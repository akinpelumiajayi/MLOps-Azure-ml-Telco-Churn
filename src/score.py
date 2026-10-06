"""Scoring script for the managed online deployment.

Loads the registered MLflow model and records every request's inputs and
predictions with the Azure ML data collector. The drift monitor reads that
collected data (`model_inputs` / `model_outputs`).

Request format is the MLflow "split" layout used by sample-request.json:
  {"input_data": {"columns": [...], "index": [...], "data": [[...], ...]}}
"""
import json
import logging
import os
from pathlib import Path

import mlflow.pyfunc
import pandas as pd
from azureml.ai.monitoring import Collector
from azureml.contrib.services.aml_response import AMLResponse
from mlflow.exceptions import MlflowException

MAX_ROWS = 1000

model = None
inputs_collector = None
outputs_collector = None


def _find_model_dir(root: str) -> str:
    """AZUREML_MODEL_DIR holds the model under a sub-folder; locate the MLmodel file."""
    matches = sorted(Path(root).rglob("MLmodel"))
    if not matches:
        raise FileNotFoundError(f"No MLmodel file under {root}")
    return str(matches[0].parent)


def init():
    global model, inputs_collector, outputs_collector
    model_dir = _find_model_dir(os.environ["AZUREML_MODEL_DIR"])
    model = mlflow.pyfunc.load_model(model_dir)
    inputs_collector = Collector(name="model_inputs", on_error=lambda e: logging.warning(e))
    outputs_collector = Collector(name="model_outputs", on_error=lambda e: logging.warning(e))
    logging.info("Loaded model from %s", model_dir)


def _parse(raw_data: str) -> pd.DataFrame:
    body = json.loads(raw_data)
    payload = body.get("input_data") if isinstance(body, dict) else None
    if not isinstance(payload, dict) or "data" not in payload or "columns" not in payload:
        raise ValueError('Expected {"input_data": {"columns": [...], "data": [[...]]}}')
    df = pd.DataFrame(payload["data"], columns=payload["columns"])
    if df.empty or len(df) > MAX_ROWS:
        raise ValueError(f"Request must contain 1-{MAX_ROWS} rows, got {len(df)}")
    return df


def run(raw_data: str):
    try:
        df = _parse(raw_data)
        # The MLflow signature enforces column names and types.
        preds = model.predict(df)
    except (ValueError, TypeError, MlflowException) as e:
        # Malformed input is a client error: answer 400 rather than an opaque 500.
        return AMLResponse(json.dumps({"error": str(e)}), 400)

    # Collected only after a successful prediction so invalid requests don't
    # pollute the drift monitor's production data.
    context = inputs_collector.collect(df)
    outputs_collector.collect(pd.DataFrame({"prediction": preds}), context)
    return [float(p) for p in preds]
