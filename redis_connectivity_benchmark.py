import redis
import datetime
import logging
import subprocess
import random
import string

def get_config_var(name):
    try:
        value = subprocess.check_output(
            f"source ./config.sh >/dev/null 2>&1 && echo -n ${name}",
            shell=True,
            executable="/bin/bash"
        )
        return value.decode("utf-8").strip() or None
    except subprocess.CalledProcessError:
        return None

# Load configuration from config.sh
cluster1 = get_config_var("CLUSTER1")
cluster2 = get_config_var("CLUSTER2")
cluster3 = get_config_var("CLUSTER3")
dns_suffix = get_config_var("DNS_ZONE")

regions = [c for c in [cluster1, cluster2, cluster3] if c]


logging.basicConfig(level=logging.INFO, format='[%(asctime)s] %(levelname)s: %(message)s')
log = logging.getLogger(__name__)

log.info(f"CLUSTERS: {regions}")
log.info(f"DNS_SUFFIX: {dns_suffix}")

def randStr(chars=string.ascii_uppercase + string.digits, N=10):
    return ''.join(random.choice(chars) for _ in range(N))

redis_clients = {}
for region in regions:
    log.info(f"🔌 Connecting to Redis cluster in region: {region} (host: crdb-anton-db.redis-{region}.{dns_suffix})")
    redis_clients[region] = redis.StrictRedis(
        host=f"crdb-anton-db.{region}.{dns_suffix}",
        port=443, db=0,
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
