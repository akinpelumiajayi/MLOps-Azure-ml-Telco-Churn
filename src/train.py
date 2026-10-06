"""Train a RandomForest on the diabetes data asset, gate it, and log it with MLflow.

The quality gate scores the candidate and the current production model on the
same held-out split. The candidate is registered only if it passes; the result
is written to `<gate_output>/gate.json` for the CI workflow to act on.

Runs unchanged locally and as an Azure ML command job (tracking URI is injected
by Azure ML, so there is no workspace-specific code here).
"""
import argparse
import json
from pathlib import Path

import mlflow
import mlflow.pyfunc
import mlflow.sklearn
import pandas as pd
from mlflow.models import infer_signature
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_squared_error, r2_score
from sklearn.model_selection import train_test_split

TARGET = "target"
FEATURES = ["age", "sex", "bmi", "bp", "s1", "s2", "s3", "s4", "s5", "s6"]


def load_data(path: str) -> pd.DataFrame:
    """Read a CSV file, or the CSV files in a folder (uri_folder / MLTable mount)."""
    p = Path(path)
    files = sorted(p.glob("*.csv")) if p.is_dir() else [p]
    if not files:
        raise FileNotFoundError(f"No CSV files found in {path}")
    df = pd.concat((pd.read_csv(f) for f in files), ignore_index=True)

    missing = set(FEATURES + [TARGET]) - set(df.columns)
    if missing:
        raise ValueError(f"Training data is missing columns: {sorted(missing)}")
    df = df[FEATURES + [TARGET]]
    if df.isna().any().any():
        raise ValueError("Training data contains missing values")
    if len(df) < 50:
        raise ValueError(f"Training data has only {len(df)} rows")
    return df


def split(df: pd.DataFrame, seed: int = 42):
    return train_test_split(df[FEATURES], df[TARGET], test_size=0.2, random_state=seed)


def train(X_train, y_train, n_estimators: int, max_depth: int, seed: int = 42):
    return RandomForestRegressor(
        n_estimators=n_estimators, max_depth=max_depth, random_state=seed
    ).fit(X_train, y_train)


def evaluate(model, X_test, y_test) -> dict:
    preds = model.predict(X_test)
    return {
        "rmse": float(mean_squared_error(y_test, preds) ** 0.5),
        "r2": float(r2_score(y_test, preds)),
    }


def quality_gate(r2: float, baseline_r2, min_r2: float, min_delta: float):
    """Return (passed, reason). `baseline_r2` is None when nothing is in production."""
    if r2 < min_r2:
        return False, f"r2 {r2:.4f} is below the absolute floor {min_r2:.4f}"
    if baseline_r2 is None:
        return True, f"r2 {r2:.4f} >= floor {min_r2:.4f}; no production model to compare"
    delta = r2 - baseline_r2
    if delta < min_delta:
        return False, (
            f"r2 {r2:.4f} vs production {baseline_r2:.4f} "
            f"(delta {delta:+.4f} < required {min_delta:+.4f})"
        )
    return True, f"r2 {r2:.4f} vs production {baseline_r2:.4f} (delta {delta:+.4f})"


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True, help="CSV file or folder of CSVs")
    parser.add_argument("--n_estimators", type=int, default=200)
    parser.add_argument("--max_depth", type=int, default=8)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--model_name", default="diabetes-rf")
    parser.add_argument("--baseline_version", default="none",
                        help="Registered version serving production traffic, or 'none'")
    parser.add_argument("--min_r2", type=float, default=0.3)
    parser.add_argument("--min_delta", type=float, default=0.0,
                        help="Required r2 improvement over production (negative allows slack)")
    parser.add_argument("--git_sha", default="local")
    parser.add_argument("--gate_output", default="outputs/gate")
    args = parser.parse_args(argv)

    X_train, X_test, y_train, y_test = split(load_data(args.data), args.seed)

    with mlflow.start_run() as run:
        model = train(X_train, y_train, args.n_estimators, args.max_depth, args.seed)
        metrics = evaluate(model, X_test, y_test)

        baseline = None
        if args.baseline_version.lower() != "none":
            baseline_model = mlflow.pyfunc.load_model(
                f"models:/{args.model_name}/{args.baseline_version}"
            )
            baseline = evaluate(baseline_model, X_test, y_test)
            metrics.update({f"baseline_{k}": v for k, v in baseline.items()})
            metrics["r2_delta"] = metrics["r2"] - baseline["r2"]

        passed, reason = quality_gate(
            metrics["r2"], baseline and baseline["r2"], args.min_r2, args.min_delta
        )

        mlflow.log_params({
            "n_estimators": args.n_estimators,
            "max_depth": args.max_depth,
            "seed": args.seed,
            "baseline_version": args.baseline_version,
            "rows_train": len(X_train),
            "rows_test": len(X_test),
        })
        mlflow.log_metrics(metrics)
        mlflow.set_tags({"gate": "passed" if passed else "rejected", "git_sha": args.git_sha})
        mlflow.sklearn.log_model(
            model,
            artifact_path="model",
            signature=infer_signature(X_test, model.predict(X_test)),
            input_example=X_test.head(2),
        )

        model_version = None
        if passed:
            registered = mlflow.register_model(
                f"runs:/{run.info.run_id}/model",
                args.model_name,
                tags={"gate": "passed", "r2": f"{metrics['r2']:.4f}", "git_sha": args.git_sha},
            )
            model_version = str(registered.version)

    result = {
        "passed": passed,
        "reason": reason,
        "model_name": args.model_name,
        "model_version": model_version,
        "baseline_version": None if baseline is None else args.baseline_version,
        "metrics": metrics,
        "run_id": run.info.run_id,
        "git_sha": args.git_sha,
    }
    out = Path(args.gate_output)
    out.mkdir(parents=True, exist_ok=True)
    (out / "gate.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return result


if __name__ == "__main__":
    main()
