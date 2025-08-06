# General Klutch Installation

This guide provides a comprehensive walkthrough for installing Klutch using its modular component repository. It is
designed to offer flexibility for deployment across various environments by breaking down the installation into logical,
self-contained components.

## Component Repository Structure

The repository is organized to reflect the modular architecture of Klutch. Each directory under components represents a
core part of the Klutch control plane. These components must be installed in the control plane cluster.

The application cluster does not require any pre-installed components. When you run the kubectl bind command for the
first time, it automatically installs a lightweight Kubernetes deployment (the konnector), this is the only component
the application cluster needs to interact with the control plane.

```
components
├── backup-storage
├── cluster-services
├── crossplane
├── data-services
├── klutch-bind-backend
└── oidc
```

## Installation Steps

The following sections detail the installation of each component from the repository.

### 1. OIDC Provider

Klutch uses OIDC for secure user authentication. The component repository provides configurations for deploying either
Dex or Keycloak as your identity provider.

#### Dex

Dex is a lightweight, open-source identity provider that can be used to handle OIDC workflows.

*   **Component Location**: `components/oidc/dex`
*   **Purpose**: Handles user authentication and issues tokens for accessing the Klutch backend.

**Installation and Configuration**

Applying the base files under the `components/oidc/dex` directory is not sufficient for a complete deployment. These
files provide a generic template that must be configured with details specific to your environment. In this repository,
environment-specific configurations are managed through Kustomize overlays, keeping the base components general and
reusable.

To successfully deploy Dex, you will need to configure the following:

1.  **Issuer and Callback URLs**: Dex needs to know its public-facing URL (the `issuer`) and the callback URL for the
OIDC client. These are critical for the OIDC redirect flow.

2.  **Client Credentials**: You must define a static client with a unique ID and secret. The Klutch backend will use
these credentials to authenticate itself with Dex.

3.  **User Database**: For development and testing, Dex can be configured with a static list of users and passwords. In
a production scenario, you would connect Dex to an external identity provider (like LDAP, SAML, or GitHub).

4.  **Ingress Rules**: An Ingress resource is required to expose the Dex service outside the cluster so that users and
the Klutch backend can reach it.

**Example Configuration (Managed via Overlays)**

In a specific environment overlay (e.g., for a local `kind` setup), you would define the following resources:

A **Secret** containing the client credentials and URLs for the Klutch backend to consume:

```yaml
# Example Secret for Klutch backend
apiVersion: v1
kind: Secret
metadata:
  name: oidc-config
  namespace: bind # Or your Klutch backend namespace
stringData:
  OIDC-ISSUER-CLIENT-ID: "klutch-bind"
  OIDC-ISSUER-CLIENT-SECRET: "paxfCR83s3r/1AnOQPjc9g3Q4P+8BG1rJQvEGcik0QtCt57TSsTFs8=" # Replace with a generated secret
  OIDC-ISSUER-URL: "http://host.docker.internal:8080/dex" # URL where Dex is exposed
  OIDC-CALLBACK-URL: "http://host.docker.internal:8080/callback" # Klutch backend callback
```

A **ConfigMap** to configure the Dex instance itself:

```yaml
# Example Dex ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: dex-config
  namespace: dex # Or your Dex namespace
data:
  config.yaml: |
    issuer: http://host.docker.internal:8080/dex
    storage: {type: memory}
    web: {http: 0.0.0.0:5556}
    staticClients:
      - id: klutch-bind
        redirectURIs: ['http://host.docker.internal:8080/callback']
        name: 'Klutch Bind'
        secret: "paxfCR83s3r/1AnOQPjc9g3Q4P+8BG1rJQvEGcik0QtCt57TSsTFs8=" # Must match the secret above
    enablePasswordDB: true
    staticPasswords:
      - email: "admin@example.com"
        hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W" # Pre-hashed password
        username: "admin"
        userID: "08a8684b-db88-4b73-90a9-3cd1661f5466"
```

An **Ingress** to expose the Dex service:

```yaml
# Example Dex Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dex-ingress
  namespace: dex # Or your Dex namespace
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - pathType: Prefix
        path: "/dex"
        backend:
          service:
            name: dex
            port:
              number: 5556
```

To deploy Dex for a specific environment, you would apply the corresponding Kustomize overlay, which combines the base
`dex` component with these environment-specific configurations.

```bash
# Example: Applying an overlay for a 'development' environment
kustomize build overlays/development | kubectl apply -f -
```

#### Keycloak

