#!/usr/bin/env bash
# load configuration options from file
# change setting like cluster names, DNS zones etc in config.sh
source ../config.sh
echo "Using configuration in config.sh:"
cat config.sh


echo "removing existing logs if any"
mkdir -p ../logs
rm -f ../logs/*.*

for CLUSTER in $CLUSTER1 $CLUSTER2
do
  echo "switching to $CLUSTER"
  kubectl config use-context $CLUSTER
  echo "▶️ Context: $(kubectl config current-context)"


  FILE="../logs/$CLUSTER-get-all.txt"
  echo "#################################################################"
  echo "  kubectl get all for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get all -n rec > $FILE
  cat $FILE

  echo "#########################################"
  echo "      External API access for $CLUSTER"
  echo "#########################################"

  REC_UNAME=$(kubectl -n $NS get secret rec-$CLUSTER -o jsonpath='{.data.username}' | base64 --decode)
  echo $REC_UNAME
  REC_PASSWORD=$(kubectl -n $NS get secret rec-$CLUSTER -o jsonpath='{.data.password}' | base64 --decode)
  echo $REC_PASSWORD

  curl https://api.$CLUSTER.$DNS_ZONE:443/v1/cluster --insecure \
  -H "content-type: application/json" \
  -u "$REC_UNAME:$REC_PASSWORD" \
  | jq .name

  FILE="../logs/$CLUSTER-operator.log"
  echo "#################################################################"
  echo "  REC Operator logs for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl logs deployment.apps/redis-enterprise-operator -n $NS > $FILE
  tail $FILE

  FILE="../logs/$CLUSTER-ingress.txt"
  echo "#################################################################"
  echo "  Ingress for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get ingress -A > $FILE
  cat $FILE
  echo "kubectl get ingress -o yaml is in file $FILE"
  kubectl get ingress -A -o yaml >> $FILE

  FILE="../logs/$CLUSTER-rec.txt"
  echo "#################################################################"
  echo "  REC Resources for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get rec -A > $FILE
  cat $FILE
  echo "kubectl get rec -o yaml is in file $FILE"
  kubectl get rec -A -o yaml >> $FILE

  FILE="../logs/$CLUSTER-rerc.txt"
  echo "#################################################################"
  echo "  RERC for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get rerc -A > $FILE
  cat $FILE
  echo "kubectl get rerc -o yaml is in file $FILE"
  kubectl get rerc -A -o yaml >> $FILE

  FILE="../logs/$CLUSTER-redb.txt"
  echo "#################################################################"
  echo "  REDB for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get redb -A > $FILE
  cat $FILE
  echo "kubectl get redb -o yaml is in file $FILE"
  kubectl get redb -A -o yaml >> $FILE

  FILE="../logs/$CLUSTER-reaadb.txt"
  echo "#################################################################"
  echo "  REAADB status for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get reaadb -n $NS > $FILE
  cat $FILE
  echo "kubectl describe reaadb $NS is in file $FILE"
  kubectl describe reaadb -n $NS >> $FILE

  FILE="../logs/$CLUSTER-rladmin-status.txt"
  echo "#################################################################"
  echo "  rladmin status for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl -n $NS exec -it rec-$CLUSTER-0 -- rladmin status > $FILE
  cat $FILE

done