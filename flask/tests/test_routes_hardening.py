import time

import pytest
import requests


@pytest.fixture(autouse=True)
def creds(app_module, monkeypatch):
    monkeypatch.setattr(app_module.cfg, "admin_credentials", lambda region: ("u", "p"))
    monkeypatch.setattr(app_module, "ROUTE_DEADLINE", 0.5)


class Resp:
    def __init__(self, payload):
        self.text = __import__("json").dumps(payload)


def test_unknown_region_is_404(client):
    assert client.get("/cluster/nope").status_code == 404
    assert client.get("/redis/nope").status_code == 404


def test_cluster_backend_error_is_json_message(client, app_module, monkeypatch):
    def boom(*a, **k):
        raise requests.exceptions.ConnectTimeout("down")
    monkeypatch.setattr(app_module.requests, "get", boom)
    r = client.get("/cluster/cluster-one")
    assert r.status_code == 200 and "Error" in r.get_json()["message"]


def test_cluster_backend_hang_returns_within_deadline(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", lambda *a, **k: time.sleep(3))
    t0 = time.monotonic()
    r = client.get("/cluster/cluster-one")
    assert time.monotonic() - t0 < 2
    assert r.status_code == 200 and "Error" in r.get_json()["message"]


def test_cluster_shard_on_unknown_node_does_not_crash(client, app_module, monkeypatch):
    def fake_get(url, **kw):
        assert kw.get("timeout"), "every outbound call needs a timeout"
        if url.endswith("/v1/nodes"):
            return Resp([{"status": "active", "uid": 1}])
        return Resp([{"status": "active", "role": "master", "node_uid": 9, "bdb_uid": 1,
                      "detailed_status": "ok"}])
    monkeypatch.setattr(app_module.requests, "get", fake_get)
    data = client.get("/cluster/cluster-one").get_json()
    assert data["node_1"]["status"] == "active" and "node_9" in data


def test_cluster_returns_every_node_returned(client, app_module, monkeypatch):
    def fake_get(url, **kw):
        if url.endswith("/v1/nodes"):
            return Resp([{"status": "active", "uid": 1}, {"status": "down", "uid": 4}])
        return Resp([])
    monkeypatch.setattr(app_module.requests, "get", fake_get)
    data = client.get("/cluster/cluster-one").get_json()
    assert set(data) == {"node_1", "node_4"}


def test_redis_route_survives_hang(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module, "connect_to_redis", lambda region: time.sleep(3))
    t0 = time.monotonic()
    r = client.get("/redis/cluster-one")
    assert time.monotonic() - t0 < 2 and "Error" in r.get_json()["message"]


def test_redisha_survives_hang_within_one_deadline_for_both_regions(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module, "connect_to_redis", lambda region: time.sleep(3))
    t0 = time.monotonic()
    r = client.get("/redisha")
    assert "Error" in r.get_json()["message"]
    assert time.monotonic() - t0 < 0.9, "regions must be probed in parallel under ONE deadline (0.5 s here)"


def test_redisha_prefers_first_region_and_falls_back(client, app_module, monkeypatch):
    ok = object()
    monkeypatch.setattr(app_module, "connect_to_redis",
                        lambda region: ok if region == "cluster-two" else None)
    assert "cluster-two" in client.get("/redisha").get_json()["message"]
    monkeypatch.setattr(app_module, "connect_to_redis", lambda region: ok)
    assert "cluster-one" in client.get("/redisha").get_json()["message"]


def test_server_options_are_local_and_not_debug(app_module, monkeypatch):
    monkeypatch.delenv("CHAOS_WEBUI_PORT", raising=False)
    o = app_module.server_options()
    assert o["host"] == "127.0.0.1" and o["debug"] is False and o["use_reloader"] is False
    assert o["port"] == 5050
    monkeypatch.setenv("CHAOS_WEBUI_PORT", "5099")
    assert app_module.server_options()["port"] == 5099


def _nodes_and_status(status_payload, status_raises=False):
    def fake_get(url, **kw):
        if url.endswith("/v1/nodes/status"):
            if status_raises:
                raise requests.exceptions.ConnectTimeout("no status")
            return Resp(status_payload)
        if url.endswith("/v1/nodes"):
            return Resp([{"status": "active", "uid": 1}, {"status": "active", "uid": 2}, {"status": "active", "uid": 3}])
        return Resp([])
    return fake_get


def test_cluster_reports_which_node_is_primary(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", _nodes_and_status({
        "1": {"role": "slave", "hostname": "rec-a-0"},   # the REST API still says master/slave
        "2": {"role": "master", "hostname": "rec-a-1"},
        "3": {"role": "slave", "hostname": "rec-a-2"},
    }))
    data = client.get("/cluster/cluster-one").get_json()
    assert data["node_2"]["role"] == "primary" and data["node_2"]["hostname"] == "rec-a-1"
    assert data["node_1"]["role"] == "replica" and data["node_3"]["hostname"] == "rec-a-2"


