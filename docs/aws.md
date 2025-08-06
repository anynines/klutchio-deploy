# Deploying Klutch on AWS EKS

This guide outlines the steps for deploying Klutch on AWS Elastic Kubernetes Service (EKS). It includes the required
infrastructure setup, identity and access configurations, DNS setup, and OpenID Connect (OIDC) integration.

## 1. Infrastructure Requirements

Before running the deployment script, you must provision the following AWS resources.

### EKS Cluster

* **Kubernetes version:** 1.33 or later
* **Node group:**
  * Instance type: `t3a.large`
* **Add-ons:**
  * Metrics Server
  * EBS CSI Driver
* **Access control:** The IAM user or role used to create the cluster is automatically granted administrative access.

### IAM User for Backups

Create a dedicated IAM user for managing backups. This user requires programmatic access (an access key ID and a secret
access key). Attach an inline policy granting the following S3 permissions on your designated backup bucket:

*   `s3:GetObject`
*   `s3:PutObject`
*   `s3:DeleteObject`
*   `s3:ListBucket`

### S3 Bucket

Create a dedicated S3 bucket to store data service backups managed by Klutch.

## 2. Deploy Ingress Controller and Configure DNS

The NGINX Ingress Controller exposes Klutch's backend services to the internet.

### 2.1. Deploy the Ingress Controller

Deploy the controller using the provided Kustomize overlay. This command will create the `ingress-nginx` namespace and
all the required resources.

```sh
kustomize build --enable-helm overlays/aws/ingress-nginx | kubectl apply -f -
```

After applying, wait for the deployment to become available. This ensures the controller is running before you proceed.

```sh
kubectl wait --namespace ingress-nginx \
  --for=condition=available deployment/ingress-nginx-controller \
  --timeout=300s
```

### 2.2. Retrieve the Load Balancer Hostname

Once the controller is ready, AWS will provision an Elastic Load Balancer (ELB) to expose it. This process can take a
few minutes. Retrieve the public hostname with the following command:

```sh
kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

The command will return a hostname similar to this:
`a1c45cxxxa-93xxx6.elb.eu-central-1.amazonaws.com`

### 2.3. Create a DNS Record

You must now create a **CNAME record** in your DNS provider to point a user-friendly hostname to the AWS Load Balancer
address. This hostname will be your `$KLUTCH_URL`.

*   **Your Hostname:** `klutch.example.com`
*   **Points To:** `a1c45cxxxa-93xxx6.elb.eu-central-1.amazonaws.com`

If you are using AWS Route 53, navigate to your domain's Hosted Zone and create a new `CNAME` record with the value set
to the Load Balancer hostname.

## 3. OIDC Integration with Keycloak

This guide assumes you have an existing Keycloak instance. You must configure a new client for Klutch.

### Keycloak Client Configuration

1.  **Log in** to the Keycloak Admin Console.
2.  **Create a New Client** with the following settings:
    *   **Client type:** OpenID Connect
    *   **Client ID:** A unique identifier (e.g., `klutch-aws`)
    *   **Root URL:** `https://<your_cname>` (e.g., `https://klutch.example.com`)
    *   **Valid Redirect URIs:** `https://<your_cname>/callback`
    *   **Valid Post Logout Redirect URIs:** `https://<your_cname>`
    *   **Web origins:** `https://<your_cname>`
3.  **Enable the following features** in the client's **Settings** tab:
    *   Client authentication
    *   Authorization
    *   Standard flow
    *   Front channel logout
    *   Backchannel logout session required
4.  **Get the Client Secret:** Open the **Credentials** tab and copy the **Client secret**.
5.  **Advanced Settings:** In the **Advanced** tab, enable the `Always use lightweight access token` option.

![Keycloak Settings Example 1](/docs/images/keycloak.png)![Keycloak Settings Example 2](/docs/images/keycloak.png)

## 4. Deployment

The rest of the Klutch components are deployed using an automated script.

### 4.1. Configure Environment Variables

Before running the deployment script, you must configure your local environment.

1.  **Create an `.env` file:** In the `overlays/aws/` directory, copy the template file.

    ```sh
    cp overlays/aws/.env.template overlays/aws/.env
    ```

2.  **Edit the `.env` file:** Fill in the values with the information from the previous steps. This file stores
sensitive data and should not be committed to Git.

    ```sh
    # overlays/aws/.env

    # AWS credentials for the backup user
    export AWS_ACCESS_KEY_ID_BU_USER="your-access-key-id"               # Used to perform S3 backups
    export AWS_SECRET_ACCESS_KEY_BU_USER="your-secret-access-key"       # Used to perform S3 backups

    # Password for encrypting sensitive data
    export ENCRYPTION_PASSWORD="your-strong-encryption-password"        # You can generate and specify your own

    # S3 bucket configuration for storing backups
    export S3_BUCKET_NAME="your-s3-bucket-name"
    export S3_BUCKET_REGION="your-s3-bucket-region"

    # OIDC (OpenID Connect) settings for authentication via Keycloak or another provider
    export OIDC_ISSUER_CLIENT_ID="your-oidc-client-id"
    export OIDC_ISSUER_CLIENT_SECRET="your-oidc-client-secret"
    export OIDC_ISSUER_URL="https://your-oidc-issuer-url"               # Typically: https://<keycloak-host>/realms/<realm>
    export OIDC_CALLBACK_URL="https://your-domain/callback"             # Should match the redirect URI configured in the oidc

    # Public address of your Klutch instance. For AWS EKS, this MUST be the public API server endpoint.
    # aws eks describe-cluster --name <your-eks-cluster-name> --region <your-aws-region> --query "cluster.endpoint" --output text
    export EXTERNAL_ADDRESS="https://<id>.<region>.eks.amazonaws.com"   # The public endpoint of your EKS cluster

    # Cookie secrets for session management (32-byte base64-encoded values)
    export COOKIE_SIGNING_KEY="your-cookie-signing-key-base64"
    export COOKIE_ENCRYPTION_KEY="your-cookie-encryption-key-base64"
    ```

### 4.2. Run the Deployment Script

Configure your cluster targets by exporting the required environment variables, then run the automated deployment script
from the root of the repository.

```sh
# Set the kubectl context for your AWS EKS control plane cluster.
export CONTROL_PLANE_CONTEXT="<my-eks-cluster>"

# Define a name for the local application cluster the script will create.
export APP_CLUSTER="<klutch-app>"

# Execute the deployment script.
./scripts/aws/aws.sh
```

The script will deploy and configure the rest of the Klutch platform, including Crossplane, Cert-Manager, the Klutch
backend, and the anynines data services framework.

## 5. Connect the Application Cluster

After the script completes successfully, it will provide the command needed to bind your local `kind` cluster to the new
Klutch control plane running in EKS.

Copy and run the command provided in the script's output:

```sh
kubectl bind https://<klutch.example.com>:443/export \
  --konnector-image=public.ecr.aws/w5n9a2g2/klutch/konnector:v1.3.2 \
  --context kind-klutch-app
```

Once authenticated, you can select the service to bind using the Klutch web UI, as shown below:

![Bind an a9s Data Service using the web UI](images/klutch-bind-ui.png)

You can now start provisioning data services, your App Cluster is fully configured and **ready to go!**

Your Klutch environment is now fully deployed and ready to use.
