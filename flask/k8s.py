import json
import sys
from pathlib import Path
from pprint import pprint

import requests
import urllib3
from kubernetes import client, config
from requests.auth import HTTPBasicAuth

urllib3.disable_warnings()

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from appconfig import Config

cfg = Config()
aaDbName = cfg.aa_db
region1, region2 = cfg.clusters[0], cfg.clusters[1]

for region in region1, region2:
    config.load_kube_config(context=f"{region}")
    user, pwd = cfg.admin_credentials(region)
    basic = HTTPBasicAuth(user, pwd)
    api_host = cfg.api_host(region)

    r=requests.get(f"https://{api_host}/v1/nodes", auth=basic, verify=False)
    for node in json.loads(r.text):
        print(node['status'])
        print(node['uid'])
        #pprint(node)

    r=requests.get(f"https://{api_host}/v1/shards", auth=basic, verify=False)
    for shard in json.loads(r.text):
        print(shard['status'])
        print(shard['role'])
        print(shard['node_uid'])
        print(shard['bdb_uid'])
        print(shard['detailed_status'])

        pprint(shard)

    rec=client.CustomObjectsApi().get_namespaced_custom_object(
        namespace=cfg.ns,
        group="app.redislabs.com",
        version="v1",
        #pretty=True,
        name=cfg.rec_of[region],
        plural="redisenterpriseclusters"
        )
    pprint(rec["status"])


    rec=client.CustomObjectsApi().get_namespaced_custom_object(
        namespace=cfg.ns,
        group="app.redislabs.com",
        version="v1alpha1",
        #pretty=True,
        name=aaDbName,
        plural="redisenterpriseactiveactivedatabases"
        )
    pprint(rec["status"])