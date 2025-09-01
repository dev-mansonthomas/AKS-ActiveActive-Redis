#!/usr/bin/env bash
source ../config.sh

CLUSTER=${CLUSTER1:?CLUSTER1 non défini dans config.sh}
LOCAL_PORT=8443

ORIGINAL_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
TARGET_CONTEXT="$CLUSTER"

SWITCHED=0
if [[ -n "$TARGET_CONTEXT" && "$ORIGINAL_CONTEXT" != "$TARGET_CONTEXT" ]]; then
  echo "🔁 Contexte courant: '${ORIGINAL_CONTEXT:-<aucun>}' → bascule vers: '$TARGET_CONTEXT'"
  kubectl config use-context "$TARGET_CONTEXT"
  SWITCHED=1
fi

# Restaure le contexte d'origine à la fin du script si on a basculé
cleanup() {
  if [[ "$SWITCHED" -eq 1 ]]; then
    if [[ -n "$ORIGINAL_CONTEXT" ]]; then
      echo "↩️  Restoring original context: '$ORIGINAL_CONTEXT'"
      kubectl config use-context "$ORIGINAL_CONTEXT"
    fi
  fi
}
trap cleanup EXIT
echo "⛓️  Using context: '$TARGET_CONTEXT'"
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