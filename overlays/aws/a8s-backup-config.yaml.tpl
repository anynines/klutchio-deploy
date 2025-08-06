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