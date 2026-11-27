"""Shared fixtures. The console reads config.sh through common/appconfig.py; tests point it
at a fixture file so they need neither a real config.sh nor a cluster."""
import os
import sys
from pathlib import Path

import pytest

TESTS = Path(__file__).resolve().parent
FLASK_DIR = TESTS.parent
REPO = FLASK_DIR.parent

os.environ["RE_CONFIG_FILE"] = str(TESTS / "fixtures" / "config.test.sh")
os.environ.setdefault("CHAOS_WEBUI_LOG_DIR", str(TESTS / ".logs"))
for p in (str(FLASK_DIR), str(REPO / "common")):
    if p not in sys.path:
        sys.path.insert(0, p)


@pytest.fixture()
def app_module():
    import app as app_mod
    return app_mod


@pytest.fixture()
def client(app_module):
    app_module.app.config["TESTING"] = True
    return app_module.app.test_client()