Klutch can also be used with Keycloak. Instructions for how to configure Keycloak so it can be used with Klutch can be
found in the documentation page for AWS. In that case, we assume that there is already an existing Keycloak setup and we
just want to expose to the `klutch-bind-backend` all the info that it needs to communicate with it. As such, no
component is provided for installation. Instead of providing installation files, the focus is on configuring your
existing Keycloak instance to work as an OIDC provider for Klutch.

### 2. Backup Storage

A reliable backup storage solution is crucial for data service backups. This guide covers using Minio for local or
on-premises setups and AWS S3 for cloud-based deployments.

#### Minio

Minio provides an S3-compatible object storage server that you can host yourself. It is ideal for local development,
testing, or on-premises deployments.

*   **Component Location**: `components/backup-storage/minio`
*   **Purpose**: Provides an S3-compatible backend to store backups of your data services.
*   **Installation**:
    1.  Navigate to the `components/backup-storage/minio` directory.
    2.  Review the `minio-secret.template.yaml` and create a `minio-secret.yaml` file with your desired credentials
         (access key and secret key).
    3.  Apply the components using Kustomize, which will deploy Minio to your cluster:
        ```bash
        kustomize build . | kubectl apply -f -
        ```

In addition to deploying Minio and its credentials, you must also create a `ConfigMap` in the `a8s-system` namespace.
This `ConfigMap` instructs the a8s framework on how to connect to your Minio instance. A typical configuration would
look like this:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: a8s-backup-store-config
  namespace: a8s-system
data:
  backup-store-config.yaml: |
    config:
      cloud_configuration:
        provider: AWS
        container: a8s-backups
        region: eu-central-1 # This can be any valid region string
        endpoint: http://minio.minio.svc.cluster.local:9000 # The internal service URL for Minio
        path_style: true
```

**Key Configuration Points:**

*   **`provider: AWS`**: Since Minio is S3-compatible, you use the `AWS` provider type.
*   **`endpoint`**: This is the most critical field for Minio. It must point to the internal Kubernetes service DNS
name of your Minio deployment. The example `http://minio.minio.svc.cluster.local:9000` assumes Minio is deployed in the
`minio` namespace with a service named `minio`.
*   **`path_style: true`**: This setting is required to ensure compatibility with Minio's URL structure.

#### AWS S3

AWS S3 can also be used for storing data service backups. As S3 is a managed service by AWS, there is no installation
component in the repository. Instead, it can be used by simply defining a Kubernetes Secret and a ConfigMap that will
be used by the a8s framework to access your S3 bucket.

You will need to create the following resources in the `a8s-system` namespace of your Control Plane Cluster:

