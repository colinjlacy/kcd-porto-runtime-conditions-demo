#!/usr/bin/env bash
# Kratix configure pipeline: renders a PostgreSQL StatefulSet, Service, ConfigMap and
# Secret for one source profile. Kratix delivers /kratix/output to the dev Destination.
set -euo pipefail

object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"

read_field() {
  local value
  value="$(yq -r "$1" "$object")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "missing required field $1" >&2
    exit 1
  fi
  printf '%s' "$value"
}

source_namespace="$(read_field .spec.source.namespace)"
source_name="$(read_field .spec.source.name)"
source_uid="$(read_field .spec.source.uid)"
database_name="$(read_field .spec.databaseName)"
storage_size="$(read_field .spec.storageSize)"

request_kind="$(read_field .kind)"
request_api_version="$(read_field .apiVersion)"
request_name="$(read_field .metadata.name)"
request_uid="$(read_field .metadata.uid)"
request_namespace="$(read_field .metadata.namespace)"

# Names derive from the source profile UID so a recreated profile never reuses old resources.
id="pg-$(printf '%s' "$source_uid" | sha256sum | cut -c1-12)"
credentials_name="${id}-credentials"
database_user="app"
host="${id}.${target_namespace}.svc.cluster.local"

# The password is kept in a Secret owned by the request in the management cluster, so
# reruns reuse it and deleting the request removes it.
password_b64="$(kubectl get secret "$credentials_name" -n "$request_namespace" \
  --ignore-not-found -o jsonpath='{.data.password}')"
if [[ -z "$password_b64" ]]; then
  kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${credentials_name}
  namespace: ${request_namespace}
  ownerReferences:
    - apiVersion: ${request_api_version}
      kind: ${request_kind}
      name: ${request_name}
      uid: ${request_uid}
stringData:
  password: $(openssl rand -hex 24)
EOF
  password_b64="$(kubectl get secret "$credentials_name" -n "$request_namespace" \
    -o jsonpath='{.data.password}')"
fi
password="$(printf '%s' "$password_b64" | base64 -d)"

labels="{app.kubernetes.io/name: postgres, app.kubernetes.io/instance: ${id}, demo.runtimeconditions.io/source-uid: \"${source_uid}\"}"
annotations="{demo.runtimeconditions.io/source-namespace: \"${source_namespace}\", demo.runtimeconditions.io/source-name: \"${source_name}\"}"

mkdir -p /kratix/output /kratix/metadata
cat > /kratix/output/postgres.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${credentials_name}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
type: Opaque
stringData:
  POSTGRES_USER: ${database_user}
  POSTGRES_PASSWORD: ${password}
  POSTGRES_DB: ${database_name}
  DATABASE_URL: postgres://${database_user}:${password}@${host}:5432/${database_name}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${id}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
data:
  DATABASE_HOST: ${host}
  DATABASE_PORT: "5432"
  DATABASE_NAME: ${database_name}
---
apiVersion: v1
kind: Service
metadata:
  name: ${id}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
spec:
  selector:
    app.kubernetes.io/instance: ${id}
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${id}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
spec:
  serviceName: ${id}
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: ${id}
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Delete
    whenScaled: Retain
  template:
    metadata:
      labels: ${labels}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        fsGroup: 70
      containers:
        - name: postgres
          image: postgres:17-alpine
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            - secretRef:
                name: ${credentials_name}
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \$POSTGRES_USER -d \$POSTGRES_DB"]
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
        labels: ${labels}
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: ${storage_size}
EOF

cat > /kratix/metadata/status.yaml <<EOF
host: ${host}
port: 5432
databaseName: ${database_name}
connectionConfigMap: ${id}
credentialsSecret: ${credentials_name}
EOF
