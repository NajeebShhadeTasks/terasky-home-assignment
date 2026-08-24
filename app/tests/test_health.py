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
