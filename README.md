# Klutch Installation Guide

This repository provides the necessary Kustomize configurations and automation scripts to install Klutch and its
dependencies across various Kubernetes environments.

## Overview

KlutchIO is an open-source, Kubernetes-native tool designed to simplify data service management across multiple clusters.
To learn more about its concepts and architecture, you can visit the official documentation at https://klutch.io/docs/.

This repository provides the necessary Kustomize configurations and automation scripts to install KlutchIO, structured
using a Kustomize base/overlay pattern:

*   `components/`: Includes the core services required to run Klutch, such as the Klutch backend, Crossplane, the a8s
data services framework, OIDC integration, and other essential cluster services.
*   `overlays/`: Provides environment-specific patches and configurations for different targets like [Kind](https://kind.sigs.k8s.io/),
[Rancher Desktop](https://rancherdesktop.io/), [OpenShift](https://www.redhat.com/en/technologies/cloud-computing/openshift),
and [AWS](https://aws.amazon.com/).
*   `scripts/`: Includes automation scripts to streamline the installation process for each supported environment.
*   `docs/`: Contains installation guides.
*   `example/`: Offers working examples that show how to provision a PostgreSQL instance and connect it to a demo application in a Kind environment.

### Core Components & Flexibility

The repository is designed for flexibility, allowing you to adapt the installation to your specific needs by swapping
out components. The `overlays` directory demonstrates this modularity in practice.

The diagram below illustrates the high-level architecture of this setup:
![high level architecture](/docs/images/high_level_architecture.png)

### Control Plane Cluster

The following components are installed on the Control Plane Cluster to enable centralized management of data services
with Klutch.

Core components include:

*   **KlutchIO Backend**: The central component that manages service exports and bindings.
*   **Authentication (OIDC)**: Handles authentication for connecting application clusters. The choice of provider can be
tailored to the environment. For example, local development setups might use **Dex** for its simplicity, while production
environments could integrate with a more robust solution like **Keycloak** for enterprise-grade features.
*   **Crossplane**: Acts as the underlying infrastructure-as-code framework. This installation includes the core
Crossplane engine, provider-kubernetes for managing resources within the cluster, and a custom KlutchIO Configuration
package.
*   **Data Services Framework**: Provides the actual data services to be provisioned. Currently, the **anynines DataServices Framework**
for PostgreSQL is supported by default. However, the architecture is extensible, with plans to support additional data
service frameworks in the future.
*   **Backup Storage**: Manages data service backups. The configuration is flexible; for example, a local development
environment might use an in-cluster **Minio** instance for convenience, while a production deployment would target a
durable, remote object store like **Amazon S3**.
*   **Cert-Manager**: Manages TLS certificates within the cluster.

### App Cluster

The App cluster, which binds to and consumes the Klutch APIs from the control plane, does not require any special
pre-installation of these components.

The kubectl-bind CLI tool handles the entire setup process. When you run the bind command for the first time to connect
to the control plane, it will automatically install a lightweight Kubernetes deployment (the "konnector") into your
application cluster. This konnector acts as a proxy, enabling secure communication and allowing you to manage service
instances directly from your application cluster's kubectl context.

## Installation Instructions

This repository offers a modular approach, providing the individual Klutch components needed to automate deployment
across different environments. For several common environments, we already include detailed instructions and scripts to
streamline and automate the setup process. If an automated script is not available for your target environment, the
generic guide serves as a template to help you create a new overlay based on your needs.

*   **[Generic Instructions](docs/generic.md)**
*   **[Kind (with Docker Desktop)](docs/kind.md)**
*   **[Rancher Desktop](docs/rancher-desktop.md)**
*   **[AWS EKS](docs/aws.md)**

## Prerequisites

### General Requirements

*   **[kubectl](https://kubernetes.io/docs/tasks/tools/)**: The Kubernetes command-line tool.
*   **[Kustomize](https://kustomize.io/)**: A tool for customizing Kubernetes resource configuration.
*   **[Helm](https://helm.sh/docs/helm/helm_install/)**: The package manager for Kubernetes.
*   **kubectl-bind CLI**: This tool is required to bind to the Klutch control plane APIs.


### Environment-Specific Requirements

*   **Local Development**:
    *   **Kind** or **Rancher Desktop** or **OpenShift CodeReady Containers (CRC)**.
    *   Minimum **14 GB of RAM** and **6 CPU cores** allocated to your virtual machine or container runtime.
*   **Cloud Providers (e.g., AWS)**:
    *   **Node Requirements**: If you plan to host highly available, container-based data services using the a8s framework
    within the Control Plane Cluster, ensure the cluster consists of at least three worker nodes. Each node should have
    resources equivalent to or exceeding an **AWS t3a.xlarge instance** (4 vCPUs and 16 GiB memory).

## Installing the `kubectl-bind` CLI

To bind an application cluster to the control plane, you’ll need to install the `kubectl-bind` plugin.

### 1. Download the Binary

Choose the appropriate link for your OS and architecture:

| Operating System | Architecture | Download Link |
| :--- | :--- | :--- |
| **macOS** | Intel (amd64) | [Download (v1.3.0)](https://anynines-artifacts.s3.eu-central-1.amazonaws.com/central-management/v1.3.0/darwin-amd64/kubectl-bind) |
| | Apple Silicon (arm64) | [Download (v1.3.0)](https://anynines-artifacts.s3.eu-central-1.amazonaws.com/central-management/v1.3.0/darwin-arm64/kubectl-bind) |
| **Linux** | i386 | [Download (v1.3.0)](https://anynines-artifacts.s3.eu-central-1.amazonaws.com/central-management/v1.3.0/linux-386/kubectl-bind) |
| | amd64 | [Download (v1.3.0)](https://anynines-artifacts.s3.eu-central-1.amazonaws.com/central-management/v1.3.0/linux-amd64/kubectl-bind) |
| **Windows** | i386 | [Download (v1.3.0)](https://anynines-artifacts.s3.eu-central-1.amazonaws.com/central-management/v1.3.0/windows-386/kubectl-bind.exe) |
| | amd64 | [Download (v1.3.0)](https://anynines-artifacts.s3.eu-central-1.amazonaws.com/central-management/v1.3.0/windows-amd64/kubectl-bind.exe) |

### 2. Install the Binary

#### macOS & Linux

Move the binary to a location in your `PATH`, such as `/usr/local/bin`, and make it executable.

```bash
# You may need sudo depending on the destination's permissions
sudo mv ~/Downloads/kubectl-bind /usr/local/bin/
sudo chmod +x /usr/local/bin/kubectl-bind
```

> **macOS Security Warning**: If you are blocked by a security warning ("can't be opened because Apple cannot check it for malicious software"), go to **System Settings > Privacy & Security**, scroll down, and click **"Allow Anyway"**. You may need to run the command again to confirm.

#### Windows

Place the `kubectl-bind.exe` file in a directory (e.g., `C:\Program Files\kubectl-plugins`) and add that folder to your
system's `PATH` environment variable.

### 3. Verify the Installation

Run the following command to ensure the plugin is installed correctly:

```bash
kubectl bind
```

You should see the plugin’s help output.

## Managing Component Versions
Klutch is pinned to specific versions of its dependencies to ensure stability. You can customize these versions by
modifying the configuration files within the components/ directory.

### 1. Helm-Based Components

For components managed by **Helm charts**, you can update the chart version directly.

*   **Components**: Crossplane, Cert-Manager, Minio.
*   **How to Update**:
    1.  Navigate to the component's directory (e.g., `components/crossplane/core/`).
    2.  Open the `kustomization.yaml` file.
    3.  Modify the `version` field within the `helmCharts` section.

### 2. Container Image-Based Components

For components deployed as standard Kubernetes **Deployments**, their version is controlled by the container image tag.

*   **Components**: KlutchIO Backend, Dex.
*   **How to Update**:
    1.  Navigate to the component's directory (e.g., `components/oidc/dex/`).
    2.  Open the `resources.yaml` file.
    3.  Locate the `Deployment` resource and update the `image:` tag to the desired version.

### 3. URL-Based Components

For components installed from **remote manifest files**, their version is embedded directly in the URL or package identifier.

*   **Components**: a8s Data Services Framework, KlutchIO CRDs, KlutchIO Crossplane Configuration.
*   **How to Update**:
    *   For the **a8s Framework and Klutch CRDs**, find the relevant `kustomization.yaml` files (e.g., `components/data-services/a8s-framework/core/`)
    and update the version tag within the `https://...` resource URLs.
    *   For the **KlutchIO Crossplane Configuration**, edit the `configuration-package.yaml` file in its component
    directory and update the version tag in the `spec.package` image string.
