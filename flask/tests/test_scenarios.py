import scenarios

IDS = {"health", "pod", "node", "region", "region-recover"}


def test_ids_and_fields():
    assert set(scenarios.SCENARIOS) == IDS
    for sid, sc in scenarios.SCENARIOS.items():
        for field in ("title", "simulate", "expect"):
            assert isinstance(sc[field], str) and sc[field].strip(), (sid, field)
        assert isinstance(sc["actions"], list) and sc["actions"], sid
        assert all(isinstance(a, str) and a for a in sc["actions"])
        assert "typical" in sc


def test_selectable_ids_are_canonical_and_exclude_health():
    assert scenarios.SELECTABLE == ["pod", "node", "region", "region-recover"]


def test_region_text_is_honest_about_manual_recovery():
    text = scenarios.SCENARIOS["region"]["expect"].lower()
    assert "not fully automatic" in text
