import json
from pathlib import Path

import pytest

import train

DATA_DIR = Path(__file__).resolve().parents[1] / "data" / "diabetes"


@pytest.fixture
def mlflow_tmp(tmp_path, monkeypatch):
    """Isolated local tracking + registry so tests never touch ./mlruns or Azure."""
    monkeypatch.setenv("MLFLOW_TRACKING_URI", (tmp_path / "mlruns").as_uri())
    return tmp_path


def test_load_data_from_folder_and_file():
    from_dir = train.load_data(str(DATA_DIR))
    from_file = train.load_data(str(DATA_DIR / "diabetes.csv"))
    assert list(from_dir.columns) == train.FEATURES + [train.TARGET]
    assert len(from_dir) == len(from_file) == 442


def test_load_data_rejects_missing_columns(tmp_path):
    (tmp_path / "bad.csv").write_text("age,sex\n1,2\n")
    with pytest.raises(ValueError, match="missing columns"):
        train.load_data(str(tmp_path))


def test_model_beats_baseline():
    X_train, X_test, y_train, y_test = train.split(train.load_data(str(DATA_DIR)))
    model = train.train(X_train, y_train, n_estimators=20, max_depth=4)
    metrics = train.evaluate(model, X_test, y_test)
    assert metrics["r2"] > 0.3
    assert metrics["rmse"] < 70


@pytest.mark.parametrize(
    "r2, baseline, min_delta, expected",
    [
        (0.20, None, 0.0, False),   # below absolute floor
        (0.45, None, 0.0, True),    # first model, above floor
        (0.45, 0.44, 0.0, True),    # improves on production
        (0.45, 0.45, 0.0, True),    # ties production
        (0.43, 0.45, 0.0, False),   # regression
        (0.44, 0.45, -0.02, True),  # regression within allowed slack
        (0.46, 0.45, 0.05, False),  # improvement too small
    ],
)
def test_quality_gate(r2, baseline, min_delta, expected):
    passed, reason = train.quality_gate(r2, baseline, min_r2=0.3, min_delta=min_delta)
    assert passed is expected
    assert reason


def _run(tmp_path, *extra):
    out = tmp_path / "gate"
    train.main([
        "--data", str(DATA_DIR), "--n_estimators", "20", "--max_depth", "4",
        "--gate_output", str(out), *extra,
    ])
    return json.loads((out / "gate.json").read_text())


def test_main_registers_first_model_then_gates_against_it(mlflow_tmp):
    first = _run(mlflow_tmp)
    assert first["passed"] and first["model_version"] == "1"
    assert first["baseline_version"] is None

    # Same data + hyperparameters + seed reproduces the production model: a tie passes.
    second = _run(mlflow_tmp, "--baseline_version", "1")
    assert second["passed"] and second["model_version"] == "2"
    assert second["metrics"]["r2_delta"] == pytest.approx(0.0)

    # A much weaker model is rejected and not registered.
    third = _run(mlflow_tmp, "--baseline_version", "1", "--n_estimators", "1", "--max_depth", "1")
    assert not third["passed"] and third["model_version"] is None
