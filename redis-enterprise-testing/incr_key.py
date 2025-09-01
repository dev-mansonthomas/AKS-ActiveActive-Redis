#!/usr/bin/env python3
import sys
import redis
import time

if len(sys.argv) < 5 or len(sys.argv) > 6:
    print("Usage: incr_key.py <host> <port> <key> <count> [pipe]")
    sys.exit(1)

host = sys.argv[1]
port = int(sys.argv[2])
key = sys.argv[3]
count = int(sys.argv[4])
use_pipeline = len(sys.argv) == 6 and sys.argv[5] == "pipe"

# Connexion Redis en TLS (443), sans vérification
r = redis.Redis(
    host=host,
    port=port,
    ssl=True,
    ssl_cert_reqs=None,
    ssl_ca_certs=None
)

print(f"🔁 Incrementing key '{key}' {count} times on {host}:{port} using {'pipeline' if use_pipeline else 'standard'} mode...")

if use_pipeline:
    pipe = r.pipeline()
    for i in range(count):
        pipe.incr(key)
        if (i + 1) % 10 == 0:
            pipe.execute()
            time.sleep(0.01)
    if count % 10 != 0:
        pipe.execute()
else:
    for _ in range(count):
        r.incr(key)
        time.sleep(0.01)

print(f"✅ Done for {host}:{port}")