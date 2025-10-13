#!/bin/bash


echo "Creating dummy service in app cluster"
kubectl apply --context k3d-klutch-app -f 2-service.yaml

namespace=$(kubectl get ns --context rancher-desktop --no-headers -o custom-columns=":metadata.name" | grep -e "kube-bind-[[:alnum:]]\{5\}-default")
echo "Briding management cluster network from namespace ${namespace}"
kubectl port-forward --context rancher-desktop --namespace ${namespace} service/example-pg-instance-master 5432