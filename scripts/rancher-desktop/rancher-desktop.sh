#!/usr/bin/env bash
set -euo pipefail

#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Rancher Desktop Cluster Setup Script
# ==============================================================================
#
# !! PRE-REQUISITES !!
#
# This script must be run AFTER you have set up Rancher Desktop correctly.
# Please perform the following manual steps in the Rancher Desktop application:
#
# 1. Start Rancher Desktop.
#
# 2. In Preferences > Kubernetes Settings:
#    - Enable Kubernetes.
#    - Choose a desired Kubernetes version.
#
# 3. In Preferences > Port Forwarding:
#    - Ensure the "Include Privileged Services" checkbox is UNCHECKED.
#    - This is CRITICAL to free up ports 80 and 443 for the ingress controller.
#
# 4. Click "Apply & Restart" and wait for the cluster to be ready.
#
# 5. Ensure 'k3d' is installed on your machine (https://k3d.io/).
#
# ==============================================================================

# --- Configuration ---
RANCHER_CONTEXT="rancher-desktop"
RANCHER_OVERLAY_PATH="overlays/rancher-desktop"
KLUTCH_CA_OUTPUT="${RANCHER_OVERLAY_PATH}/klutch-control-plane-ca.crt"
APP_CLUSTER="klutch-app"

echo "🚀 Starting Rancher Desktop control plane setup..."

# Export cluster CA certificate
kubectl get configmap -n kube-system kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > "${KLUTCH_CA_OUTPUT}"
echo "   -> Exported cluster CA to ${KLUTCH_CA_OUTPUT}"

echo "✅ Cluster CA certificate exported."

# Apply minio storage
echo "📦 Applying Minio backup storage..."
kustomize build --enable-helm components/backup-storage/minio | kubectl apply -f -

echo "⏳ Waiting for Minio to be ready..."
kubectl wait deployment --all -n minio-dev --for=condition=Available --context "${RANCHER_CONTEXT}" --timeout=5m

kubectl apply -f components/crossplane/core/crossplane-core-namespace.yaml

# Apply Rancher Desktop overlay platform stack
echo "📦 Applying Rancher Desktop platform stack overlay..."
kustomize build --enable-helm "${RANCHER_OVERLAY_PATH}" | kubectl --context "${RANCHER_CONTEXT}" apply -f -

echo "⏳ Waiting for platform stack components (ingress-nginx, bind) to be ready..."
kubectl wait deployment --all -n ingress-nginx --for=condition=Available --context "${RANCHER_CONTEXT}" --timeout=5m
kubectl wait deployment/dex -n bind --for=condition=Available --context "${RANCHER_CONTEXT}" --timeout=5m

# Install Crossplane core
echo "📦 Installing Crossplane core components..."
kustomize build --enable-helm components/crossplane/core | kubectl --context "${RANCHER_CONTEXT}" apply -f -

echo "⏳ Waiting for Crossplane controllers to be ready..."
kubectl wait deployment --all -n crossplane-system --for=condition=Available --context "${RANCHER_CONTEXT}" --timeout=180s
kubectl wait pod --all -n crossplane-system --for=condition=Ready --context "${RANCHER_CONTEXT}" --timeout=180s
echo "✅ Crossplane controllers ready."

# Install provider-kubernetes
echo "📦 Installing provider-kubernetes..."
kustomize build components/data-services/a8s-framework/crossplane-integrations/provider-kubernetes | kubectl --context "${RANCHER_CONTEXT}" apply -f -

echo "⏳ Waiting for provider-kubernetes to become Healthy..."
if ! kubectl wait providers.pkg.crossplane.io provider-kubernetes --for=jsonpath='{.status.conditions[?(@.type=="Healthy")].status}'=True --context "${RANCHER_CONTEXT}" --timeout=5m; then
    echo "🚨 provider-kubernetes failed to become Healthy. Gathering diagnostics..."
    kubectl describe providers.pkg.crossplane.io provider-kubernetes --context "${RANCHER_CONTEXT}"
    PROVIDER_POD=$(kubectl get pods -n crossplane-system -l pkg.crossplane.io/provider=provider-kubernetes -o name --context "${RANCHER_CONTEXT}" || true)
    if [[ -n "$PROVIDER_POD" ]]; then
        kubectl logs -n crossplane-system "${PROVIDER_POD}" --context "${RANCHER_CONTEXT}" --tail=50
    else
        echo "⚠️ provider-kubernetes pod not found."
    fi
    exit 1
fi
echo "✅ provider-kubernetes is Healthy."

# Apply Klutch backend CRDs
echo "📦 Applying Klutch backend CRDs..."
kustomize build components/klutch-bind-backend/crds | kubectl --context "${RANCHER_CONTEXT}" apply -f -
sleep 2
echo "✅ Klutch backend CRDs applied."

# Install cert-manager
echo "📦 Installing cert-manager..."
kustomize build --enable-helm components/cluster-services/cert-manager | kubectl --context "${RANCHER_CONTEXT}" apply -f -

echo "⏳ Waiting for cert-manager pods to be ready..."
kubectl wait deployment -n cert-manager --for=condition=Available --all --context "${RANCHER_CONTEXT}" --timeout=180s
echo "✅ cert-manager is ready."

# Install a8s Data Services Framework
echo "📦 Installing a8s Data Services Framework..."
kustomize build --enable-helm components/data-services/a8s-framework | kubectl --context "${RANCHER_CONTEXT}" apply -f -

# Apply backup config
echo "📦 Applying anynines backup configuration..."
kubectl --context "${RANCHER_CONTEXT}" apply -f overlays/rancher-desktop/a8s-backup-config.yaml

# Wait for pods in critical namespaces
echo "⏳ Waiting for all platform pods to be Ready..."
namespaces=("bind" "crossplane-system" "a8s-system")
for ns in "${namespaces[@]}"; do
  if kubectl get ns "$ns" --context "${RANCHER_CONTEXT}" &>/dev/null; then
    echo "⏳ Waiting in namespace: $ns"
    kubectl wait pod --all -n "$ns" --for=condition=Ready --context "${RANCHER_CONTEXT}" --timeout=300s
  else
    echo "ℹ️ Namespace '$ns' not found, skipping."
  fi
done

echo "✅ Rancher Desktop control plane cluster is ready."

if k3d cluster list | grep -q "^${APP_CLUSTER}[[:space:]]"; then
    echo "✅ Application cluster '${APP_CLUSTER}' already exists. Skipping creation."
else
    echo "   -> Cluster not found. Creating it now..."
    k3d cluster create "${APP_CLUSTER}"
    echo "   -> Application cluster '${APP_CLUSTER}' created successfully."
fi

echo -e "\n✅ Setup complete!\n"
echo "👉 To bind to Klutch APIs on the application cluster, run:"
echo
echo "kubectl bind http://host.lima.internal/export \\"
echo "  --konnector-image public.ecr.aws/w5n9a2g2/anynines/konnector:v1.3.0 \\"
echo "  --context k3d-${APP_CLUSTER}"
echo
