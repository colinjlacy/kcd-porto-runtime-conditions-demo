#!/usr/bin/env bash
# Kratix configure pipeline: renders a MailHog Deployment and Service, connection settings and
# SMTP credentials for one source profile. Kratix delivers /kratix/output to the dev Destination.
set -euo pipefail

object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"
mailhog_image="${MAILHOG_IMAGE:?MAILHOG_IMAGE must be set}"

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
notification_from="$(read_field .spec.from)"
notification_to="$(read_field .spec.to)"

request_kind="$(read_field .kind)"
request_api_version="$(read_field .apiVersion)"
request_name="$(read_field .metadata.name)"
request_uid="$(read_field .metadata.uid)"
request_namespace="$(read_field .metadata.namespace)"

# Names derive from the source profile UID so a recreated profile never reuses old resources.
id="smtp-$(printf '%s' "$source_uid" | sha256sum | cut -c1-12)"
credentials_name="${id}-credentials"
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

labels="{app.kubernetes.io/name: mailhog, app.kubernetes.io/instance: ${id}, demo.runtimeconditions.io/source-uid: \"${source_uid}\"}"
annotations="{demo.runtimeconditions.io/source-namespace: \"${source_namespace}\", demo.runtimeconditions.io/source-name: \"${source_name}\"}"

mkdir -p /kratix/output /kratix/metadata
cat > /kratix/output/smtp.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${credentials_name}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
type: Opaque
stringData:
  SMTP_USERNAME: ${id}
  SMTP_PASSWORD: ${password}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${id}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
data:
  SMTP_HOST: ${host}
  SMTP_PORT: "1025"
  SMTP_TLS_MODE: disabled
  NOTIFICATION_FROM: ${notification_from}
  NOTIFICATION_TO: ${notification_to}
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
    - name: smtp
      port: 1025
      targetPort: smtp
    - name: http
      port: 8025
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${id}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/instance: ${id}
  template:
    metadata:
      labels: ${labels}
    spec:
      containers:
        - name: mailhog
          image: ${mailhog_image}
          ports:
            - name: smtp
              containerPort: 1025
            - name: http
              containerPort: 8025
          readinessProbe:
            tcpSocket:
              port: smtp
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF

cat > /kratix/metadata/status.yaml <<EOF
host: ${host}
port: 1025
connectionConfigMap: ${id}
credentialsSecret: ${credentials_name}
inboxService: ${id}:8025
EOF
