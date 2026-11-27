from chaos_state import MAX_STEPS, STALE_AFTER, ChaosState


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def make():
    clock = Clock()
    return ChaosState(clock=clock), clock


def ev(type_, **kw):
    return {"type": type_, "run_id": kw.pop("run_id", "r1"), **kw}


def test_no_run_initially():
    st, _ = make()
    snap = st.snapshot()
    assert snap["run"] is None and snap["active"] is False


def test_full_cycle():
    st, clock = make()
    st.apply(ev("run_start", target="rec-a", witness="rec-b"))
    s = st.snapshot()
    assert s["active"] and s["run"]["status"] == "RUNNING" and s["run"]["target"] == "rec-a"

    st.apply(ev("phase_start", phase="pod"))
    r = st.snapshot()["run"]
    assert r["phase"] == "pod" and r["awaiting_operator"] is True
    assert r["scenario"]["title"] == "Pod failure" and r["scenario"]["actions"]

    clock.t += 5
    st.apply(ev("inject", phase="pod", note="kubectl delete pod rec-a-0 --force"))
    r = st.snapshot()["run"]
    assert r["awaiting_operator"] is False and r["injected_at"] == 1005.0
    assert r["steps"][-1]["status"] == "INFO" and "rec-a-0" in r["steps"][-1]["note"]

    st.apply(ev("step", phase="pod", name="pod-recovery", status="PASS", seconds=42))
    r = st.snapshot()["run"]
    assert r["recovered_seconds"] == 42
    assert r["steps"][-1]["name"] == "pod-recovery"

    st.apply(ev("phase_end", phase="pod", status="PASS"))
    st.apply(ev("run_end", status="PASS"))
    s = st.snapshot()
    assert s["active"] is False and s["run"]["status"] == "PASS" and s["run"]["failed"] == 0


def test_fail_step_makes_run_fail_and_counts():
    st, _ = make()
    st.apply(ev("run_start"))
    st.apply(ev("step", phase="node", name="node-data", status="FAIL"))
    st.apply(ev("step", phase="node", name="node-recovery", status="FAIL", seconds=900))
    st.apply(ev("run_end", status="PASS"))          # caller says PASS but a step failed
    r = st.snapshot()["run"]
    assert r["status"] == "FAIL" and r["failed"] == 2


def test_new_run_start_aborts_previous_running_run():
    st, _ = make()
    st.apply(ev("run_start", run_id="a"))
    st.apply(ev("run_start", run_id="b"))
    snap = st.snapshot()
    assert snap["run"]["run_id"] == "b"
    assert st.previous_status == "ABORTED"


def test_unknown_run_id_creates_run_implicitly():
    st, _ = make()
    st.apply(ev("step", run_id="late", phase="pod", name="pod-recovery", status="PASS", seconds=3))
    r = st.snapshot()["run"]
    assert r["run_id"] == "late" and r["steps"][0]["name"] == "pod-recovery"


def test_event_for_other_run_id_is_ignored_when_run_exists_and_is_finished():
    st, _ = make()
    st.apply(ev("run_start", run_id="a"))
    st.apply(ev("run_end", run_id="a", status="PASS"))
    st.apply(ev("step", run_id="a", phase="pod", name="x", status="PASS"))   # late, same run: kept
    assert len(st.snapshot()["run"]["steps"]) == 1


def test_stale_after_silence():
    st, clock = make()
    st.apply(ev("run_start"))
    clock.t += STALE_AFTER + 1
    s = st.snapshot()
    assert s["run"]["status"] == "STALE" and s["active"] is False


def test_step_cap():
    st, _ = make()
    st.apply(ev("run_start"))
    for i in range(MAX_STEPS + 50):
        st.apply(ev("step", phase="pod", name=f"s{i}", status="INFO"))
    steps = st.snapshot()["run"]["steps"]
    assert len(steps) == MAX_STEPS and steps[-1]["name"] == f"s{MAX_STEPS + 49}"


def test_unknown_phase_has_no_scenario_but_does_not_raise():
    st, _ = make()
    st.apply(ev("run_start"))
    st.apply(ev("phase_start", phase="weird"))
    assert st.snapshot()["run"]["scenario"] is None


def test_snapshot_is_a_copy():
    st, _ = make()
    st.apply(ev("run_start"))
    snap = st.snapshot()
    snap["run"]["steps"].append("x")
    assert st.snapshot()["run"]["steps"] == []
