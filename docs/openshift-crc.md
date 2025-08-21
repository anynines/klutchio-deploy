# Deploying Klutch on OpenShift CRC

This guide provides step-by-step instructions for setting up a Klutch control plane on a local [OpenShift CodeReady Containers (CRC)](https://developers.redhat.com/products/codeready-containers/overview) instance.

The process involves a one-time manual setup of CRC, followed by an automated script that deploys the entire Klutch stack, including an application cluster, which is provisioned using kind.

### Prerequisites

Before running the deployment script, you must install and configure your CRC environment.

1.  **Install CRC**: After [setting up your account](https://sso.redhat.com/), log in to the Red Hat Console and navigate to the Hybrid Cloud Console for local installation. *Tested with versions:* CRC: 2.53.0+a6f712, OpenShift: 4.19.3 and MicroShift: 4.19.0

    To get started with OpenShift Local, download the crc tool directly from the Red Hat Console.
    Once logged in, download both the installation package and the pull secret from the OpenShift Local page.

2.  **Configure CRC Resources**: OpenShift is resource-intensive. It is highly recommended to allocate sufficient CPU and memory to ensure a smooth experience.

    ```bash
    crc setup
    crc config set cpus 7
    crc config set memory 14384
    crc config set disk-size 35
    ```

3.  **Start CRC**: You will need a pull secret from your Red Hat account to start the virtual machine.

    ```bash
    crc start -p /path/to/your/pull-secret.txt
    ```

4.  **Log in to the Cluster**: You must be logged in as `kubeadmin` for the script to work.
    *   **Set up your shell environment**:
        ```bash
        eval $(crc oc-env)
        ```
    *   **Log in via the CLI**:
        ```bash
        oc login -u kubeadmin https://api.crc.testing:6443
        ```

### Application Cluster Requirement

This setup requires a second Kubernetes cluster to act as the **application cluster**. The provided `openshift-crc.sh` script automates this for you by creating a **Kind** cluster.

*   **If you use the script as-is**, You must have Kind and Docker installed and running. Kind is used to create the local Kubernetes clusters (**[installation instructions](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)**), and it requires a container runtime like **[Docker Desktop](https://www.docker.com/products/docker-desktop/)**. The script has been tested and is known to work with **Kind `v0.29.0`** and **Docker `v28.3.3` (build `980b856816`)**.
*   **If you prefer to use another type of cluster** (e.g., k3d, another CRC instance, a cloud-based cluster), you can still use the script. It will set up the control plane correctly. You will just need to adapt the `kubectl bind` and cleanup commands in the final steps to target your chosen cluster's context instead of the Kind cluster.

## Automated installation using a setup script

> **NOTE: The Openshift-CRC overlay is for development and testing only**
>
> The provided script and the Openshift-CRC Kustomize overlay are intended solely for local development and testing. This
setup is not secure, it uses plain HTTP for endpoints and includes hardcoded secrets and credentials. **Do not use this configuration in production environments.**

Once you have successfully set up and logged into your CRC instance, the rest of the installation is automated.

From the root of this repository, execute the following script:

```bash
./scripts/openshift-crc/openshift-crc.sh
```

### What the Script Does

The script automates all the necessary steps to configure your CRC instance as a Klutch control plane:

1.  **Verifies Login**: Checks that you are properly logged into the OpenShift cluster.
2.  **Exports Certificates**: OpenShift has a unique certificate infrastructure. The script automatically exports three critical certificates and saves them to the `overlays/openshift-crc/` directory for use by the Klutch components:
    *   The cluster's root Certificate Authority (CA).
    *   The OpenShift Ingress Operator's CA.
    *   The default router's serving certificate.
3.  **Deploys the Klutch Stack**: It uses Kustomize to build and apply all necessary components using the OpenShift-specific overlay (`overlays/openshift-crc`). This includes:
    *   Klutch Backend and CRDs.
    *   Crossplane, `provider-kubernetes`, and the anynines `Configuration`.
    *   Cert-Manager.
    *   Dex, configured with OpenShift `Route` resources instead of standard Ingresses.
4.  **Applies Security Patches**: It applies an OpenShift-specific `SecurityContextConstraints` for Crossplane and patches the `system:controller:statefulset-controller` ClusterRole to grant it the necessary permissions to manage data service finalizers.
5.  **Waits for Readiness**: The script includes checks to ensure all deployments and pods are fully running before proceeding.
6.  **Creates Application Cluster**: Finally, it creates a separate Kind cluster named `klutch-app` to serve as the consumer of your data services. Additionally, it configures DNS inside the cluster in such a way to allow the cluster to communicate with the control plane.

## Step 2: Bind the Application Cluster

After the script completes, it will display a final command that you must run manually. This command binds your new `klutch-app` cluster to the control plane.

Copy and paste the command into your terminal:

```bash
kubectl-bind https://klutch.apps-crc.testing/export --konnector-image public.ecr.aws/w5n9a2g2/anynines/konnector:v1.3.0 --context kind-klutch-app
```

This command uses the `kubectl-bind` plugin to install a lightweight "konnector" pod into the `klutch-app` cluster, which acts as a secure proxy to the control plane.

## Next Steps

Your Kind-based Klutch environment is now ready. You can proceed to the [Deploying a Demo Application](/docs/example.md)
to test your setup by provisioning a PostgreSQL database.

## Cleanup

When you are finished, you can destroy the entire environment with the following commands:

```bash
# Stop and delete the CRC virtual machine
crc stop
crc delete --force

# Delete the Kind application cluster
kind delete cluster --name klutch-app
```
