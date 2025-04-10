import redis
import time
import random
import string
import logging
import os
import sys

logging.basicConfig(level=logging.INFO, format='[%(asctime)s] %(message)s')

REDIS_HOST = os.environ.get("REDIS_HOST", "localhost")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))

log = logging.getLogger()

try:
    log.info(f"🔌 Trying to connect to Redis at {REDIS_HOST}:{REDIS_PORT}")
    r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    r.ping()
    log.info(f"✅ Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
except Exception as e:
    log.error(f"❌ Failed to connect to Redis at {REDIS_HOST}:{REDIS_PORT}")
    log.error(f"Error: {e}")
    sys.exit(1)

KEY_PREFIX = "loadtest:"
DELAY = 0.01

def random_key():
    return KEY_PREFIX + ''.join(random.choices(string.ascii_letters, k=8))

while True:
    key = random_key()
    value = ''.join(random.choices(string.ascii_letters + string.digits, k=100))
    try:
        r.set(key, value, ex=30)
        log.info(f"SET {key}")
    except Exception as e:
        log.error(f"Redis error: {e}")
        break
    time.sleep(DELAY)