def test_cluster_still_answers_when_node_status_is_unavailable(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", _nodes_and_status(None, status_raises=True))
    data = client.get("/cluster/cluster-one").get_json()
    assert set(data) == {"node_1", "node_2", "node_3"}
    assert data["node_1"]["role"] is None and data["node_1"]["hostname"] is None


def test_cluster_ignores_a_malformed_node_status(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", _nodes_and_status(["not", "a", "dict"]))
    data = client.get("/cluster/cluster-one").get_json()
    assert data["node_1"]["role"] is None


# ---- Active-Active database status (REST /v1/bdbs): status of the DB and of each sync link
SECRET_URI = "peer://admin:SuperSecretPassw0rd@aadb-db.rec-b.test.example.com:443"


def _bdbs(payload=None, raises=False):
    def fake_get(url, **kw):
        assert kw.get("timeout"), "every outbound call needs a timeout"
        if raises:
            raise requests.exceptions.ConnectTimeout("down")
        return Resp(payload)
    return fake_get


BDBS = [
    {"uid": 1, "name": "other", "status": "active", "crdt": False},
    {"uid": 2, "name": "aadb", "status": "active", "crdt": True, "crdt_sync": "enabled",
     "authentication_redis_pass": "TopSecretDbPassword",
     "crdt_sources": [{"status": "in-sync", "lag": 0, "last_error": "", "uid": 1,
                       "replication_tls_sni": "aadb-db.rec-b.test.example.com",
                       "uri": SECRET_URI, "server_cert": "-----BEGIN CERTIFICATE-----"}]},
]


def test_aadb_route_reports_status_and_sync_links(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", _bdbs(BDBS))
    data = client.get("/aadb/cluster-one").get_json()
    assert data["name"] == "aadb" and data["status"] == "active"
    assert data["links"] == [{"source": "rec-b", "status": "in-sync", "lag": 0, "error": ""}]


def test_aadb_route_never_leaks_secrets(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", _bdbs(BDBS))
    body = client.get("/aadb/cluster-one").get_data(as_text=True)
    for secret in ("SuperSecretPassw0rd", "TopSecretDbPassword", "peer://", "BEGIN CERTIFICATE"):
        assert secret not in body


def test_aadb_route_without_the_database(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", _bdbs([{"uid": 1, "name": "x", "status": "active", "crdt": False}]))
    assert "Error" in client.get("/aadb/cluster-one").get_json()["message"]


def test_aadb_route_errors_and_unknown_region(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", _bdbs(raises=True))
    assert "Error" in client.get("/aadb/cluster-one").get_json()["message"]
    assert client.get("/aadb/nope").status_code == 404


def test_aadb_route_hang_returns_within_deadline(client, app_module, monkeypatch):
    monkeypatch.setattr(app_module.requests, "get", lambda *a, **k: time.sleep(3))
    t0 = time.monotonic()
    assert "Error" in client.get("/aadb/cluster-one").get_json()["message"]
    assert time.monotonic() - t0 < 2
