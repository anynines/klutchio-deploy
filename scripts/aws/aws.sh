#!/usr/bin/env bash

# ==============================================================================
# Klutch on AWS EKS - Control Plane Setup Script
# ==============================================================================
#
# This script automates the deployment of the Klutch control plane components
# onto an existing AWS EKS cluster.
#
# Pre-requisites:
#   1. An EKS cluster is running.
#   2. `kubectl` is configured with a context for the EKS cluster.
#   3. An `overlays/aws/.env` file exists with required environment variables.
#   4. Required CLI tools are installed: kubectl, kustomize, envsubst, kind.
#
# ==============================================================================

# --- Strict Mode and Error Handling ---
# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Pipestatus is the last command to exit with a non-zero status.
set -euo pipefail

# --- Configuration & Global Variables ---
readonly AWS_OVERLAY_PATH="overlays/aws"
readonly KUSTOMIZATION_TEMPLATE="${AWS_OVERLAY_PATH}/kustomization.yaml.template"
readonly KUSTOMIZATION_FINAL="${AWS_OVERLAY_PATH}/kustomization.yaml"

# These should be defined in your environment or the .env file
# Example: export CONTROL_PLANE_CONTEXT="my-eks-cluster"
# Example: export APP_CLUSTER="klutch-app"
: "${CONTROL_PLANE_CONTEXT?Please set the CONTROL_PLANE_CONTEXT environment variable}"
: "${APP_CLUSTER?Please set the APP_CLUSTER environment variable}"

# --- Function Definitions ---

# Cleanup function to be called on script exit
cleanup() {
  echo "🧹 Cleaning up temporary files..."
  rm -f "${KUSTOMIZATION_FINAL}"
}
trap cleanup EXIT

# Check for required command-line tools
check_deps() {
  echo "🔎 Checking for required tools..."
  local missing_deps=0
  for dep in kubectl kustomize envsubst kind; do
    if ! command -v "${dep}" &>/dev/null; then
      echo "   ❌ Error: '${dep}' command not found. Please install it and ensure it's in your PATH."
      missing_deps=1
    fi
  done
  if ((missing_deps)); then
    exit 1
  fi
  echo "✅ All required tools are present."
}

# Source environment variables and generate the final kustomization file
prepare_kustomization() {
  echo "📝 Preparing AWS overlay configuration..."
  if [[ ! -f "overlays/aws/.env" ]]; then
      echo "   ❌ Error: Environment file 'overlays/aws/.env' not found. Please create it."
      exit 1
  fi
  source "overlays/aws/.env"
  envsubst < "${KUSTOMIZATION_TEMPLATE}" > "${KUSTOMIZATION_FINAL}"
  echo "✅ Kustomization file generated from template."
}

# Install Cert-Manager and wait for it to be ready
install_cert_manager() {
  echo "📦 Installing Cert-Manager..."
  kustomize build --enable-helm components/cluster-services/cert-manager | kubectl apply -f -
  echo "⏳ Waiting for Cert-Manager pods to be ready..."
  kubectl wait --for=condition=Available deployment --all -n cert-manager --context "${CONTROL_PLANE_CONTEXT}" --timeout=240s
  echo "✅ Cert-Manager is ready."
}

expose_klutch_backend() {
    echo "🔑 Applying TLS Issuer and Certificate..."
    # Apply the issuer.yaml which contains the ClusterIssuer and Certificate resources.
    # We use envsubst to replace any environment variables (like email or domain) in the template.
    envsubst < "${AWS_OVERLAY_PATH}/issuer.yaml" | kubectl apply -f -

    echo "⏳ Waiting for Cert-Manager to issue the certificate..."
    # This command waits for the 'Ready' condition on the Certificate resource to be 'True'.
    kubectl wait --for=condition=Ready certificate/klutch-bind-backend-tls -n bind --timeout=300s
    echo "✅ Certificate is ready."

    echo "🌐 Applying Ingress for Klutch Backend..."
    # Apply the Ingress resource.
    kubectl apply -f "${AWS_OVERLAY_PATH}/klutch-bind-backend-ingress.yaml"
    echo "✅ Ingress created."
}


