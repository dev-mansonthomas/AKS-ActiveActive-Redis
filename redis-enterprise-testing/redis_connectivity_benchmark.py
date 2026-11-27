import redis
import datetime
import logging
import sys
from pathlib import Path
import random
import string

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from appconfig import Config  # noqa: E402

cfg = Config()
aaDbName = cfg.aa_db
dns_suffix = cfg.dns_zone
# regions = cloud cluster names (kube contexts); hosts use the REC name (rec-a).
regions = cfg.clusters


logging.basicConfig(level=logging.INFO, format='[%(asctime)s] %(levelname)s: %(message)s')
log = logging.getLogger(__name__)

log.info(f"CLUSTERS: {regions}")
log.info(f"DNS_SUFFIX: {dns_suffix}")

def randStr(chars=string.ascii_uppercase + string.digits, N=10):
    return ''.join(random.choice(chars) for _ in range(N))

redis_clients = {}
for region in regions:
    log.info(f"🔌 Connecting to Redis cluster in region: {region} (host: {cfg.db_host(region)})")
    redis_clients[region] = redis.StrictRedis(
        host=cfg.db_host(region),
        port=443, db=0,
        password=cfg.db_password(regions[0]),
        ssl=True,
        ssl_cert_reqs=None,
    )

log.info("### Basic ping test ###")
for region in regions:
    log.info(f"{region} ping: {redis_clients[region].ping()}")
log.info("")

niter = 100
r1 = {region: [] for region in regions}
log.info(f"### Ping test for {niter} iterations###")
for i in range(niter):
    for region in regions:
        r_start = datetime.datetime.now()
        redis_clients[region].ping()
        r_end = datetime.datetime.now()
        r1[region].append((r_end - r_start).microseconds)

for region in regions:
    values = r1[region]
    avg = sum(values) / len(values)
    minimum = min(values)
    maximum = max(values)
    log.info(f"[{region}] PING latencies over {niter} iterations:")
    log.info(f"  ➤ Avg: {avg:.2f} µs | Min: {minimum} µs | Max: {maximum} µs")
log.info("")

r1 = {region: [] for region in regions}
log.info(f"### ActiveActive sync test for {niter} iterations###")
for i in range(niter):
    for src in regions:
        timestamp = datetime.datetime.now().microsecond
        key = f"{src}-aa"
        redis_clients[src].set(name=key, value=timestamp)

        for dst in [r for r in regions if r != src]:
            try:
                retrieved = redis_clients[dst].get(name=key)
                if retrieved is None:
                    continue
                r_dst = int(retrieved)
                delay = timestamp - r_dst
                if delay < 0:
                    delay += 1_000_000  # adjust if wrapped
                if i >= 1:
                    r1[dst].append(delay)
            except Exception as e:
                log.warning(f"⚠️ Failed to get key '{key}' from {dst}: {e}")

for region in regions:
    avg = sum(r1[region]) / len(r1[region])
    maximum = max(r1[region])
    minimum = min(r1[region])
    log.info(f"[{region}] AA Sync delays over {niter} iterations:")
    log.info(f"  ➤ Avg: {avg:.2f} µs | Min: {minimum} µs | Max: {maximum} µs")
log.info("")

niter = 10
payload_size = 6000000
str = randStr(N=payload_size)
log.info(f"### Large payload for {niter} iterations###")
log.info(f"### Payload size {payload_size}###")
r1 = {region: [] for region in regions}
for i in range(niter):
    for region in regions:
        log.info(f"Iteration {i} for region {region}")
        r1_start = datetime.datetime.now()
        redis_clients[region].set(name=f"{region}", value=str)
        r1_end = datetime.datetime.now()
        r1[region].append((r1_end - r1_start).microseconds)

for region in regions:
    avg = sum(r1[region]) / len(r1[region])
    minimum = min(r1[region])
    maximum = max(r1[region])
    log.info(f"[{region}] SET {payload_size} bytes over {niter} iterations:")
    log.info(f"  ➤ Avg: {avg:.2f} µs | Min: {minimum} µs | Max: {maximum} µs")

if __name__ == "__main__":
    pass
