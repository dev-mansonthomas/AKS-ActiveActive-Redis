#!/usr/bin/env bash
source ../config.sh

CLUSTER=$CLUSTER2
LOCAL_PORT=8444

kubectl config use-context $CLUSTER

nohup kubectl port-forward svc/rec-$CLUSTER-ui $LOCAL_PORT:8443 -n rec &

echo "⏲️ Waiting 2 seconds that the connexion is established"
sleep 2

URL="https://localhost:$LOCAL_PORT/#/"
echo "🔓tunneling opened on local port $LOCAL_PORT, ready to connect to $URL"

if [[ "$OSTYPE" == "darwin"* ]]; then
    open "$URL"    # macOS
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    xdg-open "$URL"  # Linux
else
    echo "❌ Unsupported OS."
fi