# Install Crossplane and its providers
install_crossplane() {
  echo "✈️  Installing Crossplane and providers..."
  echo "   -> Installing Crossplane core..."
  kustomize build --enable-helm components/crossplane/core | kubectl --context "${CONTROL_PLANE_CONTEXT}" apply -f -
  echo "   -> Waiting for Crossplane controller pods to be ready..."
  kubectl wait --for=condition=Available deployment --all -n crossplane-system --context "${CONTROL_PLANE_CONTEXT}" --timeout=180s
  kubectl wait --for=condition=Ready pod --all -n crossplane-system --context "${CONTROL_PLANE_CONTEXT}" --timeout=180s

  echo "   -> Installing provider-kubernetes..."
  kustomize build components/data-services/a8s-framework/crossplane-integrations/provider-kubernetes | kubectl --context "${CONTROL_PLANE_CONTEXT}" apply -f -
  echo "   -> Waiting for provider-kubernetes to become Healthy..."
  if ! kubectl wait providers.pkg.crossplane.io provider-kubernetes --for=jsonpath='{.status.conditions[?(@.type=="Healthy")].status}'=True --context "${CONTROL_PLANE_CONTEXT}" --timeout=5m; then
      echo "   🚨 provider-kubernetes failed to become Healthy. Gathering diagnostics:"
      kubectl describe providers.pkg.crossplane.io provider-kubernetes --context "${CONTROL_PLANE_CONTEXT}"
      local PROVIDER_POD
      PROVIDER_POD=$(kubectl get pods -n crossplane-system -l pkg.crossplane.io/provider=provider-kubernetes -o name --context "${CONTROL_PLANE_CONTEXT}" || true)
      if [[ -n "$PROVIDER_POD" ]]; then
          kubectl logs -n crossplane-system "${PROVIDER_POD}" --context "${CONTROL_PLANE_CONTEXT}" --tail=50
      fi
      exit 1
  fi
  echo "✅ Crossplane and providers are ready."
}

# Install Klutch components
install_klutch() {
  echo "🧩 Installing Klutch components..."
  echo "   -> Applying Klutch bind backend CRDs..."
  kustomize build components/klutch-bind-backend/crds | kubectl apply -f -
  sleep 2 # Short wait for API server to register CRDs

  echo "   -> Installing anynines Data Services Framework..."
  kustomize build --enable-helm components/data-services/a8s-framework | kubectl apply -f -

  echo "   -> Applying anynines Backup Configuration..."
  envsubst < "${AWS_OVERLAY_PATH}/a8s-backup-config.yaml.tpl" | kubectl apply -f -
  envsubst < "${AWS_OVERLAY_PATH}/a8s-backup-secret.yaml.tpl" | kubectl apply -f -

  echo "   -> Exporting control plane CA certificate..."
  kubectl get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' > "${AWS_OVERLAY_PATH}/klutch-control-plane-ca.crt"

  echo "   -> Applying final Klutch backend configuration..."
  kustomize build --enable-helm "${AWS_OVERLAY_PATH}" | kubectl apply -f -
  echo "✅ Klutch components are ready."
}

# Create the local application cluster
create_app_cluster() {
  echo "🚀 Creating local application cluster: ${APP_CLUSTER}..."
  if kind get clusters | grep -q "^${APP_CLUSTER}$"; then
    echo "   -> Cluster '${APP_CLUSTER}' already exists. Skipping creation."
  else
    kind create cluster --name="${APP_CLUSTER}"
  fi
  echo "✅ Application cluster is ready."
}

# --- Main Execution ---
main() {
  check_deps
  prepare_kustomization

  install_cert_manager
  install_crossplane
  install_klutch

  expose_klutch_backend

  echo "✅ Klutch control plane cluster is ready."

  create_app_cluster

  echo -e "\n🎉 Setup complete!\n"
  echo "👉 To bind to the Klutch APIs, run the following command:"
  echo
  echo "   kubectl bind <your-domain>:443/export --konnector-image=public.ecr.aws/w5n9a2g2/klutch/konnector:v1.3.0 --context kind-${APP_CLUSTER}"
  echo
}

# Run the main function
main