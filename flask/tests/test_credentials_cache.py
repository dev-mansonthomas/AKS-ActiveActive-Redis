"""The page polls every ~1 s per source: the Kubernetes client and the admin credentials must not be
rebuilt (exec auth plugin + secret read) on every request, and a stale value must not stick."""
import base64

import appconfig
import pytest
import redis
import requests


class FakeSecret:
    def __init__(self, user="admin", pw="pw1"):
        self.data = {"username": base64.b64encode(user.encode()).decode(),
                     "password": base64.b64encode(pw.encode()).decode()}


@pytest.fixture()
def cfg(monkeypatch):
    from kubernetes import client, config
    calls = {"client": 0, "secret": 0, "pw": "pw1"}

    def new_client(context=None, **kw):
        calls["client"] += 1
        return client.ApiClient()

    def read_secret(self, name, ns, **kw):
        calls["secret"] += 1
        return FakeSecret(pw=calls["pw"])

    monkeypatch.setattr(config, "new_client_from_config", new_client)
    monkeypatch.setattr(client.CoreV1Api, "read_namespaced_secret", read_secret)
    c = appconfig.Config()
    c.calls = calls
    return c


def test_kube_client_is_built_once(cfg):
    name = cfg.clusters[0]
    for _ in range(20):
        cfg.admin_credentials(name)
    assert cfg.calls["client"] == 1


def test_admin_credentials_are_read_once(cfg):
    name = cfg.clusters[0]
    assert cfg.admin_credentials(name) == ("admin", "pw1")
    for _ in range(20):
        cfg.admin_credentials(name)
    assert cfg.calls["secret"] == 1


def test_invalidate_forces_a_fresh_read(cfg):
    name = cfg.clusters[0]
    cfg.admin_credentials(name)
    cfg.calls["pw"] = "pw2"          # the rig was destroyed and redeployed: new password
    assert cfg.admin_credentials(name) == ("admin", "pw1")
    cfg.invalidate(name)
    assert cfg.admin_credentials(name) == ("admin", "pw2")


def test_cache_expires(cfg, monkeypatch):
    name = cfg.clusters[0]
    cfg.admin_credentials(name)
    now = appconfig.time.monotonic()
    monkeypatch.setattr(appconfig.time, "monotonic", lambda: now + appconfig.CACHE_TTL + 1)
    cfg.admin_credentials(name)
    assert cfg.calls["secret"] == 2 and cfg.calls["client"] == 2


# ---- the console's database password -------------------------------------------------------------
def test_missing_db_password_is_not_cached(app_module, monkeypatch):
    seen = []
    monkeypatch.setattr(app_module.cfg, "db_password", lambda r: seen.append(r))   # returns None
    monkeypatch.setattr(app_module, "_db_password", {})
    region = app_module.cfg.clusters[0]
    assert app_module.db_password(region) is None
    assert app_module.db_password(region) is None
    assert len(seen) == 2, "None (secret not created yet) must be retried, not remembered"


def test_db_password_is_cached_then_dropped_on_auth_error(app_module, monkeypatch):
    values = iter(["old", "new"])
    monkeypatch.setattr(app_module.cfg, "db_password", lambda r: next(values))
    monkeypatch.setattr(app_module, "_db_password", {})
    region = app_module.cfg.clusters[0]
    assert app_module.db_password(region) == "old"
    assert app_module.db_password(region) == "old"          # cached

    class Boom:
        def __init__(self, *a, **k): pass
        def ping(self): raise redis.AuthenticationError("WRONGPASS")
    monkeypatch.setattr(app_module.redis, "StrictRedis", Boom)
    assert app_module.connect_to_redis(region) is None
    assert app_module.db_password(region) == "new"           # dropped on WRONGPASS: redeployed rig


def test_rest_401_invalidates_the_admin_credentials(app_module, monkeypatch):
    region = app_module.cfg.clusters[0]
    dropped = []
    monkeypatch.setattr(app_module.cfg, "admin_credentials", lambda r: ("u", "p"))
    monkeypatch.setattr(app_module.cfg, "invalidate", lambda r=None: dropped.append(r))

    class R401:
        status_code = 401
        text = "{}"
    monkeypatch.setattr(app_module.requests, "get", lambda *a, **k: R401())
    with pytest.raises(PermissionError):
        app_module._fetch_cluster(region)
    assert dropped and set(dropped) == {region}     # the 3 parallel REST calls may each drop it
    dropped.clear()
    with pytest.raises(PermissionError):
        app_module._fetch_aadb(region)
    assert dropped and set(dropped) == {region}
    assert requests  # imported for parity with the other test modules
