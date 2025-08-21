#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# OpenShift CRC Cluster Setup Script
# ==============================================================================
#
# !! PRE-REQUISITES !!
#
# This script must be run AFTER you have successfully set up and logged into
# your CodeReady Containers (CRC) instance. Please perform the following to
# manual steps in your terminal first:
#
# 1. Setup CRC and configure its resources:
#    crc setup
#    crc config set cpus 6
#    crc config set disk-size 35
#    crc config set memory 10752
#
# 2. Start CRC with your pull secret:
#    crc start -p ~/Downloads/pull-secret.txt
#
# 3. Set up your shell environment to use the 'oc' CLI:
#    eval $(crc oc-env)
#
# 4. Log in to the cluster as the admin user:
#    oc login -u kubeadmin https://api.crc.testing:6443
#
# ==============================================================================

OPENSHIFT_CONTEXT=$(kubectl config current-context)
CRC_OVERLAY_PATH="overlays/openshift-crc"
PATCH_OVERLAY_PATH="${CRC_OVERLAY_PATH}/clusterrole-patch"
KLUTCH_CA_OUTPUT="${CRC_OVERLAY_PATH}/klutch-control-plane-ca.crt"
INGRESS_CA_OUTPUT="${CRC_OVERLAY_PATH}/ingress-ca-certificate.crt"
ROUTER_CERT_OUTPUT="${CRC_OVERLAY_PATH}/openshift-router.crt"
APP_CLUSTER="klutch-app"
CROSSPLANE_OVERLAY_PATH="${CRC_OVERLAY_PATH}/crossplane"

# --- Verify OpenShift Login ---
echo "🚀 Verifying OpenShift login and context..."
if ! oc whoami &>/dev/null; then
    echo "❌ Not logged into OpenShift. Please run 'eval \$(crc oc-env)' and 'oc login' first."
    exit 1
fi
echo "✅ Logged in as '$(oc whoami)' on context '${OPENSHIFT_CONTEXT}'."


# --- Export Certificates ---
echo "🔐 Exporting required certificates..."
oc get configmap -n kube-system kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > "${KLUTCH_CA_OUTPUT}"
oc get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.tls\.crt}' | base64 --decode > "${INGRESS_CA_OUTPUT}"
oc get secret router-certs-default -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | base64 --decode > "${ROUTER_CERT_OUTPUT}"
oc get secret router-certs-default -n openshift-ingress -o jsonpath='{.data.tls\.key}' | base64 --decode > "${CRC_OVERLAY_PATH}/openshift-router.key"
echo "✅ Certificate export complete."


# --- [STEP 1] Install Prerequisite: cert-manager ---
echo "📦 Installing cert-manager..."
kustomize build --enable-helm components/cluster-services/cert-manager | kubectl --context "${OPENSHIFT_CONTEXT}" apply -f -

echo "⏳ Waiting for cert-manager to be ready..."
kubectl wait deployment -n cert-manager --for=condition=Available --all --context "${OPENSHIFT_CONTEXT}" --timeout=180s
echo "✅ cert-manager is ready."


# --- [STEP 2] Install Prerequisite: Crossplane Core ---
echo "📦 Ensuring 'crossplane-system' namespace exists..."
kubectl apply -f components/crossplane/core/crossplane-core-namespace.yaml
echo "📦 Applying Crossplane stack..."
kustomize build --enable-helm "${CROSSPLANE_OVERLAY_PATH}" | kubectl --context "${OPENSHIFT_CONTEXT}" apply -f -

echo "⏳ Waiting for Crossplane controllers to become Ready..."
kubectl wait --for=condition=Available deployment --all -n crossplane-system --context "${OPENSHIFT_CONTEXT}" --timeout=180s
echo "✅ Crossplane is ready."


# --- [STEP 3] Install provider-kubernetes and Wait ---
echo "📦 Installing provider-kubernetes..."
kustomize build components/data-services/a8s-framework/crossplane-integrations/provider-kubernetes | kubectl --context "${OPENSHIFT_CONTEXT}" apply -f -

