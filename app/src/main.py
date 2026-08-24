"""TeraSky home assignment backend.

Endpoints:
  GET /health   - liveness/readiness probe target
  GET /nodes    - cluster node list, marking the node this pod runs on
  GET /metrics  - Prometheus metrics
"""

import logging
import os
import time

from fastapi import FastAPI, Request, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

from .k8s import KubernetesUnavailableError, list_nodes

APP_ENV = os.getenv("APP_ENV", "local")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("backend")

app = FastAPI(title="terasky-backend", version="1.0.0", docs_url=None, redoc_url=None)

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests",
    ["method", "path", "status"],
)
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "path"],
)


@app.middleware("http")
async def prometheus_middleware(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start
    path = request.url.path
    HTTP_REQUESTS.labels(request.method, path, str(response.status_code)).inc()
    HTTP_LATENCY.labels(request.method, path).observe(elapsed)
    return response


@app.get("/health")
def health() -> dict:
    """Cheap, dependency-free health signal used by liveness AND readiness
    probes. It intentionally does NOT call the Kubernetes API: a control-plane
    hiccup must not make every replica unready at once."""
    return {
        "status": "ok",
        "environment": APP_ENV,
        # Presence only - never the value. Proves the External Secrets flow
        # delivered the secret into the container environment.
        "secretLoaded": bool(os.getenv("API_KEY")),
    }


@app.get("/nodes")
def nodes(response: Response) -> dict:
    """List cluster nodes and mark the one running this pod.

    Node identity comes from the Downward API (spec.nodeName); the node list
    comes from the Kubernetes API using the pod's ServiceAccount, which is
    allowed exactly get/list on nodes and nothing else.
    """
    current_node = os.getenv("NODE_NAME", "")
    payload = {
        "pod": os.getenv("POD_NAME", ""),
        "namespace": os.getenv("POD_NAMESPACE", ""),
        "environment": APP_ENV,
        "currentNode": current_node,
    }
    try:
        payload["nodes"] = list_nodes(current_node)
    except KubernetesUnavailableError as exc:
        logger.error("kubernetes API unavailable: %s", exc)
        response.status_code = 503
        payload["error"] = "kubernetes API unavailable"
        return payload
    return payload


@app.get("/metrics")
def metrics() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
