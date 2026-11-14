#!/usr/bin/env bash
# Kratix pipeline: "configure" issues SMTP credentials for one EmailSender request with OpenTofu, an
# IAM user allowed to send only as the requested, platform-verified sender identity, then publishes
# a service-binding Secret to the production cluster; "delete" destroys the user.
set -euo pipefail

mode="${1:?usage: pipeline.sh configure|delete}"
object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"
config_map="${AWS_CONFIG_MAP:-promise-aws-config}"

read_field() {
  local value
  value="$(yq -r "$1" "$object")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "missing required field $1" >&2
    exit 1
  fi
  printf '%s' "$value"
}

request_namespace="$(read_field .metadata.namespace)"
request_name="$(read_field .metadata.name)"
request_uid="$(read_field .metadata.uid)"
sender="$(read_field .spec.sender)"

# Names derive from the request UID so a recreated request never reuses old resources.
hash="$(printf '%s' "$request_uid" | sha256sum | cut -c1-12)"
id="smtp-${hash}"

settings="$(kubectl get configmap "$config_map" -n "$KRATIX_OBJECT_NAMESPACE" -o json)"
setting() {
  jq -er --arg key "$1" '.data[$key]' <<<"$settings"
}
region="$(setting AWS_REGION)"
state_bucket="$(setting STATE_BUCKET)"

work="$(mktemp -d)"
cp -R /opt/tofu/. "$work"
cd "$work"
export TF_IN_AUTOMATION=1 AWS_REGION="$region"

tofu init -input=false \
  -backend-config="bucket=${state_bucket}" \
  -backend-config="key=smtp-prod/${id}/terraform.tfstate" \
  -backend-config="region=${region}" \
  -backend-config="use_lockfile=true"

tags="$(jq -cn \
  --arg ns "$request_namespace" --arg name "$request_name" --arg uid "$request_uid" \
  '{"platform.runtimeconditions.io/request-namespace": $ns, "platform.runtimeconditions.io/request-name": $name, "platform.runtimeconditions.io/request-uid": $uid}')"

tofu_args=(
  -input=false
  -var "aws_region=${region}"
  -var "name=${id}"
  -var "from_address=${sender}"
  -var "tags=${tags}"
)

if [[ "$mode" == "delete" ]]; then
  tofu destroy -auto-approve "${tofu_args[@]}"
  exit 0
fi

tofu apply -auto-approve "${tofu_args[@]}"

outputs="$(tofu output -json)"
output() {
  jq -er --arg key "$1" '.[$key].value | tostring' <<<"$outputs"
}
host="$(output host)"
username="$(output username)"
password="$(output password)"
sender_verified="$(output sender_verified)"
port=587

mkdir -p /kratix/output /kratix/metadata
jq -n \
  --arg name "$request_name" --arg namespace "$target_namespace" \
  --arg requestNamespace "$request_namespace" --arg requestName "$request_name" \
  --arg host "$host" --arg port "$port" --arg username "$username" \
  --arg password "$password" --arg sender "$sender" '
  {
    apiVersion: "v1", kind: "Secret",
    metadata: {
      name: $name, namespace: $namespace,
      labels: {"app.kubernetes.io/name": "ses-smtp", "app.kubernetes.io/instance": $name, "app.kubernetes.io/managed-by": "kratix"},
      annotations: {"platform.runtimeconditions.io/request-namespace": $requestNamespace, "platform.runtimeconditions.io/request-name": $requestName}
    },
    type: "Opaque",
    stringData: {type: "smtp", host: $host, port: $port, username: $username, password: $password, tlsMode: "starttls", sender: $sender}
  }' | yq -P > /kratix/output/binding.yaml

cat > /kratix/metadata/status.yaml <<EOF
bindingSecret: ${request_name}
host: ${host}
port: ${port}
sender: ${sender}
senderVerification: ${sender_verified}
EOF