echo "⏳ Waiting for provider-kubernetes to become Healthy..."
if ! kubectl wait providers.pkg.crossplane.io provider-kubernetes \
  --for=jsonpath='{.status.conditions[?(@.type=="Healthy")].status}'=True \
  --context "${OPENSHIFT_CONTEXT}" --timeout=5m; then
    echo "❌ provider-kubernetes failed to become Healthy. Check Crossplane pods."
    exit 1
fi
echo "✅ provider-kubernetes is Healthy."


# --- [STEP 4] Apply All Other Components via Overlay ---
echo "📦 Applying all remaining components (Klutch, Minio, a8s framework, and patches)..."

# Patch ClusterRole
echo "   -> Patching ClusterRole..."
kubectl get clusterrole system:controller:statefulset-controller -o yaml --context "${OPENSHIFT_CONTEXT}" | \
  yq 'del(.metadata.managedFields)' > "${PATCH_OVERLAY_PATH}/clusterrole-base.yaml"
kustomize build "${PATCH_OVERLAY_PATH}" | kubectl --context "${OPENSHIFT_CONTEXT}" apply -f -
rm "${PATCH_OVERLAY_PATH}/clusterrole-base.yaml"

# Apply remaining components
kustomize build components/klutch-bind-backend/crds | kubectl --context "${OPENSHIFT_CONTEXT}" apply -f -
sleep 2 # Short sleep for CRDs to register
kustomize build --enable-helm components/backup-storage/minio | kubectl --context "${OPENSHIFT_CONTEXT}" apply -f -


# This single command now applies the overlay AND the patched a8s-framework.
kustomize build --enable-helm overlays/openshift-crc | kubectl --context "${OPENSHIFT_CONTEXT}" apply -f -
echo "✅ All manifests applied."


# --- [STEP 5] Final Wait for All Pods to Become Ready ---
echo "⏳ Waiting for all platform pods to be Ready..."
namespaces=("a8s-system" "bind" "crossplane-system")
for ns in "${namespaces[@]}"; do
  if kubectl get ns "$ns" --context "${OPENSHIFT_CONTEXT}" &>/dev/null; then
    echo "⏳ Waiting for pods in namespace: $ns"
    kubectl wait pod --all -n "$ns" --for=condition=Ready --context "${OPENSHIFT_CONTEXT}" --timeout=5m
  else
    echo "ℹ️ Namespace '$ns' not found. Skipping."
  fi
done

echo "✅ Klutch control plane cluster is ready."

# --- Create Kind Application Cluster ---
if kind get clusters | grep -q "^${APP_CLUSTER}$"; then
    echo "✅ Kind cluster '${APP_CLUSTER}' already exists. Skipping creation."
    kubectl config use-context kind-${APP_CLUSTER}
else
    echo "🚀 Creating application cluster with kind: ${APP_CLUSTER}..."
    kind create cluster --name="${APP_CLUSTER}"
fi

echo "📦 Adjusting coredns configmap..."
COREDNS_CM_NS=kube-system
COREDNS_CM_NAME=coredns
COREDNS_ALIAS=api.crc.testing
COREDNS_TARGET=host.docker.internal

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
kubectl -n "$COREDNS_CM_NS" get configmap "$COREDNS_CM_NAME" -o go-template='{{ index .data "Corefile" }}' >"$tmp"

if grep -q "rewrite name exact ${COREDNS_ALIAS} ${COREDNS_TARGET}" "$tmp"; then 
    echo "✅ Rewrite target already present in configmap"
else
    sed -i '' "/^\.:53[[:space:]]*{/a\\
    rewrite name exact ${COREDNS_ALIAS} ${COREDNS_TARGET}
    " "$tmp"
fi

kubectl -n "$COREDNS_CM_NS" create configmap "$COREDNS_CM_NAME" --from-file=Corefile="$tmp" -o yaml --dry-run=client | kubectl apply -f -

echo -e "\n🎉 Setup complete!\n"
echo "👉 To bind your app cluster to the control plane, run:"
echo
echo "kubectl bind http://klutch.apps-crc.testing/export \\"
echo "  --konnector-image public.ecr.aws/w5n9a2g2/anynines/konnector:v1.3.0 \\"
echo "  --context kind-${APP_CLUSTER}"
echo
