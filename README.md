# MLOps on Azure (Azure ML + GitHub Actions)

```
data/diabetes/              Training data (CSV + MLTable) -> registered as data asset `diabetes-data`
src/train.py                Train, evaluate vs. production model, quality gate, register
src/score.py                Online scoring + production data collection (for drift)
tests/                      Unit/integration tests (run in CI before any cloud spend)
environments/               conda.yml (training), score.yml (inference) - same pinned versions
mlops/azureml/              Azure ML CLI v2 specs: data, job, endpoint, deployment, monitor
infra/main.bicep(param)     Workspace + deps, managed VNet, private endpoints, diagnostics, alerts
scripts/setup.ps1           One-time OIDC bootstrap (no secrets stored in GitHub)
scripts/endpoint_state.sh   Which slot (blue/green) and model version is live
.github/workflows/          infra.yml    train.yml --(workflow_run)--> deploy.yml
```

## Flow

1. **infra** – Bicep lint + what-if on PR, deploy on merge to `main`, then provisions the
   managed network (incl. serverless Spark used by the drift monitor).
2. **train** – `pytest` + `shellcheck`, then on `main`:
   1. Registers `data/diabetes` as data asset `diabetes-data` with a **content-hash version**
      (unchanged data reuses the version; every model traces back to exact data).
   2. Reads the endpoint to find the model version **currently serving production traffic**.
   3. Runs the Azure ML job. `train.py` scores the candidate **and the production model on the
      same held-out split** and applies the **quality gate**:
      `r2 >= GATE_MIN_R2` and `r2 - production_r2 >= GATE_MIN_DELTA`.
   4. Only a passing candidate is registered (tags `gate=passed`, `r2`, `git_sha`). The gate
      result is shown in the run summary and uploaded as the `candidate` artifact; a rejected
      candidate fails the workflow.
3. **deploy** – starts automatically when `train` succeeds on `main` (`workflow_run`), or
   manually. Blue/green rollout:
   1. Deploys the candidate to the **idle** slot (`blue`/`green`) at **0% traffic**.
   2. Smoke-tests that slot directly and validates the response shape.
   3. Shifts traffic in steps (`TRAFFIC_STEPS`, default `10 50 100`), baking `BAKE_SECONDS`
      and health-checking between steps.
   4. On any failure, **automatically restores 100% to the previous slot**.
   5. On success tags model versions `stage=production` / `stage=archived` and points the
      drift monitor at the new slot. The previous slot stays at 0% for instant rollback.

The `production` GitHub environment still gates `deploy`. Keep required reviewers on it until
you trust the gate; remove them for fully continuous delivery.

## Monitoring

| What | Where |
|---|---|
| Scoring requests, latency, failures | App Insights (`app_insights_enabled: true` on deployments) |
| Alerts: >5 failed requests / avg latency >1s in 15 min | Azure Monitor → email `ALERT_EMAIL` |
| Workspace logs + metrics (jobs, compute, deployments) | Log Analytics (diagnostic settings) |
| Endpoint metrics (requests/min, latency, per deployment) | Azure Monitor metrics on the endpoint |
| Data drift + prediction drift vs. training data, daily | Azure ML model monitor `diabetes-rf-monitor` (studio → Monitoring) |

`score.py` collects `model_inputs` / `model_outputs` (valid requests only) for the monitor.
To be emailed on drift, add `alert_notification.emails` to `mlops/azureml/monitor.yml`.

## Networking

- **Managed VNet** (`AML_ISOLATION_MODE`, default `AllowInternetOutbound`) isolates training
  compute, serverless Spark and online deployments; cluster nodes get no public IPs and images
  are built on `cpu-cluster`. `AllowOnlyApprovedOutbound` restricts egress to the package feeds
  in `main.bicep` (Azure adds a billed managed firewall for FQDN rules).
- **Private endpoints** (`AML_PRIVATE_ENDPOINTS=true`) put the workspace, storage (blob/file),
  Key Vault and ACR behind private endpoints in `vnet-<prefix>` and disable public access.
  GitHub-hosted runners can then no longer reach the workspace: run a self-hosted runner in
  `snet-runners` and set `RUNNER_LABEL`. Set `ENDPOINT_PUBLIC_ACCESS=disabled` to make the
  scoring endpoint private too.
- ACR is Premium whenever private endpoints are used (managed VNet or customer VNet).

> **Existing workspaces:** managed VNet can only be enabled on a workspace without compute.
> Delete `cpu-cluster` (and any compute instances) before the first infra run with managed
> VNet on; infra recreates the cluster. Isolation cannot be switched back to `Disabled`.

## Setup

Prereqs: Azure CLI (`az login`), an Azure subscription where you can create resources and
role assignments, a GitHub repo.

```powershell
./scripts/setup.ps1 -GitHubRepo <owner>/<repo>
```

Add the printed secrets/variables to the repo, create the `production` environment, push, and
run **infra**. **train** and **deploy** then run on every change to `src/`, `data/`, etc.

### Repo variables

| Variable | Default | Purpose |
|---|---|---|
| `AZURE_RESOURCE_GROUP`, `AZURE_ML_WORKSPACE`, `ENDPOINT_NAME` | – | required |
| `GATE_MIN_R2` | `0.3` | absolute r2 floor |
| `GATE_MIN_DELTA` | `0.0` | required r2 gain over production (negative = allowed regression) |
| `TRAFFIC_STEPS` | `10 50 100` | % of traffic to the new slot per step |
| `BAKE_SECONDS` | `300` | wait between traffic steps |
| `ALERT_EMAIL` | – | enables metric alerts |
| `AML_ISOLATION_MODE` | `AllowInternetOutbound` | managed VNet mode |
| `AML_PRIVATE_ENDPOINTS` | `false` | private endpoints + no public access |
| `ENDPOINT_PUBLIC_ACCESS` | `enabled` | scoring endpoint public access |
| `RUNNER_LABEL` | `ubuntu-latest` | self-hosted runner for private workspaces |

## Operations

```bash
# Manual rollback (previous slot is still deployed at 0%)
az ml online-endpoint update -n $ENDPOINT_NAME --traffic "blue=100 green=0"

# Deploy a specific version / redeploy the live one
gh workflow run deploy -f model_version=7 -f force=true

# Retrain allowing a small regression (e.g. after a data refresh)
gh workflow run train -f min_delta=-0.02
```

**New data:** replace `data/diabetes/diabetes.csv` (same columns) and push; a new data
version is registered and the candidate is gated against production on the new split. For
data that lands in a datastore instead, point `path` in `mlops/azureml/data.yml` at the
datastore folder (it must contain an `MLTable` file).

**Cost:** the idle slot keeps one `Standard_DS3_v2` running. Delete it when rollback cover is
not needed: `az ml online-deployment delete -n <idle> -e $ENDPOINT_NAME --yes`.

Local check: `pip install -r requirements-dev.txt && pytest`
