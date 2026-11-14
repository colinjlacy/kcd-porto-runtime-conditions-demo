#!/usr/bin/env bash
# Kratix configure pipeline: runs one PostgreSQL instance in the dev cluster for a request and
# publishes its connection details as a service-binding Secret named after the request.
# Kratix delivers /kratix/output to the selected Destination.
set -euo pipefail

object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"
postgres_image="${POSTGRES_IMAGE:?POSTGRES_IMAGE must be set}"
storage_size="${STORAGE_SIZE:?STORAGE_SIZE must be set}"

read_field() {
  local value
  value="$(yq -r "$1" "$object")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "missing required field $1" >&2
    exit 1
  fi
  printf '%s' "$value"
}

request_kind="$(read_field .kind)"
request_api_version="$(read_field .apiVersion)"
request_name="$(read_field .metadata.name)"
request_uid="$(read_field .metadata.uid)"
request_namespace="$(read_field .metadata.namespace)"

# Every output is named after the request, so consumers can reference it without any lookup.
name="$request_name"
database=app
username=app
host="${name}.${target_namespace}.svc.cluster.local"

# The password is kept in a Secret owned by the request in the management cluster, so
# reruns reuse it and deleting the request removes it.
password_secret="${name}-password"
password_b64="$(kubectl get secret "$password_secret" -n "$request_namespace" \
  --ignore-not-found -o jsonpath='{.data.password}')"
if [[ -z "$password_b64" ]]; then
  kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${password_secret}
  namespace: ${request_namespace}
  ownerReferences:
    - apiVersion: ${request_api_version}
      kind: ${request_kind}
      name: ${request_name}
      uid: ${request_uid}
stringData:
  password: $(openssl rand -hex 24)
EOF
  password_b64="$(kubectl get secret "$password_secret" -n "$request_namespace" \
    -o jsonpath='{.data.password}')"
fi
password="$(printf '%s' "$password_b64" | base64 -d)"

labels="{app.kubernetes.io/name: postgresql, app.kubernetes.io/instance: ${name}, app.kubernetes.io/managed-by: kratix}"
annotations="{platform.runtimeconditions.io/request-namespace: \"${request_namespace}\", platform.runtimeconditions.io/request-name: \"${request_name}\"}"

mkdir -p /kratix/output /kratix/metadata
cat > /kratix/output/postgres.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
type: Opaque
stringData:
  type: postgresql
  host: ${host}
  port: "5432"
  database: ${database}
  username: ${username}
  password: ${password}
  uri: postgres://${username}:${password}@${host}:5432/${database}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
spec:
  selector:
    app.kubernetes.io/instance: ${name}
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${name}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
spec:
  serviceName: ${name}
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: ${name}
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
          image: ${postgres_image}
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
            - name: POSTGRES_USER
              valueFrom: {secretKeyRef: {name: ${name}, key: username}}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: ${name}, key: password}}
            - name: POSTGRES_DB
              valueFrom: {secretKeyRef: {name: ${name}, key: database}}
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
bindingSecret: ${name}
host: ${host}
port: 5432
database: ${database}
EOF
