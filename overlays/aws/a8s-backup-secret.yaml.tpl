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