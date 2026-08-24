from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


def test_health_returns_200():
    resp = client.get("/health")
    assert resp.status_code == 200


def test_health_body():
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert "environment" in body
    assert isinstance(body["secretLoaded"], bool)


def test_health_reports_secret_presence(monkeypatch):
    monkeypatch.setenv("API_KEY", "not-a-real-secret")
    body = client.get("/health").json()
    assert body["secretLoaded"] is True


def test_metrics_exposes_prometheus_format():
    client.get("/health")  # ensure at least one sample exists
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "http_requests_total" in resp.text


def test_metrics_folds_unmatched_paths():
    """Bot-scanned garbage paths must not create per-path time series."""
    client.get("/wp-login.php")
    client.get("/some/other/junk")
    body = client.get("/metrics").text
    assert "wp-login" not in body
    assert "/some/other/junk" not in body
    assert 'path="unmatched"' in body


def test_openapi_surface_disabled():
    assert client.get("/openapi.json").status_code == 404
    assert client.get("/docs").status_code == 404
