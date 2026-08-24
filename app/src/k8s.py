"""Thin wrapper around the Kubernetes API.

Kept separate from the FastAPI app so tests can exercise the shaping logic
with fake node objects and no cluster.
"""

import logging
from functools import lru_cache

from kubernetes import client, config
from kubernetes.client.rest import ApiException

logger = logging.getLogger("backend.k8s")


class KubernetesUnavailableError(RuntimeError):
    """Raised when the Kubernetes API cannot be reached or refuses us."""


@lru_cache(maxsize=1)
def _core_v1() -> client.CoreV1Api:
    """Load in-cluster config (ServiceAccount token + cluster CA). Falls back
    to local kubeconfig so the app can also run during development."""
    try:
        config.load_incluster_config()
        logger.info("loaded in-cluster kubernetes config")
    except config.ConfigException:
        config.load_kube_config()
        logger.info("loaded local kubeconfig")
    return client.CoreV1Api()


def shape_node(node, current_node: str) -> dict:
    """Reduce a V1Node to safe, useful fields. Deliberately excludes
    addresses, taints and full label sets - /nodes is an application endpoint,
    not a cluster-inventory API."""
    conditions = node.status.conditions or []
    ready = any(c.type == "Ready" and c.status == "True" for c in conditions)
    info = node.status.node_info
    return {
        "name": node.metadata.name,
        "ready": ready,
        "current": node.metadata.name == current_node,
        "kubeletVersion": info.kubelet_version if info else None,
        "architecture": info.architecture if info else None,
        "os": info.operating_system if info else None,
    }


def list_nodes(current_node: str) -> list[dict]:
    try:
        result = _core_v1().list_node(_request_timeout=5)
    except (ApiException, Exception) as exc:  # noqa: BLE001 - urllib3 raises many types
        raise KubernetesUnavailableError(str(exc)) from exc
    return [shape_node(n, current_node) for n in result.items]
