import json
import logging

import pytest


@pytest.fixture(autouse=True)
def fresh_state(app_module):
    import chaos_api
    from chaos_state import ChaosState
    chaos_api.state = ChaosState()
    yield


def post(client, body, **kw):
    return client.post("/api/chaos/event", json=body, **kw)


def test_health(client):
    r = client.get("/api/health")
    assert r.status_code == 200 and r.get_json() == {"status": "ok"}


def test_valid_run_is_reflected_in_state(client):
    assert post(client, {"type": "run_start", "run_id": "r-1", "target": "rec-a", "witness": "rec-b"}).status_code == 204
    assert post(client, {"type": "phase_start", "run_id": "r-1", "phase": "node"}).status_code == 204
    assert post(client, {"type": "inject", "run_id": "r-1", "phase": "node", "note": "reset vm"}).status_code == 204
    assert post(client, {"type": "step", "run_id": "r-1", "phase": "node", "name": "node-recovery",
                         "status": "PASS", "seconds": 61}).status_code == 204
    s = client.get("/api/chaos/state").get_json()
    assert s["active"] is True
    assert s["run"]["phase"] == "node" and s["run"]["recovered_seconds"] == 61
    assert s["run"]["scenario"]["title"] == "Node failure"


def test_state_before_any_run(client):
    s = client.get("/api/chaos/state").get_json()
    assert s["run"] is None and s["active"] is False and "server_time" in s


@pytest.mark.parametrize("body", [
    {"run_id": "r"},                                            # no type
    {"type": "bogus", "run_id": "r"},                           # unknown type
    {"type": "run_start"},                                      # no run_id
    {"type": "run_start", "run_id": "has space"},               # bad charset
    {"type": "run_start", "run_id": "x" * 41},                  # too long
    {"type": "phase_start", "run_id": "r"},                     # phase required
    {"type": "phase_start", "run_id": "r", "phase": "nope"},    # unknown phase
    {"type": "step", "run_id": "r", "phase": "pod", "name": "n", "status": "MAYBE"},
    {"type": "step", "run_id": "r", "phase": "pod", "name": "n", "status": "PASS", "seconds": -1},
    {"type": "step", "run_id": "r", "phase": "pod", "name": "n", "status": "PASS", "seconds": "x"},
    {"type": "run_end", "run_id": "r", "status": "WHATEVER"},
    ["not", "an", "object"],
])
def test_invalid_events_are_rejected_with_400(client, body):
    r = post(client, body)
    assert r.status_code == 400 and "error" in r.get_json()
    assert client.get("/api/chaos/state").get_json()["run"] is None


def test_non_json_is_400(client):
    r = client.post("/api/chaos/event", data="{not json", content_type="application/json")
    assert r.status_code == 400


def test_too_large_is_413(client):
    r = client.post("/api/chaos/event", data=json.dumps({"type": "run_start", "run_id": "r", "note": "x" * 6000}),
                    content_type="application/json")
    assert r.status_code == 413


def test_non_loopback_client_is_403(client):
    r = post(client, {"type": "run_start", "run_id": "r"}, environ_overrides={"REMOTE_ADDR": "10.1.2.3"})
    assert r.status_code == 403
    assert client.get("/api/chaos/state").get_json()["run"] is None


def test_ipv6_loopback_is_accepted(client):
    r = post(client, {"type": "run_start", "run_id": "r"}, environ_overrides={"REMOTE_ADDR": "::1"})
    assert r.status_code == 204


def test_unknown_keys_ignored_and_note_clipped(client):
    post(client, {"type": "run_start", "run_id": "r", "evil": "<script>"})
    post(client, {"type": "step", "run_id": "r", "phase": "pod", "name": "n", "status": "INFO",
                  "note": "y" * 500})
    step = client.get("/api/chaos/state").get_json()["run"]["steps"][0]
    assert len(step["note"]) == 200 and "evil" not in json.dumps(client.get("/api/chaos/state").get_json())


def test_http_server_logs_go_to_a_file_not_the_terminal(tmp_path, capsys):
    import chaos_api
    log = chaos_api.configure_logging(tmp_path)
    logging.getLogger("werkzeug").info('127.0.0.1 - - "GET / HTTP/1.1" 200 -')
    for h in logging.getLogger("werkzeug").handlers:
        h.flush()
    out = capsys.readouterr()
    assert out.out == "" and out.err == ""
    assert "GET / HTTP/1.1" in log.read_text()
    assert log.parent == tmp_path
