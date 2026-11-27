import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from pathlib import Path

import chaos_api
import redis
import requests
import urllib3
from requests.auth import HTTPBasicAuth

from flask import Flask, abort, jsonify, render_template

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = chaos_api.MAX_BODY
app.config["TEMPLATES_AUTO_RELOAD"] = True   # edit the page, reload the browser: no restart needed
app.register_blueprint(chaos_api.bp)


sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
import appconfig
from appconfig import Config

cfg = Config()
aaDbName = cfg.aa_db
dns_suffix = cfg.dns_zone
# region == kubectl context == cloud cluster name; the REC name differs (rec-a).
region1, region2 = cfg.clusters[0], cfg.clusters[1]
_db_password = {}   # region -> (monotonic time, password)


def db_password(region):
    """Read from the <db>-password secret and kept for a while. NOT kept when there is none yet (the
    console may start before step 04 created it) or when the read failed; dropped on WRONGPASS."""
    hit = _db_password.get(region)
    if hit and time.monotonic() - hit[0] < appconfig.CACHE_TTL:
        return hit[1]
    try:
        pw = cfg.db_password(region)
    except Exception:  # noqa: BLE001 - any k8s/auth error just means "no password yet"
        return None
    if pw is not None:
        _db_password[region] = (time.monotonic(), pw)
    return pw


def connect_to_redis(region):
    if region not in cfg.rec_of:
        return None
    host = cfg.db_host(region)
    try:
        r = redis.StrictRedis(
            host=host,
            port=443, db=0,
            password=db_password(region),
            ssl=True,
            ssl_cert_reqs=None,
            decode_responses=True,
            socket_timeout=1
        )
        r.ping()  # Check if the connection is alive
        return r
    except redis.AuthenticationError:
        _db_password.pop(region, None)     # the rig was redeployed: the password changed
        return None
    except (redis.ConnectionError, redis.TimeoutError):
        return None

# Every route must answer within ROUTE_DEADLINE seconds even if a region is dead: during a
# chaos run the page polls these continuously and must show "unreachable", not freeze.
ROUTE_DEADLINE = 4.0
_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="probe")


def within_deadline(fn, *args):
    """Run fn(*args) with a hard deadline. Raises TimeoutError; the worker thread ends when
    the call's own network timeouts expire."""
    future = _pool.submit(fn, *args)
    try:
        return future.result(timeout=ROUTE_DEADLINE)
    except FutureTimeout as exc:
        raise TimeoutError(f"no answer within {ROUTE_DEADLINE}s") from exc


@app.route('/redis/<region>')
def redis_test(region):
    if region not in cfg.rec_of:
        abort(404)
    try:
        redis_connection = within_deadline(connect_to_redis, region)
    except Exception:  # noqa: BLE001 - a dead region is a normal state here
        redis_connection = None
    if redis_connection:
        return jsonify(message="Connected to Redis successfully")
    return jsonify(message="Error: Redis is not available")


@app.route('/redisha')
def redisha():
    """First region (in config order) that answers; both are probed in parallel under one deadline."""
    futures = {region: _pool.submit(connect_to_redis, region) for region in (region1, region2)}
    deadline = time.monotonic() + ROUTE_DEADLINE
    for region in (region1, region2):
        try:
            if futures[region].result(timeout=max(0.0, deadline - time.monotonic())):
                return jsonify(message=f"Connected to Redis {region} successfully")
        except Exception:  # noqa: BLE001 - timeout or error: this region is not usable
            app.logger.info("redisha: %s did not answer", region)
    return jsonify(message="Error: Redis is not available in both regions")


_io_pool = ThreadPoolExecutor(max_workers=12, thread_name_prefix="rest")   # sub-requests of one cluster fetch


def _check_auth(region, resp):
    """A 401 means the cached admin credentials are stale (rig redeployed): drop them, fail this poll."""
    if getattr(resp, "status_code", 200) == 401:
        cfg.invalidate(region)
        raise PermissionError(f"{region}: REST API refused the admin credentials")


