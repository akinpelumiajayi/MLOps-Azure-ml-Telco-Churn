#!/usr/bin/env bash
# One-time bootstrap: resource group + Entra app with GitHub OIDC federation (no stored secrets).
# Bash equivalent of setup.ps1; safe to re-run (existing resources are reused).
#
# Usage:
#   ./scripts/setup.sh --repo myorg/my-mlops-repo [options]
#
# Options:
#   --repo OWNER/REPO        GitHub repository (required)
#   --resource-group NAME    default: rg-mlops
#   --location REGION        default: westeurope
#   --app-name NAME          Entra app / service principal name, default: sp-mlops-github
#   --endpoint-name NAME     Online endpoint name (unique per region), default: derived from the subscription + resource group
#   --configure-github       Also write the secrets, variables and `production` environment to the repo with `gh`
#   -h, --help
set -euo pipefail

# Git Bash on Windows rewrites arguments starting with "/" (e.g. role scopes) into Windows paths.
export MSYS_NO_PATHCONV=1

REPO=""
RESOURCE_GROUP="rg-mlops"
LOCATION="westeurope"
APP_NAME="sp-mlops-github"
ENDPOINT_NAME=""
WORKSPACE_NAME="mlw-mlops"   # matches 'mlw-${prefix}' in infra/main.bicep
CONFIGURE_GITHUB=false

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }
die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
# az on Windows emits CRLF; strip it so values compare and interpolate cleanly.
azv() { az "$@" | tr -d '\r'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)             REPO="${2:?}"; shift 2 ;;
    --resource-group)   RESOURCE_GROUP="${2:?}"; shift 2 ;;
    --location)         LOCATION="${2:?}"; shift 2 ;;
    --app-name)         APP_NAME="${2:?}"; shift 2 ;;
    --endpoint-name)    ENDPOINT_NAME="${2:?}"; shift 2 ;;
    --configure-github) CONFIGURE_GITHUB=true; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ] || { usage >&2; die "--repo OWNER/REPO is required"; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must look like owner/repo, got '$REPO'"
if [ -n "$ENDPOINT_NAME" ] && ! [[ "$ENDPOINT_NAME" =~ ^[A-Za-z][A-Za-z0-9-]{1,31}$ ]]; then
  die "--endpoint-name must start with a letter and be 2-32 letters, digits or hyphens, got '$ENDPOINT_NAME'"
fi
command -v az >/dev/null || die "Azure CLI (az) not found"
if $CONFIGURE_GITHUB; then
  command -v gh >/dev/null || die "--configure-github needs the GitHub CLI (gh)"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"
fi
az account show >/dev/null 2>&1 || die "not logged in to Azure (run: az login)"

SUB=$(azv account show --query id -o tsv)
TENANT=$(azv account show --query tenantId -o tsv)
log "Subscription $SUB (tenant $TENANT)"

# --- resource group -----------------------------------------------------------
log "Resource group $RESOURCE_GROUP ($LOCATION)"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
RG_ID=$(azv group show --name "$RESOURCE_GROUP" --query id -o tsv)

if [ -z "$ENDPOINT_NAME" ]; then
  # Stable per subscription + RG, starts with a letter, <= 32 chars.
  ENDPOINT_NAME="diabetes-rf-$(printf '%s' "$RG_ID" | sha256sum | cut -c1-8)"
fi

# --- Entra app + service principal -------------------------------------------
APP_ID=$(azv ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -n "$APP_ID" ]; then
  log "Reusing app registration $APP_NAME ($APP_ID)"
else
  APP_ID=$(azv ad app create --display-name "$APP_NAME" --query appId -o tsv)
  log "Created app registration $APP_NAME ($APP_ID)"
fi

if ! az ad sp show --id "$APP_ID" -o none 2>/dev/null; then
  az ad sp create --id "$APP_ID" -o none
  log "Created service principal"
fi

# --- role assignment (retried: a new service principal takes time to replicate)
EXISTING=$(azv role assignment list --assignee "$APP_ID" --role Contributor --scope "$RG_ID" --query "length(@)" -o tsv)
if [ "${EXISTING:-0}" -gt 0 ]; then
  log "Contributor on $RESOURCE_GROUP already assigned"
else
  for attempt in 1 2 3 4 5 6; do
    if az role assignment create --assignee "$APP_ID" --role Contributor --scope "$RG_ID" -o none 2>/dev/null; then
      log "Assigned Contributor on $RESOURCE_GROUP"
      break
    fi
    [ "$attempt" -lt 6 ] || die "could not assign Contributor role (do you have Owner / User Access Administrator on the RG?)"
    echo "    service principal not visible yet, retrying in 10s ($attempt/6)"
    sleep 10
  done
fi

# --- federated credentials: one per GitHub context that logs in to Azure -----
#   ref:refs/heads/main     train / infra on main
#   environment:production  deploy (also when triggered by workflow_run)
#   pull_request            infra what-if on PRs
EXISTING_CREDS=$(azv ad app federated-credential list --id "$APP_ID" --query "[].subject" -o tsv)
for subject in "ref:refs/heads/main" "environment:production" "pull_request"; do
  full="repo:${REPO}:${subject}"
  if grep -qxF "$full" <<<"$EXISTING_CREDS"; then
    log "Federated credential for $full exists"
    continue
  fi
  name=$(printf '%s' "$subject" | tr -c 'A-Za-z0-9' '-')
  az ad app federated-credential create --id "$APP_ID" -o none --parameters "{
    \"name\": \"$name\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$full\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
  log "Created federated credential for $full"
done

# --- GitHub configuration -------------------------------------------------------
SECRETS=(
  "AZURE_CLIENT_ID=$APP_ID"
  "AZURE_TENANT_ID=$TENANT"
  "AZURE_SUBSCRIPTION_ID=$SUB"
)
VARIABLES=(
  "AZURE_RESOURCE_GROUP=$RESOURCE_GROUP"
  "AZURE_ML_WORKSPACE=$WORKSPACE_NAME"
  "ENDPOINT_NAME=$ENDPOINT_NAME"
)

if $CONFIGURE_GITHUB; then
  for kv in "${SECRETS[@]}"; do
    gh secret set "${kv%%=*}" --repo "$REPO" --body "${kv#*=}"
  done
  for kv in "${VARIABLES[@]}"; do
    gh variable set "${kv%%=*}" --repo "$REPO" --body "${kv#*=}"
  done
  gh api --method PUT "repos/$REPO/environments/production" --silent
  log "Wrote secrets, variables and the 'production' environment to $REPO"
  echo
  echo "Add required reviewers to the 'production' environment for a manual deploy approval:"
  echo "  https://github.com/$REPO/settings/environments"
else
  echo
  echo "Done. Add these to GitHub (Settings > Secrets and variables > Actions),"
  echo "or re-run with --configure-github to set them with gh:"
  echo
  echo "Secrets:   ${SECRETS[*]}"
  echo "Variables: ${VARIABLES[*]}"
  echo "Also create a GitHub environment named 'production' (add required reviewers for approval)."
fi

cat <<EOF

Optional variables (see README):
  GATE_MIN_R2=0.3  GATE_MIN_DELTA=0.0  TRAFFIC_STEPS='10 50 100'  BAKE_SECONDS=300
  ALERT_EMAIL=<you@example.com>  AML_ISOLATION_MODE=AllowInternetOutbound  AML_PRIVATE_ENDPOINTS=false
  ENDPOINT_PUBLIC_ACCESS=enabled  RUNNER_LABEL=<self-hosted label, required once private endpoints are on>

Next: push, then run the 'infra' workflow.
EOF
