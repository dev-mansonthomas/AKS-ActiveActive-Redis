#!/usr/bin/env python3
import sys
import redis

if len(sys.argv) != 4:
    print("Usage: get_key.py <host> <port> <key>")
    sys.exit(1)

host = sys.argv[1]
port = int(sys.argv[2])
key = sys.argv[3]

r = redis.Redis(
    host=host,
    port=port,
    ssl=True,
    ssl_cert_reqs=None,
    ssl_ca_certs=None
)

value = r.get(key)
print(f"🔎 Key '{key}' on {host}:{port} = {int(value) if value else 0}")