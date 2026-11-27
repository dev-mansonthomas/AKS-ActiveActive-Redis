from pathlib import Path

import appconfig


def test_config_reads_file_named_by_env(monkeypatch, tmp_path):
    cfg_file = tmp_path / "c.sh"
    cfg_file.write_text("CLUSTER1=x1\nREC_NAME1=ra\nCLUSTER2=x2\nREC_NAME2=rb\nAA_DB_NAME=d\nDNS_ZONE=z.example\n")
    monkeypatch.setenv("RE_CONFIG_FILE", str(cfg_file))
    cfg = appconfig.Config()
    assert cfg.clusters == ["x1", "x2"]
    assert cfg.db_host("x1") == "d-db.ra.z.example"


def test_default_is_repo_config_sh(monkeypatch):
    monkeypatch.delenv("RE_CONFIG_FILE", raising=False)
    assert appconfig.default_config_path() == Path(appconfig.REPO_ROOT) / "config.sh"
