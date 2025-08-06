#!/bin/bash


echo "Creating dummy service in app cluster"
kubectl apply --context kind-klutch-app -f 2-service.yaml

namespace=$(kubectl get ns --context kind-klutch-control-plane --no-headers -o custom-columns=":metadata.name" | grep -e "kube-bind-[[:alnum:]]\{5\}-default")
echo "Briding management cluster network from namespace ${namespace}"
kubectl port-forward --context kind-klutch-control-plane --namespace ${namespace} service/example-pg-instance-master 5432