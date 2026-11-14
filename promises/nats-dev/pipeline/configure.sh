#!/usr/bin/env bash
# Kratix configure pipeline: renders the connection settings, application credentials and a
# provisioning Job that creates a JetStream stream and durable consumer on the environment's
# NATS broker for one source profile. Kratix delivers /kratix/output to the selected Destination.
set -euo pipefail

object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"
broker_url="${NATS_BROKER_URL:?NATS_BROKER_URL must be set}"
nats_box_image="${NATS_BOX_IMAGE:?NATS_BOX_IMAGE must be set}"

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
stream="$(read_field .spec.stream)"
subject="$(read_field .spec.subject)"
consumer="$(read_field .spec.consumer)"

request_kind="$(read_field .kind)"
request_api_version="$(read_field .apiVersion)"
request_name="$(read_field .metadata.name)"
request_uid="$(read_field .metadata.uid)"
request_namespace="$(read_field .metadata.namespace)"

# Names derive from the source profile UID so a recreated profile never reuses old resources.
id="nats-$(printf '%s' "$source_uid" | sha256sum | cut -c1-12)"
credentials_name="${id}-credentials"
# A Job's pod template cannot change, so a changed declaration gets a new Job.
job_name="${id}-provision-$(printf '%s|%s|%s' "$stream" "$subject" "$consumer" | sha256sum | cut -c1-8)"

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

labels="{app.kubernetes.io/name: nats-access, app.kubernetes.io/instance: ${id}, demo.runtimeconditions.io/source-uid: \"${source_uid}\"}"
annotations="{demo.runtimeconditions.io/source-namespace: \"${source_namespace}\", demo.runtimeconditions.io/source-name: \"${source_name}\"}"

mkdir -p /kratix/output /kratix/metadata
cat > /kratix/output/nats.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${credentials_name}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
type: Opaque
stringData:
  NATS_USERNAME: ${id}
  NATS_PASSWORD: ${password}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${id}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
data:
  NATS_URL: ${broker_url}
  NATS_TLS: "false"
  NATS_STREAM: ${stream}
  NATS_SUBJECT: ${subject}
  NATS_CONSUMER: ${consumer}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
spec:
  backoffLimit: 2
  activeDeadlineSeconds: 900
  template:
    metadata:
      labels: ${labels}
    spec:
      restartPolicy: Never
      containers:
        - name: provision
          image: ${nats_box_image}
          envFrom:
            - configMapRef:
                name: ${id}
          command:
            - sh
            - -c
            - |
              provision() {
                nats --server "\$NATS_URL" stream info "\$NATS_STREAM" >/dev/null 2>&1 ||
                  nats --server "\$NATS_URL" stream add "\$NATS_STREAM" \\
                    --subjects "\$NATS_SUBJECT" --storage file --defaults
                nats --server "\$NATS_URL" consumer info "\$NATS_STREAM" "\$NATS_CONSUMER" >/dev/null 2>&1 ||
                  nats --server "\$NATS_URL" consumer add "\$NATS_STREAM" "\$NATS_CONSUMER" \\
                    --pull --filter "\$NATS_SUBJECT" --ack explicit --deliver all \\
                    --max-deliver 5 --replay instant --defaults
              }
              until provision; do sleep 5; done
EOF

cat > /kratix/metadata/status.yaml <<EOF
url: ${broker_url}
stream: ${stream}
consumer: ${consumer}
connectionConfigMap: ${id}
credentialsSecret: ${credentials_name}
provisioningJob: ${job_name}
EOF
