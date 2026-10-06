import importlib
import json
import sys
import types
from pathlib import Path

import mlflow.sklearn
import pytest
from mlflow.models import infer_signature

import train

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = (ROOT / "mlops" / "azureml" / "sample-request.json").read_text()


class FakeCollector:
    def __init__(self, name, on_error=None):
        self.name, self.collected = name, []

    def collect(self, df, context=None):
        self.collected.append(df)
        return object()


class FakeResponse:
    def __init__(self, body, status_code):
        self.body, self.status_code = body, status_code


@pytest.fixture
def score(tmp_path, monkeypatch):
    # The Azure ML serving packages only exist inside the inference image.
    for name, attrs in {
        "azureml": {}, "azureml.ai": {}, "azureml.contrib": {}, "azureml.contrib.services": {},
        "azureml.ai.monitoring": {"Collector": FakeCollector},
        "azureml.contrib.services.aml_response": {"AMLResponse": FakeResponse},
    }.items():
        monkeypatch.setitem(sys.modules, name, types.SimpleNamespace(**attrs))

    X_train, X_test, y_train, _ = train.split(train.load_data(str(ROOT / "data" / "diabetes")))
    model = train.train(X_train, y_train, n_estimators=10, max_depth=3)
    # Mirror the layout Azure ML mounts: AZUREML_MODEL_DIR/<model folder>/MLmodel
    mlflow.sklearn.save_model(
        model, tmp_path / "model", signature=infer_signature(X_test, model.predict(X_test))
    )
    monkeypatch.setenv("AZUREML_MODEL_DIR", str(tmp_path))

    module = importlib.import_module("score")
    module = importlib.reload(module)
    module.init()
    return module


def test_scores_sample_request_and_collects(score):
    preds = score.run(SAMPLE)
    assert len(preds) == 1 and isinstance(preds[0], float)
    assert len(score.inputs_collector.collected) == 1
    assert len(score.outputs_collector.collected) == 1


@pytest.mark.parametrize("body", [
    "not json",
    json.dumps({"data": [[1, 2]]}),
    json.dumps({"input_data": {"columns": ["age"], "data": [[0.1]]}}),  # schema mismatch
])
def test_bad_requests_get_400_and_are_not_collected(score, body):
    resp = score.run(body)
    assert isinstance(resp, FakeResponse) and resp.status_code == 400
    assert score.inputs_collector.collected == []
