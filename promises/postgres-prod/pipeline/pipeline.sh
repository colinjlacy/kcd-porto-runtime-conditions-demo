#!/usr/bin/env bash
# Kratix pipeline: "configure" applies one Aurora Serverless PostgreSQL cluster per source
# profile with OpenTofu and renders its connection settings for the production cluster;
# "delete" destroys that cluster.
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
database_name="$(read_field .spec.databaseName)"
min_capacity="$(read_field .spec.minCapacity)"
max_capacity="$(read_field .spec.maxCapacity)"

# Names derive from the source profile UID so a recreated profile never reuses old resources.
id="pg-$(printf '%s' "$source_uid" | sha256sum | cut -c1-12)"
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
  -backend-config="key=postgres-prod/${id}/terraform.tfstate" \
  -backend-config="region=${region}" \
  -backend-config="use_lockfile=true"

tags="$(jq -cn \
  --arg ns "$source_namespace" --arg name "$source_name" --arg uid "$source_uid" \
  '{"demo.runtimeconditions.io/source-namespace": $ns, "demo.runtimeconditions.io/source-name": $name, "demo.runtimeconditions.io/source-uid": $uid}')"

tofu_args=(
  -input=false
  -var "aws_region=${region}"
  -var "name=${id}"
  -var "subnet_ids=$(jq -cn --arg v "$(setting SUBNET_IDS)" '$v | split(",")')"
  -var "security_group_id=$(setting SECURITY_GROUP_ID)"
  -var "database_name=${database_name}"
  -var "min_capacity=${min_capacity}"
  -var "max_capacity=${max_capacity}"
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
port="$(output port)"
username="$(output username)"
password="$(output password)"
database="$(output database_name)"

labels="{app.kubernetes.io/name: postgres, app.kubernetes.io/instance: ${id}, demo.runtimeconditions.io/source-uid: \"${source_uid}\"}"
annotations="{demo.runtimeconditions.io/source-namespace: \"${source_namespace}\", demo.runtimeconditions.io/source-name: \"${source_name}\"}"

mkdir -p /kratix/output /kratix/metadata
# Aurora's certificate authority is not in Node's trust store, so the URL asks for an
# encrypted but unverified connection.
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
  DATABASE_URL: postgres://${username}:${password}@${host}:${port}/${database}?sslmode=no-verify
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
  DATABASE_PORT: "${port}"
  DATABASE_NAME: ${database}
EOF

cat > /kratix/metadata/status.yaml <<EOF
host: ${host}
port: ${port}
databaseName: ${database}
connectionConfigMap: ${id}
credentialsSecret: ${credentials_name}
EOF
