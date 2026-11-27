"""Every third-party module the console imports must be declared in requirements.txt (D4)."""
import ast
import sys
from pathlib import Path

FLASK_DIR = Path(__file__).resolve().parent.parent
# import name -> distribution name
DIST = {"flask": "flask", "redis": "redis", "requests": "requests", "urllib3": "urllib3",
        "kubernetes": "kubernetes"}


def _imports(path):
    tree = ast.parse(path.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                yield a.name.split(".")[0]
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            yield node.module.split(".")[0]


def test_imports_are_declared_and_pinned():
    declared = {}
    for line in (FLASK_DIR / "requirements.txt").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            name, _, ver = line.partition("==")
            declared[name.lower()] = ver
    used = set()
    for py in FLASK_DIR.glob("*.py"):
        used |= {m for m in _imports(py) if m in DIST}
    missing = {DIST[m] for m in used} - set(declared)
    assert not missing, f"imported but not in flask/requirements.txt: {sorted(missing)}"
    assert all(declared.values()), "every requirement must be pinned with =="
    assert sys.version_info >= (3, 9)
