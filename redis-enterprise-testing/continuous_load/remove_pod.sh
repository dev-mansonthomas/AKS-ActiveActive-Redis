kubectl delete deploy redis-loadgen
kubectl delete pod -l app=redis-loadgen --grace-period=0 --force || true