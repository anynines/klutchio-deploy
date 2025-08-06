# Klutch in Action: PostgreSQL + Blog Application Walkthrough

**Prerequisite**: Ensure that you have bound to the Klutch API and made it available to your app cluster. You can bind
to the Klutch control plane API with the process described [here](kind.md/#bind-to-klutchs-apis-from-the-application-cluster).
After a successful binding to the PostgreSQL data service, the following Custom Resource Definitions (CRDs) should be
present and available in your Application Cluster:

```bash
kubectl get crds
````

Expected output:

```bash
apiservicebindings.klutch.anynines.com
backups.anynines.com
postgresqlinstances.anynines.com
restores.anynines.com
servicebindings.anynines.com
```

### 1. Deploy a PostgreSQL Instance

Navigate to the example directory:

```bash
cd examples/
```

Provision a PostgreSQL instance in your App Cluster:

```bash
kubectl apply -f 0-postgres-instance.yaml
```

### 2. Create a ServiceBinding

Allow your application to access the database by creating a `ServiceBinding`:

```bash
kubectl apply -f 1-servicebinding.yaml
```

This creates a Secret named `example-pg-instance-service-binding` in the `default` namespace containing the database
credentials and connection details.

### 3. Set Up Local Network Access

Wait for the PostgreSQL to be ready. If it's your first time applying the manifest, it may take a couple of minutes to
pull the container image.

Then run:

```bash
./2-setup-network.sh
```

This bridges the Control Plane to the PostgreSQL service in the App Cluster by applying a dummy service and setting up
port-forwarding for local access.

### 4. Deploy the Blog Application

In a new terminal tab, deploy the sample blog application:

```bash
kubectl apply -f 3-blog-app.yaml
```

### 5. Access the Application

Expose the app locally by running:

```bash
kubectl port-forward svc/demo-app 3000:3000
```

Open your browser and go to [http://localhost:3000](http://localhost:3000) to explore the blog interface.

---

### 6. Back Up Your Blog Posts

To create a backup of your blog posts, apply the following manifest:

```bash
kubectl apply -f 4-backup.yaml
```

### 7. Restore from a Backup

If you lose data or want to roll back, you can restore from a backup by applying:

```bash
kubectl apply -f 5-restore.yaml
```

You've seen how to provision a PostgreSQL instance, deploy an app, back up data, and restore it, all using Klutch and
Kubernetes resources in a local setup.