1.  **A Secret** to securely store the credentials for your backup user:

    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: a8s-backup-storage-credentials
      namespace: a8s-system
    type: Opaque
    stringData:
      access-key-id: "${AWS_ACCESS_KEY_ID_BU_USER}"
      secret-access-key: "${AWS_SECRET_ACCESS_KEY_BU_USER}"
      encryption-password: "${ENCRYPTION_PASSWORD}"
    ```

2.  **A ConfigMap** to configure the backup store settings, specifying S3 as the provider and providing your bucket details:

    ```yaml
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: a8s-backup-store-config
      namespace: a8s-system
    data:
      backup-store-config.yaml: |
        config:
          cloud_configuration:
            provider: AWS
            container: "${YOUR_BUCKET_NAME}"
            region: "${YOUR_BUCKET_REGION}"
    ```

These resources instruct the a8s data service operators to use your specified S3 bucket as the target for all backup
operations.

### 3. Cluster Services (Cert-Manager)

Cert-Manager is a foundational component for managing TLS certificates within your cluster.

*   **Component Location**: `components/cluster-services/cert-manager`
*   **Purpose**: Automates the management and issuance of TLS certificates from various issuing sources.
*   **Installation**:
    1.  Navigate to the `components/cluster-services` directory.
    2.  Apply the Cert-Manager components:
        ```bash
        kustomize build --enable-helm . | kubectl apply -f -
        ```

### 4. Crossplane

Crossplane is leveraged by Klutch to enable the provisioning and management of infrastructure and services across
different environments.

*   **Component Location**: `components/crossplane/core`
*   **Purpose**: Provides the core Crossplane functionality.
*   **Installation**:
    1.  Navigate to the `components/crossplane/core` directory.
    2.  Install Crossplane into your Control Plane cluster:
        ```bash
        kustomize build --enable-helm . | kubectl apply -f -
        ```

### 5. Data Services (a8s Framework)

This component includes the necessary integrations for the a8s data services framework.

*   **Component Location**: `components/data-services/a8s-framework`
*   **Purpose**: Installs the a8s framework, including Crossplane integrations and the required providers.
*   **Installation**:
    1.  Navigate to the `components/data-services/a8s-framework` directory.
    2.  Apply the framework components:
        ```bash
        kubectl apply -k .
        ```

### 6. Klutch Bind Backend

This is the core of the Klutch Control Plane, responsible for handling API binding requests and managing service exports.

*   **Component Location**: `components/klutch-bind-backend`
*   **Purpose**: Manages API service exports and the binding process. The `klutch-bind-backend` verifies authentication
requests through OIDC and enables the creation of service accounts and bindings for Application Clusters.

**Installation and Configuration**

Applying the base files under the `components/klutch-bind-backend` directory is not sufficient for a complete deployment.
The base component acts as a template, and many parameters are environment-dependent. These configurations are managed
through Kustomize overlays to keep the base component general and reusable.

To successfully deploy the `klutch-bind-backend`, you will need to configure several key aspects, which are typically
defined within an environment-specific overlay (e.g., `overlays/kind-docker`).

1.  **OIDC Configuration**: The backend needs to know how to communicate with your OIDC provider (like Dex or Keycloak).
This is typically configured via a `Secret`.

    ```yaml
    # Example defined in Kind-Docker overlay's kustomization.yaml
    secretGenerator:
      - name: oidc-config
        namespace: bind
        literals:
          - OIDC-ISSUER-CLIENT-ID="klutch-bind"
          - OIDC-ISSUER-CLIENT-SECRET="/1AnOQPjc9g3Q4P+8BG1rJQvEGcik0QtCt57TSsTFs8="
          - OIDC-ISSUER-URL="http://host.docker.internal:8080/dex"
          - OIDC-CALLBACK-URL="http://host.docker.internal:8080/callback"
    ```

2.  **Cookie Security**: Secure keys for signing and encrypting session cookies must be provided.

    ```yaml
    # Example defined in an overlay's kustomization.yaml
    secretGenerator:
      - name: cookie-config
        namespace: bind
        literals:
          - COOKIE-SIGNING-KEY="NQ7BQKIpuj68FlksdjHfZIM9ZwmXN61M3632wIPaQmc="
          - COOKIE-ENCRYPTION-KEY="3wdxRGrS6nU4DvAQ5c/DPUL4ONOQS7Qym9lLAeqmtSI="
    ```

3.  **Backend Configuration**: The backend needs to be aware of its own external address for generating correct URLs.
This is configured via a `ConfigMap`.

    ```yaml
    # Example defined in an overlay's kustomization.yaml
    configMapGenerator:
      - name: klutch-bind-backend-config
        namespace: bind
        literals:
          - external-address=https://host.docker.internal:6443 # This should be the address of your K8s API server
    ```

4.  **Ingress Rules**: An Ingress resource is required to expose the `klutch-bind-backend` service.

    ```yaml
    # Example Ingress manifest included in an overlay
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: klutch-bind-backend
      namespace: bind
      annotations:
        nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    spec:
      ingressClassName: nginx
      rules:
      - http:
          paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: klutch-bind-backend
                port:
                  number: 443
    ```

**Deployment**

To deploy the `klutch-bind-backend` for a specific environment, you apply the corresponding Kustomize overlay, which
combines the base component with these environment-specific configurations.

You can use the existing overlays as an example for creating your own deployment configurations.

```bash
# Example: Applying the overlay for the 'kind-docker' environment
kustomize build --enable-helm overlays/kind-docker | kubectl apply -f -
```

### 7. Binding to Klutch Control Plane APIs

Once the Control Plane is fully deployed, you can bind to the Klutch control plane APIs and manage data services from
your Application Cluster.

1.  **Install the `kubectl-bind` CLI**: Follow the instructions in the main Klutch documentation to install the
`kubectl-bind` plugin. This tool is required to bind your application cluster to the Klutch control plane APIs.

2.  **Bind to Klutch's APIs**: From your Application Cluster's context, run the `kubectl bind` command, pointing to the
export URL of your Klutch backend.

    ```bash
    kubectl bind <your-klutch-backend-export-url> --context <your-app-cluster-context>
    ```

    This command initiates the OIDC authentication flow and installs the `konnector` in the Application Cluster. The
    `konnector` is a lightweight agent that facilitates communication between the Application Cluster and the Control
    Plane, enabling you to provision and manage data services.
