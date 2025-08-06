#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
CONTROL_PLANE_CLUSTER="klutch-control-plane"
APP_CLUSTER="klutch-app"
CONTROL_PLANE_KIND_CONFIG="scripts/kind/kind_control_plane.yaml"
CA_OUTPUT="overlays/kind-docker/klutch-control-plane-ca.crt"
CONTROL_PLANE_CONTEXT="kind-${CONTROL_PLANE_CLUSTER}"

# --- Cluster Setup ---
echo "🚀 Creating control plane cluster: ${CONTROL_PLANE_CLUSTER}..."
if [[ ! -f "${CONTROL_PLANE_KIND_CONFIG}" ]]; then
    echo "❌ Kind config file not found: ${CONTROL_PLANE_KIND_CONFIG}"
    exit 1
fi
kind create cluster --name="${CONTROL_PLANE_CLUSTER}" --config="${CONTROL_PLANE_KIND_CONFIG}"

# --- CA Export ---
echo "🔐 Exporting cluster CA to: ${CA_OUTPUT}"
kubectl config view --raw --minify --context "${CONTROL_PLANE_CONTEXT}" \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode > "${CA_OUTPUT}"

echo "🔌 Discovering dynamically assigned API Server port..."
API_SERVER_URL=$(kubectl config view --raw --minify --context "${CONTROL_PLANE_CONTEXT}" -o jsonpath='{.clusters[0].cluster.server}')

API_SERVER_PORT=$(echo "${API_SERVER_URL}" | cut -d':' -f3)

if [[ -z "$API_SERVER_PORT" ]]; then
    echo "❌ Failed to discover the API server port after cluster creation."
    exit 1
fi
echo "✅ API Server is running on port: ${API_SERVER_PORT}"

# --- Wait for Nodes ---
echo "⏳ Waiting for all control plane nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --context "${CONTROL_PLANE_CONTEXT}" --timeout=120s

# --- Install Crossplane ---
echo "📦 Installing Crossplane core..."
kustomize build --enable-helm components/crossplane/core | kubectl --context "${CONTROL_PLANE_CONTEXT}" apply -f -
echo "⏳ Waiting for Crossplane controllers to become Ready..."
kubectl wait --for=condition=Available deployment --all -n crossplane-system --context "${CONTROL_PLANE_CONTEXT}" --timeout=180s
kubectl wait --for=condition=Ready pod --all -n crossplane-system --context "${CONTROL_PLANE_CONTEXT}" --timeout=180s
echo "✅ Crossplane is ready."

# --- Install provider-kubernetes ---
echo "📦 Installing provider-kubernetes..."
kustomize build components/data-services/a8s-framework/crossplane-integrations/provider-kubernetes | kubectl --context "${CONTROL_PLANE_CONTEXT}" apply -f -

echo "⏳ Waiting for provider-kubernetes to become Healthy..."
if ! kubectl wait providers.pkg.crossplane.io provider-kubernetes \
  --for=jsonpath='{.status.conditions[?(@.type=="Healthy")].status}'=True \
  --context "${CONTROL_PLANE_CONTEXT}" --timeout=5m; then
    echo "❌ provider-kubernetes failed to become Healthy. Fetching details..."
    kubectl describe providers.pkg.crossplane.io provider-kubernetes --context "${CONTROL_PLANE_CONTEXT}"
    PROVIDER_POD=$(kubectl get pods -n crossplane-system -l pkg.crossplane.io/provider=provider-kubernetes -o name --context "${CONTROL_PLANE_CONTEXT}" || true)
    if [[ -n "$PROVIDER_POD" ]]; then
        kubectl logs -n crossplane-system "${PROVIDER_POD}" --context "${CONTROL_PLANE_CONTEXT}" --tail=50
    else
        echo "⚠️ Provider pod not found."
    fi
    exit 1
fi
echo "✅ provider-kubernetes is Healthy."

# --- Apply Klutch CRDs ---
echo "📦 Applying Klutch backend CRDs..."
kustomize build components/klutch-bind-backend/crds | kubectl --context "${CONTROL_PLANE_CONTEXT}" apply -f -
sleep 2
echo "✅ CRDs applied."

# --- Install cert-manager ---
echo "📦 Installing cert-manager..."
kustomize build --enable-helm components/cluster-services/cert-manager | kubectl --context "${CONTROL_PLANE_CONTEXT}" apply -f -

echo "⏳ Waiting for cert-manager to be ready..."
kubectl wait deployment -n cert-manager --for=condition=Available --all --context "${CONTROL_PLANE_CONTEXT}" --timeout=180s
echo "✅ cert-manager is ready."

# --- Apply minio ---
echo "📦 Applying minio..."
kustomize build --enable-helm components/backup-storage/minio | kubectl --context "${CONTROL_PLANE_CONTEXT}" apply -f -

# --- Generate the dynamic ConfigMap before applying the overlay ---
echo "⚙️ Generating dynamic config for Klutch backend with port ${API_SERVER_PORT}..."
cat <<EOF > overlays/kind-docker/generated-klutch-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: klutch-bind-backend-config
  namespace: bind
data:
  external-address: "https://host.docker.internal:${API_SERVER_PORT}"
EOF

# Generate the ConfigMap from the template file ---
echo "⚙️ Generating dynamic config from template with port ${API_SERVER_PORT}..."
TEMPLATE_FILE="overlays/kind-docker/klutch-bind-configmap.template.yaml"
GENERATED_FILE="overlays/kind-docker/generated-klutch-config.yaml"
sed "s/__API_SERVER_PORT__/${API_SERVER_PORT}/g" "${TEMPLATE_FILE}" > "${GENERATED_FILE}"

# --- Apply additional components ---
echo "📦 Applying a8s framework..."
kubectl apply -k components/data-services/a8s-framework --context "${CONTROL_PLANE_CONTEXT}"

# --- Apply overlay ---
echo "📦 Applying platform stack overlay (kind-docker)..."
kustomize build --enable-helm overlays/kind-docker | kubectl --context "${CONTROL_PLANE_CONTEXT}" apply -f -

# --- Wait for final pods ---
echo "⏳ Waiting for all relevant pods to be Ready..."
namespaces=("a8s-system" "bind" "crossplane-system")
for ns in "${namespaces[@]}"; do
  if kubectl get ns "$ns" --context "${CONTROL_PLANE_CONTEXT}" &>/dev/null; then
    echo "⏳ Waiting in namespace: $ns"
    kubectl wait --for=condition=Ready pod --all -n "$ns" --context "${CONTROL_PLANE_CONTEXT}" --timeout=300s
  else
    echo "ℹ️ Namespace '$ns' not found. Skipping..."
  fi
done

echo "🧹 Cleaning up generated files..."
rm "${GENERATED_FILE}"

echo "✅ Control plane cluster is fully set up."

# --- Create Application Cluster ---
echo "🚀 Creating application cluster: ${APP_CLUSTER}..."
kind create cluster --name="${APP_CLUSTER}"

# --- Final Message ---
echo
echo "🎉 All clusters are ready!"
echo
echo "👉 To bind your app cluster to the control plane, run:"
echo
echo "kubectl bind http://host.docker.internal:8080/export \\"
echo "  --konnector-image public.ecr.aws/w5n9a2g2/anynines/konnector:v1.3.0 \\"
echo "  --context kind-${APP_CLUSTER}"
echo
