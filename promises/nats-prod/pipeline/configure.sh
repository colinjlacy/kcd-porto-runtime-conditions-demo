#!/usr/bin/env bash
# Kratix configure pipeline: publishes a service-binding Secret for the environment's NATS broker
# and renders a Job that creates a JetStream stream and durable consumers on it. Outputs are named
# after the request. Kratix delivers /kratix/output to the selected Destination.
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

request_kind="$(read_field .kind)"
request_api_version="$(read_field .apiVersion)"
request_name="$(read_field .metadata.name)"
request_uid="$(read_field .metadata.uid)"
request_namespace="$(read_field .metadata.namespace)"

name="$request_name"
spec="$(yq -o=json -I=0 '.spec' "$object")"
stream="$(jq -er '.stream' <<<"$spec")"
subjects="$(jq -er '.subjects | join(",")' <<<"$spec")"
# One "name|filter" line per consumer; an empty filter consumes every subject of the stream.
consumers="$(jq -r '(.consumers // []) | map(.name + "|" + (.filterSubject // "")) | join("\n")' <<<"$spec")"
# A Job's pod template cannot change, so a changed spec gets a new Job.
job_name="${name}-provision-$(printf '%s' "$spec" | sha256sum | cut -c1-8)"

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

provision_script='provision() {
  nats --server "$NATS_URL" stream info "$STREAM" >/dev/null 2>&1 ||
    nats --server "$NATS_URL" stream add "$STREAM" --subjects "$SUBJECTS" --storage file --defaults
  printf "%s\n" "$CONSUMERS" > /tmp/consumers
  while IFS="|" read -r consumer filter; do
    [ -n "$consumer" ] || continue
    nats --server "$NATS_URL" consumer info "$STREAM" "$consumer" >/dev/null 2>&1 ||
      nats --server "$NATS_URL" consumer add "$STREAM" "$consumer" --pull ${filter:+--filter "$filter"} \
        --ack explicit --deliver all --max-deliver 5 --replay instant --defaults
  done < /tmp/consumers
}
until provision; do sleep 5; done'

mkdir -p /kratix/output /kratix/metadata
jq -n \
  --arg name "$name" --arg namespace "$target_namespace" \
  --arg requestNamespace "$request_namespace" --arg requestName "$request_name" \
  --arg url "$broker_url" --arg password "$password" --arg stream "$stream" '
  {
    apiVersion: "v1", kind: "Secret",
    metadata: {
      name: $name, namespace: $namespace,
      labels: {"app.kubernetes.io/name": "nats-access", "app.kubernetes.io/instance": $name, "app.kubernetes.io/managed-by": "kratix"},
      annotations: {"platform.runtimeconditions.io/request-namespace": $requestNamespace, "platform.runtimeconditions.io/request-name": $requestName}
    },
    type: "Opaque",
    stringData: {type: "nats", url: $url, username: $name, password: $password, tls: "false", stream: $stream}
  }' | yq -P > /kratix/output/binding.yaml

jq -n \
  --arg name "$job_name" --arg instance "$name" --arg namespace "$target_namespace" \
  --arg requestNamespace "$request_namespace" --arg requestName "$request_name" \
  --arg image "$nats_box_image" --arg url "$broker_url" --arg stream "$stream" \
  --arg subjects "$subjects" --arg consumers "$consumers" --arg script "$provision_script" '
  {
    apiVersion: "batch/v1", kind: "Job",
    metadata: {
      name: $name, namespace: $namespace,
      labels: {"app.kubernetes.io/name": "nats-access", "app.kubernetes.io/instance": $instance, "app.kubernetes.io/managed-by": "kratix"},
      annotations: {"platform.runtimeconditions.io/request-namespace": $requestNamespace, "platform.runtimeconditions.io/request-name": $requestName}
    },
    spec: {
      backoffLimit: 2, activeDeadlineSeconds: 900,
      template: {
        metadata: {labels: {"app.kubernetes.io/name": "nats-access", "app.kubernetes.io/instance": $instance}},
        spec: {
          restartPolicy: "Never",
          containers: [{
            name: "provision", image: $image,
            env: [
              {name: "NATS_URL", value: $url}, {name: "STREAM", value: $stream},
              {name: "SUBJECTS", value: $subjects}, {name: "CONSUMERS", value: $consumers}
            ],
            command: ["sh", "-c", $script]
          }]
        }
      }
    }
  }' | yq -P > /kratix/output/provision-job.yaml

cat > /kratix/metadata/status.yaml <<EOF
bindingSecret: ${name}
url: ${broker_url}
stream: ${stream}
provisioningJob: ${job_name}
EOF
