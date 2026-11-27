"""In-memory state of the current chaos run, fed by `scripts/chaos.sh` events.

One run is kept (the last one). Events are assumed already validated by
chaos_api; this module never raises on odd ordering: a console restarted in the
middle of a run must keep working (see docs/specs/chaos-webui.md).
"""
import copy
import threading
import time

import scenarios

STALE_AFTER = 30 * 60      # seconds without any event before a RUNNING run is shown as STALE
MAX_STEPS = 200

_FINISHED = ("PASS", "FAIL", "ABORTED")


class ChaosState:
    def __init__(self, clock=time.time):
        self._clock = clock
        self._lock = threading.Lock()
        self._run = None
        self.previous_status = None   # status given to the run replaced by the last run_start

    # ------------------------------------------------------------------ events
    def apply(self, event):
        with self._lock:
            now = self._clock()
            typ = event["type"]
            run_id = event["run_id"]

            if typ == "run_start":
                if self._run is not None and self._run["status"] == "RUNNING":
                    self.previous_status = "ABORTED"
                self._run = self._new_run(run_id, now, event)
                return

            if self._run is None or self._run["run_id"] != run_id:
                if self._run is not None and self._run["status"] == "RUNNING":
                    self.previous_status = "ABORTED"
                self._run = self._new_run(run_id, now, event)   # implicit run (console restarted)
            run = self._run
            run["last_event"] = now

            phase = event.get("phase")
            if typ == "phase_start":
                run["phase"] = phase
                run["phase_started_at"] = now
                run["injected_at"] = None
                run["recovered_seconds"] = None
                run["awaiting_operator"] = True
                run["scenario"] = self._scenario(phase)
            elif typ == "inject":
                if phase and run["phase"] != phase:
                    run["phase"] = phase
                    run["scenario"] = self._scenario(phase)
                run["injected_at"] = now
                run["awaiting_operator"] = False
                self._add_step(run, now, phase, "inject", "INFO", None, event.get("note", ""))
            elif typ == "step":
                status = event.get("status", "INFO")
                name = event.get("name", "")
                self._add_step(run, now, phase or run["phase"], name, status,
                               event.get("seconds"), event.get("note", ""))
                if status == "PASS" and name.endswith("-recovery") and event.get("seconds") is not None:
                    run["recovered_seconds"] = event["seconds"]
            elif typ == "phase_end":
                run["awaiting_operator"] = False
            elif typ == "run_end":
                run["awaiting_operator"] = False
                status = event.get("status", "PASS")
                if status not in _FINISHED:
                    status = "FAIL"
                if run["failed"] > 0 and status == "PASS":
                    status = "FAIL"
                run["status"] = status
                run["finished_at"] = now

    # ---------------------------------------------------------------- snapshot
    def snapshot(self):
        with self._lock:
            now = self._clock()
            if self._run is None:
                return {"server_time": now, "active": False, "run": None}
            run = copy.deepcopy(self._run)
            if run["status"] == "RUNNING" and now - run["last_event"] > STALE_AFTER:
                run["status"] = "STALE"
            return {"server_time": now, "active": run["status"] == "RUNNING", "run": run}

    # ----------------------------------------------------------------- helpers
    @staticmethod
    def _scenario(phase):
        sc = scenarios.SCENARIOS.get(phase)
        return copy.deepcopy(sc) if sc else None

    @staticmethod
    def _add_step(run, now, phase, name, status, seconds, note):
        if status == "FAIL":
            run["failed"] += 1
        run["steps"].append({"t": now, "phase": phase, "name": name, "status": status,
                             "seconds": seconds, "note": note})
        if len(run["steps"]) > MAX_STEPS:
            del run["steps"][: len(run["steps"]) - MAX_STEPS]

    @staticmethod
    def _new_run(run_id, now, event):
        return {
            "run_id": run_id, "target": event.get("target"), "witness": event.get("witness"),
            "started_at": now, "last_event": now, "phase": None, "phase_started_at": None,
            "injected_at": None, "recovered_seconds": None, "awaiting_operator": False,
            "status": "RUNNING", "finished_at": None, "failed": 0, "steps": [], "scenario": None,
        }
