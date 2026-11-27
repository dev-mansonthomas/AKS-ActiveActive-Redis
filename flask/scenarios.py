"""Texts the console shows for each chaos scenario.

Ids are shared with `scripts/chaos.sh --scenario` (see SELECTABLE; a test keeps
`chaos.sh --list` and this file in sync). Edit the wording here, nothing else reads it.
`typical` is filled in once real durations have been measured.
"""

SCENARIOS = {
    "health": {
        "title": "Health check",
        "simulate": "Nothing is broken yet: both clusters and the Active-Active database are inspected.",
        "actions": [
            "Check Kubernetes nodes and pods on both clusters",
            "Check Redis Enterprise nodes and databases (rladmin)",
            "Check the Active-Active objects (RERC, REAADB)",
            "Write on one region and read on both",
        ],
        "expect": "Everything green. If not, the run stops before anything is broken, so the demo "
                  "never starts from a half-broken setup.",
        "typical": None,
    },
    "pod": {
        "title": "Pod failure",
        "simulate": "One Redis Enterprise pod is force-deleted: never the cluster primary nor the holder of "
                    "the database endpoint (node 2 when it is neither). It may hold the primary or the replica shard.",
        "actions": [
            "Pick the pod from rladmin: node 2 unless it is the cluster primary or holds the endpoint; the exact pod and its role are shown when it is deleted",
            "Force-delete that pod",
            "Wait for Kubernetes to recreate it and for the node to rejoin",
            "Check every Redis Enterprise node and database, then write/read on both regions",
        ],
        "expect": "Kubernetes recreates the pod, the Redis Enterprise node rejoins the cluster and "
                  "the database stays available in both regions, the cluster API included. No human "
                  "action. (Deleting the primary pod instead, --pod 0, also takes the REST API and the "
                  "endpoint of that region down for a short while: the worst case.)",
        "typical": None,
    },
    "node": {
        "title": "Node failure",
        "simulate": "The cloud VM hosting a Redis Enterprise node is hard-reset.",
        "actions": [
            "Hard-reset the cloud VM hosting the chosen replica pod",
            "Wait for the Kubernetes node and its Redis Enterprise pod to come back",
            "Check every Redis Enterprise node and database, then write/read on both regions",
        ],
        "expect": "The node goes down, then OK again once the VM and the pod are back. Shards "
                  "fail over inside the cluster and the database keeps serving. No human action.",
        "typical": None,
    },
    "region": {
        "title": "Region outage",
        "simulate": "Every node of one region is removed: the whole cluster is gone.",
        "actions": [
            "Remove all nodes of the target cluster (and force-delete its Redis Enterprise pods)",
            "Check that the other region still serves reads and writes",
            "Bring the nodes back",
            "Run the cluster recovery, then the database recovery (issued by chaos.sh)",
            "Check every node and database, then write/read on both regions",
        ],
        "expect": "The surviving region keeps serving reads and writes (Active-Active). When the "
                  "nodes come back, the cluster and database recovery procedure restores the "
                  "region and replication catches up. Recovery after the loss of a whole cluster "
                  "is not fully automatic: chaos.sh issues the recovery commands.",
        "typical": None,
    },
    "region-recover": {
        "title": "Region recovery (resume)",
        "simulate": "A region left down or half-recovered after an interruption is brought back.",
        "actions": [
            "Restore the node pool size and autoscaling",
            "Run the cluster recovery, then the database recovery",
            "Check every node and database, then write/read on both regions",
        ],
        "expect": "Same recovery as at the end of the region outage scenario. The health check is "
                  "skipped because the cluster is degraded by definition.",
        "typical": None,
    },
}

# Scenarios `chaos.sh --scenario` accepts, in the canonical order they are played.
SELECTABLE = ["pod", "node", "region", "region-recover"]