def _fetch_cluster(region):
    """Nodes, shards and node roles of a Redis Enterprise cluster through its REST API (may raise).

    /v1/nodes/status adds each node's role and hostname (the REST API says master/slave; the page says
    primary/replica, like the shards). It is optional: if it fails the page just does not show the primary."""
    user, pwd = cfg.admin_credentials(region)
    basic = HTTPBasicAuth(user, pwd)
    api_host = cfg.api_host(region)
    timeout = (2, 2)   # connect, read

    def get(path):
        resp = requests.get(f"https://{api_host}{path}", auth=basic, verify=False, timeout=timeout)
        _check_auth(region, resp)
        return json.loads(resp.text)

    f_nodes, f_shards, f_status = (_io_pool.submit(get, path)
                                   for path in ("/v1/nodes", "/v1/shards", "/v1/nodes/status"))
    nodes, shards = f_nodes.result(), f_shards.result()
    ROLE = {"master": "primary", "slave": "replica"}
    try:
        status = f_status.result()
        if not isinstance(status, dict):
            status = {}
    except Exception:  # noqa: BLE001 - optional
        status = {}

    res = {}
    for node in nodes:
        st = status.get(str(node['uid'])) or {}
        res[f"node_{node['uid']}"] = {'status': node['status'], 'uid': node['uid'], 'shards': [],
                                      'role': ROLE.get(st.get('role')), 'hostname': st.get('hostname')}
    for shard in shards:
        role = ROLE.get(shard['role'], shard['role'])
        entry = res.setdefault(f"node_{shard['node_uid']}",
                               {'status': 'unknown', 'uid': shard['node_uid'], 'shards': [],
                                'role': None, 'hostname': None})
        entry['shards'].append({'status': shard['status'], 'role': role, 'bdb_uid': shard['bdb_uid'],
                                'detailed_status': shard['detailed_status']})
    return res


def get_cluster(region):
    try:
        return jsonify(within_deadline(_fetch_cluster, region))
    except Exception:  # noqa: BLE001 - unreachable region, kube error, bad payload...
        return jsonify(message="Error: Cannot connect to Redis Enterprise cluster")


def _fetch_aadb(region):
    """Status of the Active-Active database and of each sync link, from /v1/bdbs (may raise).

    Only whitelisted fields leave this function: the raw crdt_sources entries carry a peer URI with
    credentials and certificates."""
    user, pwd = cfg.admin_credentials(region)
    resp = requests.get(f"https://{cfg.api_host(region)}/v1/bdbs", auth=HTTPBasicAuth(user, pwd),
                        verify=False, timeout=(2, 2),
                        params={"fields": "uid,name,status,crdt,crdt_sync,crdt_sources"})
    _check_auth(region, resp)
    bdbs = [b for b in json.loads(resp.text) if isinstance(b, dict) and b.get("crdt")]
    db = next((b for b in bdbs if b.get("name") == cfg.aa_db), None)
    if db is None:
        raise LookupError(f"Active-Active database '{cfg.aa_db}' not found")
    links = []
    for src in db.get("crdt_sources") or []:
        sni = src.get("replication_tls_sni") or ""
        parts = sni.split(".")
        links.append({"source": parts[1] if len(parts) > 1 else sni or "?",
                      "status": src.get("status"), "lag": src.get("lag"),
                      "error": str(src.get("last_error") or "")[:120]})
    return {"name": db.get("name"), "status": db.get("status"), "links": links}


@app.route('/aadb/<region>')
def aadb(region):
    if region not in cfg.rec_of:
        abort(404)
    try:
        return jsonify(within_deadline(_fetch_aadb, region))
    except Exception:  # noqa: BLE001
        return jsonify(message="Error: Cannot read the Active-Active database status")


@app.route('/cluster/<region>')
def cluster(region):
    if region not in cfg.rec_of:
        abort(404)
    return get_cluster(region)


BRAND_DIR = Path(__file__).resolve().parent / "static" / "brand"
LOGO_FILE = "Redis_Logo_Red_RGB.svg"


@app.route('/')
def index():
    # The Redis logo is a trademark asset: not in the repo. Shown if you dropped the official
    # SVG (brand.redis.io) into flask/static/brand/.
    logo = f"brand/{LOGO_FILE}" if (BRAND_DIR / LOGO_FILE).is_file() else None
    return render_template('index.html', region1=region1, region2=region2, logo=logo)


def server_options():
    """Where and how the console listens: localhost only, no Werkzeug debugger."""
    return {"host": "127.0.0.1", "port": int(os.environ.get("CHAOS_WEBUI_PORT", "5050")),
            "debug": False, "use_reloader": False, "threaded": True}


def log_dir():
    return os.environ.get("CHAOS_WEBUI_LOG_DIR") or str(Path(__file__).resolve().parent.parent / "debug")


if __name__ == '__main__':
    chaos_api.configure_logging(log_dir(), os.environ.get("CHAOS_WEBUI_LOG_FILE"))
    app.run(**server_options())
