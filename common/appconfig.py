"""Shared config for the Python tools (Flask console, benchmarks).

config.sh is the single source of truth (ADR 0005) and uses shell expansion
(REC_NAME1=rec-${RE_ALIAS1}), so it cannot be parsed line by line: it is
*sourced* by bash and the resulting environment is read back. Independent of the
current working directory.
"""
import base64
import os
import subprocess
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The console polls ~1 s per source. Building a Kubernetes client (on GKE: starting the auth plugin)
# and reading the admin secret on every request can exceed the 4 s route deadline and flap the page,
# so both are kept for a few minutes (and dropped at once when the cluster answers 401).
CACHE_TTL = 300


def default_config_path():
    """config.sh at the repo root, unless RE_CONFIG_FILE points elsewhere (used by tests)."""
    override = os.environ.get("RE_CONFIG_FILE")
    return Path(override) if override else REPO_ROOT / "config.sh"


def load():
    """Return config.sh's variables as a dict (sourced by bash, expansions done)."""
    out = subprocess.check_output(
        ["bash", "-c", 'set -a; . "$1" >/dev/null 2>&1; env -0', "_", str(default_config_path())]
    )
    env = {}
    for kv in out.decode("utf-8", "replace").split("\0"):
        if "=" in kv:
            k, v = kv.split("=", 1)
            env[k] = v
    return env


class Config:
    def __init__(self):
        self.env = load()
        self._cache = {}
        self._lock = threading.Lock()
        e = self.env
        self.ns = e.get("NS") or "rec"
        self.aa_db = e.get("AA_DB_NAME")
        self.dns_zone = e.get("DNS_ZONE")
        # (kubectl context == cloud cluster name, Redis Enterprise cluster name)
        self.rec_of = {}
        for i in (1, 2, 3):
            cluster, rec = e.get(f"CLUSTER{i}"), e.get(f"REC_NAME{i}")
            if cluster and rec:
                self.rec_of[cluster] = rec
        # GKE's exec auth plugin uses the *active* gcloud account; pin the one
        # config.sh names, like the shell scripts do.
        if e.get("CLOUD_PROVIDER") == "gcp" and e.get("GCP_ACCOUNT"):
            os.environ.setdefault("CLOUDSDK_CORE_ACCOUNT", e["GCP_ACCOUNT"])

    @property
    def clusters(self):
        return list(self.rec_of)

    def db_host(self, cluster):
        return f"{self.aa_db}-db.{self.rec_of[cluster]}.{self.dns_zone}"

    def api_host(self, cluster):
        return f"api.{self.rec_of[cluster]}.{self.dns_zone}"

    def _cached(self, key, build):
        now = time.monotonic()
        with self._lock:
            hit = self._cache.get(key)
            if hit and now - hit[0] < CACHE_TTL:
                return hit[1]
        value = build()      # outside the lock: it can be slow (auth plugin, network)
        with self._lock:
            self._cache[key] = (now, value)
        return value

    def invalidate(self, cluster=None):
        """Forget the cached client and credentials of one cluster (or all): a redeployed rig has new ones."""
        with self._lock:
            for key in [k for k in self._cache if cluster is None or k[1] == cluster]:
                del self._cache[key]

    def kube_api(self, cluster):
        from kubernetes import client, config
        return self._cached(("kube", cluster), lambda: client.CoreV1Api(
            api_client=config.new_client_from_config(context=cluster)))

    def admin_credentials(self, cluster):
        """(username, password) of the REC admin: secret named after the REC."""
        def read():
            s = self.kube_api(cluster).read_namespaced_secret(self.rec_of[cluster], self.ns)
            return (base64.b64decode(s.data["username"]).decode(),
                    base64.b64decode(s.data["password"]).decode())
        return self._cached(("admin", cluster), read)

    def db_password(self, cluster):
        """Database password from secret <db>-password, or None if there is none
        (e.g. an Azure deployment created before the password was generated)."""
        from kubernetes.client.rest import ApiException
        try:
            s = self.kube_api(cluster).read_namespaced_secret(f"{self.aa_db}-password", self.ns)
        except ApiException as e:
            if e.status == 404:
                return None
            raise
        return base64.b64decode(s.data["password"]).decode()
