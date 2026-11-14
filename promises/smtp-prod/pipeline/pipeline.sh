#!/usr/bin/env bash
# Kratix pipeline: "configure" registers the SES sender and recipient identities and SMTP
# credentials for one source profile with OpenTofu, then renders the connection settings for the
# production cluster; "delete" destroys them.
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

source_namespace="$(read_field .spec.source.namespace)"
source_name="$(read_field .spec.source.name)"
source_uid="$(read_field .spec.source.uid)"
notification_from="$(read_field .spec.from)"
notification_to="$(read_field .spec.to)"

# Names derive from the source profile UID so a recreated profile never reuses old resources.
hash="$(printf '%s' "$source_uid" | sha256sum | cut -c1-12)"
id="smtp-${hash}"
credentials_name="${id}-credentials"

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
  --arg ns "$source_namespace" --arg name "$source_name" --arg uid "$source_uid" \
  '{"demo.runtimeconditions.io/source-namespace": $ns, "demo.runtimeconditions.io/source-name": $name, "demo.runtimeconditions.io/source-uid": $uid}')"

tofu_args=(
  -input=false
  -var "aws_region=${region}"
  -var "name=${id}"
  -var "from_address=${notification_from}"
  -var "to_address=${notification_to}"
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
recipient_verified="$(output recipient_verified)"

labels="{app.kubernetes.io/name: ses-smtp, app.kubernetes.io/instance: ${id}, demo.runtimeconditions.io/source-uid: \"${source_uid}\"}"
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
  SMTP_USERNAME: ${username}
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
  SMTP_PORT: "587"
  SMTP_TLS_MODE: starttls
  NOTIFICATION_FROM: ${notification_from}
  NOTIFICATION_TO: ${notification_to}
EOF

cat > /kratix/metadata/status.yaml <<EOF
host: ${host}
port: 587
connectionConfigMap: ${id}
credentialsSecret: ${credentials_name}
senderVerification: ${sender_verified}
recipientVerification: ${recipient_verified}
EOF
