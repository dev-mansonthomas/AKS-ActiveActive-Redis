# Deploying Redis Enterprise Active Active on AKS & Demo

This repo contains deployment scripts and web monitoring dashboard for Active Active Redis Enterprise deployment in two Azure Regions.
This repo will allow you to showcase the 99.999% HA capabilities of RedisEnterprise

![alt text](images/flask_app.png)

# Prerequisites and Configuration

## Prerequisites

You'll need : 
* A temporary license for Redis Enterprise if you want to create more than 4 shards
* A domain name (if you don't have it, try Gandi.net)
* Azure account
* 2 regions, with each 24 vCPU, supporting AKZ & Azure Identity Management
  * this can be lowered to 2 vCPU per node, so 6 per region, total of 12 for the active/active setup

_Software on your machine_

- bash 5 
  - `brew install bash` 
  - add `/opt/homebrew/opt/bash` to `/etc/shells`
  - `sudo chsh -s "$(brew --prefix)/bin/bash" $USER`
- az CLI
- OpenTofu
- kubectl
- helm
- jq (jquery)
- python3
- watch

## Summary

This section will walk through Azure configuration and the config.sh configuration

* Login in Azure
* Check that you can get your subscription ID
* Configure Azure to manage a subdomain of your DNS domain
* Configure your domain name to delegate that subdomain to Azure
* Find a region with sufficient quota for the two K8S cluster for Redis Enterprise
* 

## Azure subscription and CLI

You need t be able to successfully authenticate your azure cli to the Azure Subscription:
```shell
az login
```

## Fetch Azure subscription ID
```shell
az account show --query id -o tsv
```

ex: e48e7b4e-f9d8-4d23-81ac-d204f77b00ac (UUID v4 format)

## Azure DNS Zone

Redis Enterprise ActiveActive requires FQDN (NOT the public IP) of the ingress services for both participating clusters. 
In your Azure Subscription create DNS Zone and make sure it resolvable by the public DNS. 
You can use a subdomain of the existing domain hosted elsewhere.

### Azure DNS Zone creation

Let's take the Top Level Domain like **paquerette.com**.

We'll delegate a subdomain of this domain to Azure Name Servers to give FQDN to our clusters. For exemple : **demo.paquerette.com**.

Update the config.sh with domain.

```shell
DNS_ZONE=demo.paquerette.com
```

Create the dns zone in Azure which will provide the Name Servers that will manage this subdomain.

Choose a ResourceGroup, exemple "ThomasManson" and set it to config.sh

```shell
# Resource Group zone where DNS is defined
DNS_RESOURCE_GROUP=ThomasManson
```
And then run this command, replacing **_RESOURCE_GROUP_** with your resource group.

```shell
az network dns zone create \
  --resource-group RESOURCE_GROUP \
  --name demo.paquerette.com

{
  "etag": "c....0",
  "id": "/subscriptions/e....7/resourceGroups/thomasmanson/providers/Microsoft.Network/dnszones/demo.paquerette.com",
  "location": "global",
  "maxNumberOfRecordSets": 10000,
  "name": "demo.paquerette.com",
  "nameServers": [
    "ns1-04.azure-dns.com.",
    "ns2-04.azure-dns.net.",
    "ns3-04.azure-dns.org.",
    "ns4-04.azure-dns.info."
  ],
  "numberOfRecordSets": 2,
  "resourceGroup": "thomasmanson",
  "tags": {},
  "type": "Microsoft.Network/dnszones",
  "zoneType": "Public"
}
```
Copy the nameservers array from the response to use the values in your DNS Zone.

### Update a subdomain of your domain with Azure Name Servers

Go to your registrar & edit the DNS zone of your domain as follow : 
Don’t forget the trailing “.” at the end of the Azure DNS names.
```
demo 10800 IN NS ns1-04.azure-dns.com.
demo 10800 IN NS ns2-04.azure-dns.net.
demo 10800 IN NS ns3-04.azure-dns.org.
demo 10800 IN NS ns4-04.azure-dns.info.
```
Verify (DNS propagation can take a few minutes, it's usually a matter of seconds these days) : 
```shell
~ ➜ dig NS demo.paquerette.com +short
ns4-04.azure-dns.info.
ns2-04.azure-dns.net.
ns3-04.azure-dns.org.
ns1-04.azure-dns.com.
```

## Azure regions

Determine in which regions you want to have your two clusters setup
You'll need to check that you have enough quota to successfully create them.

### Check the current quota

You need 24 CPU in per regions (3 nodes x8 CPUs x 2 regions) 

List all regions : 
```shell
az account list-locations --output table
```

Check two regions that has at least 24 CPU per region

```shell
az vm list-usage --location francecentral --output table
az vm list-usage --location ukwest --output table
```
Ensure that you have more than 24 in both regions you choose.

Ex:
```
Standard Dv3 Family vCPUs                 0               10
Standard DSv3 Family vCPUs                0               100
```
Both regions must support K8S & Identity.

### Edit config.sh

Edit the config.sh with the two regions

```shell
CLUSTER1=redis-francecentral
CLUSTER2=redis-ukwest
```

### Edit the variables.tf with the machine family 
 
```
variable "instance_type" {
  type        = string
  default     = "Standard_D8s_v3"
  description = "Instance type for the AKS cluster"
}
```
DSv3 => D8s_v3 (8: 8vCPU per node)



## Resource groups

edit config.sh and define the resource group for the AKS Clusters.
You should use a different resource group than the DNS_RESOURCE_GROUP, as the cost of DNS is close to 0$ and you can leave it configured _forever_, while AKS will cost quite some money.

edit config.sh
```shell
RESOURCE_GROUP=ThomasManson-temp-AKS
```

# Create the two Redis Enterprise Cluster, set them as Active/Active and create an Active/Active DB

```shell
./create-all.sh
```
The script will create the AKS, Redis Enterprise Cluster & the Database.
Watch the output to ensure that no error happens during the process.
You may encounter errors like : not enough quota, Azure Identity Management not available

This script takes about 10 minutes to complete, it spends some time to wait for AKS creation, K8S resource creation and availability...

Upon completion, you have an Active/Active setup with a Active/Active DB setup.

Here is a sample output of the script with cluster informations : 

````
=========================================
⏱️ Execution Summary:
• 01-create-cluster.sh           :  4 min 54 sec
• 02-setup-haproxy.sh            :  4 min 06 sec
• 03-setup-rerc.sh               :  0 min 03 sec
• 04-create-active-active-db.sh  :  0 min 04 sec
-----------------------------------------
🔴 Total execution time          :  9 min 07 sec
=========================================

Switched to context "redis-francecentral".
##############################################################################################################
#📍 Cluster Name      : redis-francecentral
#👤 Username          : account@domain.com
#🔑 Password          : xxxxxx
#🌐 FQDN              : rec-redis-francecentral.rec.svc.cluster.local
#🔌 Connection String : rediss://active-active-db-db.redis-francecentral.demo.paquerette.com:443
##############################################################################################################
Switched to context "redis-ukwest".
##############################################################################################################
#📍 Cluster Name      : redis-ukwest
#👤 Username          : account@domain.com
#🔑 Password          : yyyyyyy
#🌐 FQDN              : rec-redis-ukwest.rec.svc.cluster.local
#🔌 Connection String : rediss://active-active-db-db.redis-ukwest.demo.paquerette.com:443
##############################################################################################################
````

# Access to Redis Enterprise WebUI

You may need it to access the WebUi for the demo and register your license.
In case of the license, it need to be register on both nodes (this can also be scripted)

## Get credentials

check the output of `./create-all.sh` or run `./05-get-cluster-info.sh` to get username & password

## Create a secure tunnel to the Redis Enterprise WebUI

```shell
./redis-enterprise-testing/webui-cluster1.sh
```

or

```shell
./redis-enterprise-testing/webui-cluster1.sh
```

This will create a secure connection, tunnel communication between your browser and Redis Enterprise Web UI.
It will open your browser to https://localhost:8443 or https://localhost:8444

# License

If you don't have a license the Redis Enterprise will run for 30 days with a max of 4 shards per cluster 
https://redis.io/docs/latest/operate/rs/clusters/configure/license-keys/

To add a license : 
* Connect to each of the web console
  * https://localhost:8443/#/cluster/configuration/general
  * https://localhost:8444/#/cluster/configuration/general
* Go to the license tab, click "Change" and paste the license
* Check that the number of shards increase from 4 to something more.

# Connect Redis Insight to each cluster

Use the connection string printed at the end of the creation of the cluster (or use `./05-get-cluster-info.sh` to get it again)

* Give each a name that include the region
* paste the connection string 
  * ex: rediss://active-active-db-db.redis-ukwest.demo.paquerette.com:443
*  Go to connection settings, security tab, and ensure that both TLS & SNI are checked

# Showcase concurrent writes

`./redis-enterprise-testing/launch_test.sh`

Launch 2 instances of a python programs in the background and wait for their executions to complete.
Each instance will connect to one region and increment 1000 times a counter.
After the completion the value of the counter is printed and show 2000.

Arguments : 
* No argument, the increment will be done without a pipe, which showcase the importance of the latency, the region closer to the client will complete earlier
* pipe :  pipe the increments, which makes the execution way faster
* reset : reset the counter to 0 before starting the increments

```
 ./launch_test.sh pipe reset
🔄 Resetting key...
🚀 Launching parallel INCR...
⏳ Waiting for process to finish :  29882, 29883
🔁 Incrementing key 'counter' 1000 times on active-active-db-db.redis-francecentral.demo.paquerette.com:443 using pipeline mode...
🔁 Incrementing key 'counter' 1000 times on active-active-db-db.redis-ukwest.demo.paquerette.com:443 using pipeline mode...
✅ Done for active-active-db-db.redis-francecentral.demo.paquerette.com:443
✅ Done for active-active-db-db.redis-ukwest.demo.paquerette.com:443
⏳ Waiting for convergence...
📥 Reading value from active-active-db-db.redis-francecentral.demo.paquerette.com
🔎 Key 'counter' on active-active-db-db.redis-francecentral.demo.paquerette.com:443 = 2000
```

# Continuous Load v1

* create a simple database
  * `redis-enterprise-testing/standalone-db/01-created-db.sh`

* Run the continuous load : 
  * `redis-enterprise-testing/continuous_load/redeploy.sh`

* Enable HA
  * `redis-enterprise-testing/standalone-db/02-enable-HA.sh`
* Increase RAM
  * `redis-enterprise-testing/standalone-db/03-db-ram-increase.sh`
* Increase shard count
  * `redis-enterprise-testing/standalone-db/04-increase-shard-count-db.sh`

* delete the db (in case you need to rerun)
  * `redis-enterprise-testing/standalone-db/05-delete-db.sh`

## Troubleshooting

### Collecting logs

```shell
./redis-enterprise-testing/check-redis-enterprise-on-azure.sh
```

Would collect logs and k8s resource statuses from various components of the setup in `./logs` folder.

Alternatively you can use Log Collector as described here: https://docs.redis.com/latest/kubernetes/logs/collect-logs/

### Redis Cluster Status

```
kubectl config use-context redis-canadacentral
kubectl exec -it  -n rec  rec-redis-canadacentral-0 -- bash
rladmin status
```
## Web Dashboard

![alt text](images/flask_app.png)

To enable Web UI for the demo run:
```
python3 flask/app.py
```
and point your browser to `http://localhost:5000/`


## Testing access to the cluster

Adjust test.py file to use selected regions and dns name:
```
region1="canadacentral"
region2="canadaeast"
dns_suffix="sademo.umnikov.com"
```

Run test:
```
python3 test.py
```
This simple woul connect to Redis DB endpoints in both regions and measure:
- avg ping time for endpoints in both regions
- replication speed between the regions
- Speed of setting large (6Mb keys)

While it's possible to execute this test on your own laptop, it is recommended to run it in the region, designated as "region1". It would demostrate difference in the responce (ping) time between local and remote region and will test large keys with the local region.



To test access from the redis command line `redis-cli` use:
```
# Canada Central
redis-cli --tls -h crdb-anton-db.redis-canadacentral.demo.umnikov.com -p 443  --insecure --sni crdb-anton-db.redis-canadacentral.demo.umnikov.com

# East US
redis-cli --tls -h crdb-anton-db.redis-eastus.demo.umnikov.com -p 443  --insecure --sni crdb-anton-db.redis-eastus.demo.umnikov.com
```

You can execute comands such as:
```
# run in canadacentral
set hello-from canada

# run in eastus
get hello-from
canada 
```

## Testing High Availability and Disaster Recovery

```
bash chaos.sh
```
would build up the commands specific to your environment (but not execute them!!!) that you can use in the next following steps.

### Forcing the k8s level (pod) failure

To simulate k8s level failure - force delete one of the redis enterprise pods.
```
kubectl delete pod rec-redis-canadacentral-0 -n rec --force
```

### Emulating single node failure

To emulate a failure of a single node you can forse restart one of the nodes of the AKS cluster.
```
az vmss restart  --name vmss \
--resource-group MC_ANTON-RG-AA-AKS_REDIS-CANADACENTRAL_CANADACENTRAL \
--instance-ids 1
```

With Replication enabled node restart even should be totally transparent to the application and the user. Note: application should be attempting reconnect in case of connection interruption (for instance - using `retry_on_error` conection flag in Python).

### Emulating Region outage

To emulate the entire Region outage you can stop and restart the AKS cluster in that region. For example:
```
az aks stop --name redis-canadacentral --resource-group anton-rg-aa-aks
# wait for the cluster to stop

az aks start --name redis-canadacentral --resource-group anton-rg-aa-aks
# wait for cluster to get back online
```

While the one of the clusters is down - make sure that you still can access and set/retreive data from the cluster in another region.

Since full cluster outage is also a loss of quorum (more than 50% of Redis Cluster nodes are down) recovery involves two additional steps on the Redis side:
```
# Recover from loss of quorum
kubectl -n rec patch rec rec-redis-canadacentral --type merge --patch '{"spec":{"clusterRecovery":true}}'
watch "kubectl -n rec describe rec | grep State"
# wait for "Running" state


# Recover databases
kubectl exec -it  -n rec  rec-redis-canadacentral-0 -- rladmin recover all
```
Make sure you can access clusters in both regions and data entered another region during the outage is accasibble in the region recoverd from the outage.

The following table summary of potential outage types:

![alt text](images/outages.png)

## Credits
This project is based on the work by [antonum](https://github.com/antonum/AKS-ActiveActive-Redis).

 * Improvement on the scripting so that the cluster can be created in one run, with improved wait() to ensure resource creation on K8S
 * Added an image to deploy on K8S to continuously query the DB while it's being scaled up/out
 * Improve the use of variables so that it relies on config.sh only
 * Some reorginasation, new scripts created for ease of use
 * Switch to opentofu


