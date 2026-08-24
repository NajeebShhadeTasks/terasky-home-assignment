from types import SimpleNamespace

from fastapi.testclient import TestClient

from src import k8s
from src.main import app

client = TestClient(app)


def fake_node(name: str, ready: bool = True):
    return SimpleNamespace(
        metadata=SimpleNamespace(name=name),
        status=SimpleNamespace(
            conditions=[
                SimpleNamespace(type="MemoryPressure", status="False"),
                SimpleNamespace(type="Ready", status="True" if ready else "False"),
            ],
            node_info=SimpleNamespace(
                kubelet_version="v1.33.0",
                architecture="amd64",
                operating_system="linux",
            ),
        ),
    )


def test_shape_node_marks_current():
    shaped = k8s.shape_node(fake_node("node-a"), current_node="node-a")
    assert shaped == {
        "name": "node-a",
        "ready": True,
        "current": True,
        "kubeletVersion": "v1.33.0",
        "architecture": "amd64",
        "os": "linux",
    }


def test_shape_node_not_ready_not_current():
    shaped = k8s.shape_node(fake_node("node-b", ready=False), current_node="node-a")
    assert shaped["ready"] is False
    assert shaped["current"] is False


def test_nodes_endpoint_marks_current_node(monkeypatch):
    monkeypatch.setenv("NODE_NAME", "node-a")
    monkeypatch.setenv("POD_NAME", "backend-abc")
    monkeypatch.setenv("POD_NAMESPACE", "dev")
    monkeypatch.setattr(
        k8s,
        "_core_v1",
        lambda: SimpleNamespace(
            list_node=lambda _request_timeout: SimpleNamespace(
                items=[fake_node("node-a"), fake_node("node-b")]
            )
        ),
    )

    body = client.get("/nodes").json()
    assert body["pod"] == "backend-abc"
    assert body["namespace"] == "dev"
    assert body["currentNode"] == "node-a"
    current_flags = {n["name"]: n["current"] for n in body["nodes"]}
    assert current_flags == {"node-a": True, "node-b": False}


def test_nodes_endpoint_api_unavailable(monkeypatch):
    def boom(_request_timeout):
        raise RuntimeError("connection refused")

    monkeypatch.setattr(k8s, "_core_v1", lambda: SimpleNamespace(list_node=boom))
    resp = client.get("/nodes")
    assert resp.status_code == 503
    assert resp.json()["error"] == "kubernetes API unavailable"
