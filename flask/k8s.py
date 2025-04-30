from kubernetes import client, config
from pprint import pprint
import base64
from requests.auth import HTTPBasicAuth
import requests
import subprocess
import json
import urllib3
urllib3.disable_warnings()

def get_config_var(name, config_path="../config.sh"):
    try:
        with open(config_path, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith(f"{name}="):
                    value = line.split("=", 1)[1].strip().strip('"').strip("'")
                    return value if value else None
        return None
    except FileNotFoundError:
        return None

aaDbName = get_config_var("AA_DB_NAME")
region1 = get_config_var("CLUSTER1")
region2 = get_config_var("CLUSTER2")
dns_suffix = get_config_var("DNS_ZONE")

for region in region1, region2:
    config.load_kube_config(context=f"{region}")

    v1 = client.CoreV1Api()
    secret=v1.read_namespaced_secret(f"rec-{region}", "rec")
    user=base64.b64decode(secret.data['username'])
    pwd=base64.b64decode(secret.data['password'])
    basic = HTTPBasicAuth(user.decode('utf-8'), pwd.decode('utf-8'))

    r=requests.get(f"https://api.{region}.{dns_suffix}/v1/nodes", auth=basic, verify=False)
    for node in json.loads(r.text):
        print(node['status'])
        print(node['uid'])
        #pprint(node)

    r=requests.get(f"https://api.{region}.{dns_suffix}/v1/shards", auth=basic, verify=False)
    for shard in json.loads(r.text):
        print(shard['status'])
        print(shard['role'])
        print(shard['node_uid'])
        print(shard['bdb_uid'])
        print(shard['detailed_status'])

        pprint(shard)

    rec=client.CustomObjectsApi().get_namespaced_custom_object(
        namespace="rec",
        group="app.redislabs.com",
        version="v1",
        #pretty=True,
        name=f"rec-{region}",
        plural="redisenterpriseclusters"
        )
    pprint(rec["status"])


    rec=client.CustomObjectsApi().get_namespaced_custom_object(
        namespace="rec",
        group="app.redislabs.com",
        version="v1alpha1",
        #pretty=True,
        name=aaDbName,
        plural="redisenterpriseactiveactivedatabases"
        )
    pprint(rec["status"])