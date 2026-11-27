"""HTTP API between `scripts/chaos.sh` and the chaos web console.

  POST /api/chaos/event   chaos.sh -> console (localhost only)
  GET  /api/chaos/state   page -> console
  GET  /api/health        launcher -> console

Contract: docs/specs/chaos-webui.md. Input is validated and rebuilt field by field:
unknown keys are dropped and free text is clipped. The page renders it with
textContent only.
"""
import logging
import re
from pathlib import Path

import scenarios
from chaos_state import ChaosState

from flask import Blueprint, jsonify, request

bp = Blueprint("chaos", __name__)
state = ChaosState()

MAX_BODY = 4096
RUN_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,40}$")
EVENT_TYPES = {"run_start", "phase_start", "inject", "step", "phase_end", "run_end"}
PHASE_REQUIRED = {"phase_start", "inject", "step", "phase_end"}
STEP_STATUS = {"PASS", "FAIL", "INFO"}
RUN_END_STATUS = {"PASS", "FAIL", "ABORTED"}
LOOPBACK = {"127.0.0.1", "::1", "::ffff:127.0.0.1"}


class Invalid(ValueError):
    pass


def _text(body, key, limit):
    value = body.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise Invalid(f"'{key}' must be a string")
    return value[:limit]


def validate(body):
    """Return a clean event dict or raise Invalid."""
    if not isinstance(body, dict):
        raise Invalid("body must be a JSON object")
    typ = body.get("type")
    if typ not in EVENT_TYPES:
        raise Invalid(f"'type' must be one of {sorted(EVENT_TYPES)}")
    run_id = body.get("run_id")
    if not isinstance(run_id, str) or not RUN_ID_RE.match(run_id):
        raise Invalid("'run_id' is required: 1-40 characters of [A-Za-z0-9._-]")
    ev = {"type": typ, "run_id": run_id}

    if typ in PHASE_REQUIRED:
        phase = body.get("phase")
        if phase not in scenarios.SCENARIOS:
            raise Invalid(f"'phase' must be one of {sorted(scenarios.SCENARIOS)}")
        ev["phase"] = phase

    for key, limit in (("target", 40), ("witness", 40), ("note", 200), ("name", 60)):
        value = _text(body, key, limit)
        if value is not None:
            ev[key] = value

    if typ == "step":
        if not ev.get("name"):
            raise Invalid("'name' is required for a step")
        status = body.get("status", "INFO")
        if status not in STEP_STATUS:
            raise Invalid(f"'status' must be one of {sorted(STEP_STATUS)}")
        ev["status"] = status
        seconds = body.get("seconds")
        if seconds is not None:
            if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or seconds < 0:
                raise Invalid("'seconds' must be a number >= 0")
            ev["seconds"] = seconds
    elif typ == "phase_end":
        status = body.get("status", "PASS")
        if status not in STEP_STATUS:
            raise Invalid(f"'status' must be one of {sorted(STEP_STATUS)}")
        ev["status"] = status
    elif typ == "run_end":
        status = body.get("status", "PASS")
        if status not in RUN_END_STATUS:
            raise Invalid(f"'status' must be one of {sorted(RUN_END_STATUS)}")
        ev["status"] = status
    return ev


@bp.get("/api/health")
def health():
    return jsonify(status="ok")


@bp.get("/api/chaos/state")
def get_state():
    return jsonify(state.snapshot())


@bp.post("/api/chaos/event")
def post_event():
    if request.remote_addr not in LOOPBACK:
        return jsonify(error="events are accepted from localhost only"), 403
    body = request.get_json(silent=True)   # RequestEntityTooLarge (413) is not swallowed
    try:
        event = validate(body)
    except Invalid as exc:
        return jsonify(error=str(exc)), 400
    state.apply(event)
    return "", 204


def configure_logging(log_dir, filename=None):
    """Send the HTTP server's access log (and Flask's) to a file, never to the terminal.

    `filename` (full path) wins over `log_dir`. Returns the log file path. Safe to call twice.
    """
    if filename:
        path = Path(filename)
        path.parent.mkdir(parents=True, exist_ok=True)
    else:
        log_dir = Path(log_dir)
        log_dir.mkdir(parents=True, exist_ok=True)
        path = log_dir / "chaos-webui.log"
    handler = logging.FileHandler(path, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    for name in ("werkzeug", "flask.app"):
        lg = logging.getLogger(name)
        lg.handlers = [handler]
        lg.setLevel(logging.INFO)
        lg.propagate = False
    return path
