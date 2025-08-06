# Deploying Klutch on Kind

This guide provides instructions for setting up a complete Klutch environment locally using [Kind](https://kind.sigs.k8s.io/)
and [Docker](https://www.docker.com/products/docker-desktop/). A shell script can be used to deploy all components
required to run Klutch locally. Alternatively, you can use other automation workflows to apply the same components,
if you prefer a different setup approach.

### Prerequisites

Before running the script, ensure you have the following installed and configured:

1.  **General Tools**:
    *   [kubectl](https://kubernetes.io/docs/tasks/tools/)
    *   [Kustomize](https://kustomize.io/)
    *   [Helm](https://helm.sh/docs/helm/helm_install/)
2.  **[Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)**: The primary tool for creating the local
Kubernetes clusters.
    *Tested with version:* 0.29.0
3.  **[Docker Desktop](https://www.docker.com/products/docker-desktop/)**: Kind uses this to run the Kubernetes nodes
as containers.
    *Tested with version:* 28.3.3 (build 980b856816)
4.  **Host DNS Configuration**: Add the following entry to your local `/etc/hosts` file. This is **required** for your
machine to resolve the OIDC issuer URL exposed by the Kind cluster's ingress.

    ```bash
    echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts
    ```
5. **kubectl-bind CLI**: Install the `kubectl-bind` plugin as described in the main README under **Installing the `kubectl-bind` CLI**.
This tool is required to bind your application cluster to the Klutch control plane APIs.

## Automated installation using a setup script

> **NOTE: The kind-Docker overlay is for development and testing only**
>
> The provided script and the kind-docker Kustomize overlay are intended solely for local development and testing. This
setup is not secure, it uses plain HTTP for endpoints and includes hardcoded secrets and credentials. **Do not use this configuration in production environments.**


The entire setup process is automated. From the root of this repository, execute the following script:

```bash
./scripts/kind/kind-klutch.sh
```

**Troubleshooting Tip**: If the script fails with a `resource mapping not found... ensure CRDs are installed first` error,
this is a common race condition. The Crossplane controller is still installing necessary components in the background.
Simply run the script again.

### What the Script Does

This setup script provisions two local Kubernetes clusters using Kind: one for the Klutch control plane and one for
running your own applications. It applies all necessary components to get a fully functional local development
environment.

#### 1. **Creates the Control Plane Cluster**

A Kind cluster named `klutch-control-plane` is created using the configuration defined in `scripts/kind/kind_control_plane.yaml`.
This configuration:

* Maps port 8080 on your host machine to port 80 inside the cluster, making the Ingress controller accessible.
* Adds `host.docker.internal` as a Subject Alternative Name (SAN) in the Kubernetes API server certificate for proper
OIDC communication with Dex.

#### 2. **Exports the Cluster's CA Certificate**

After the cluster is running, the script discovers the dynamically assigned API server port. The script extracts the CA
certificate of the control plane cluster and saves it as `overlays/kind-docker/klutch-control-plane-ca.crt`.
This certificate is used by the Klutch backend for secure API communication.

#### 3. **Installs Required Components**

The script installs all critical components in sequence, including:

* **Crossplane core** and the **provider-kubernetes** plugin.
* **Klutch backend CRDs** for managing custom resources.
* **Cert-Manager** for TLS certificate automation.
* **Minio** for local object storage.
* The **a8s framework** for provisioning data services.
* All additional infrastructure defined in the `overlays/kind-docker` overlay (e.g., Dex, NGINX Ingress).

#### 4. **Creates an Application Cluster**

A second Kind cluster named `klutch-app` is created. This cluster represents where your applications will run and
consume data services. At this stage, nothing is pre-installed in the application cluster. A lightweight Kubernetes
deployment will be installed automatically once the first binding to any Klutch API is made by the user.

#### 5. **Final Output**

Once both clusters are running, the script provides instructions for connecting the application cluster to the control
plane using the `kubectl bind` command.

## Bind to Klutch’s APIs from the Application Cluster

After the script completes successfully, it will display a command that you need to run manually. This command initiates
the binding process from your application cluster to the Klutch control plane APIs.

Copy and paste the command into your terminal:

```bash
kubectl bind http://host.docker.internal:8080/export --konnector-image public.ecr.aws/w5n9a2g2/anynines/konnector:v1.3.0 --context kind-klutch-app
```

The following actions will be performed as a result of this command:

- The kubectl-bind plugin starts the OIDC authentication process and automatically installs the `konnector` Kubernetes
deployment in the App Cluster when the first binding request is made.

- A browser window will open, prompting you to log in with your OIDC credentials. Grant access to the OIDC client and
confirm in the terminal when prompted.

The API binding process must be completed one service at a time. To bind multiple services, re-run the kubectl-bind
command and log in again as needed.

For this environment, use the following credentials:

* **Email Address:** `admin@example.com`
* **Password:** `password`

Once authenticated, you can select the service to bind using the Klutch web UI, as shown below:

![Bind an a9s Data Service using the web UI](images/klutch-bind-ui.png)

You can now start provisioning data services, your App Cluster is fully configured and **ready to go!**

**Note:** If the login page displays a `400 Bad Request` or `Request Header Or Cookie Too Large` error, please **clear the cookies**
for the `host.docker.internal` site in your browser and try again.

## Cleanup

When you are finished with the local environment, you can delete both clusters with the following commands:

```bash
kind delete cluster --name klutch-control-plane
kind delete cluster --name klutch-app
```

## Next Steps

Your Kind-based Klutch environment is now ready. You can proceed to the [Deploying a Demo Application](/docs/example.md)
to test your setup by provisioning a PostgreSQL database.
