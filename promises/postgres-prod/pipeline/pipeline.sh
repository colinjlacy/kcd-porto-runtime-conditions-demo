#!/usr/bin/env bash
# Kratix pipeline: "configure" creates one database and one login for a source profile on the
# shared production Aurora cluster and renders its connection settings for the production
# cluster; "delete" drops that database and login. The cluster itself is owned by the platform.
set -euo pipefail

mode="${1:?usage: pipeline.sh configure|delete}"
object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"
admin_secret="${POSTGRES_ADMIN_SECRET:-shared-postgres}"

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

request_kind="$(read_field .kind)"
request_api_version="$(read_field .apiVersion)"
request_name="$(read_field .metadata.name)"
request_uid="$(read_field .metadata.uid)"
request_namespace="$(read_field .metadata.namespace)"

# Names derive from the source profile UID so a recreated profile never reuses old resources.
hash="$(printf '%s' "$source_uid" | sha256sum | cut -c1-12)"
id="pg-${hash}"
credentials_name="${id}-credentials"
# The database and login share one name: hex digits only, so they are safe in SQL. PostgreSQL
# reserves the pg_ prefix for roles, so the name cannot start with it.
database="db_${hash}"

admin="$(kubectl get secret "$admin_secret" -n "$request_namespace" -o json)"
admin_field() {
  jq -er --arg key "$1" '.data[$key] | @base64d' <<<"$admin"
}
host="$(admin_field host)"
port="$(admin_field port)"
admin_username="$(admin_field username)"
PGPASSWORD="$(admin_field password)"
# Aurora only offers its own certificate authority, so the connection is encrypted but unverified.
export PGPASSWORD PGSSLMODE=require PGCONNECT_TIMEOUT=30

psql_admin() {
  psql -h "$host" -p "$port" -U "$admin_username" -d postgres -v ON_ERROR_STOP=1 -tAq "$@"
}

# A paused cluster resumes on the first connection, which can take a minute.
for attempt in $(seq 1 10); do
  if psql_admin -c 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 10 ]]; then
    echo "Aurora at ${host} did not accept connections" >&2
    exit 1
  fi
  sleep 15
done

if [[ "$mode" == "delete" ]]; then
  psql_admin -c "DROP DATABASE IF EXISTS ${database} WITH (FORCE)" -c "DROP ROLE IF EXISTS ${database}"
  exit 0
fi

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

if [[ -z "$(psql_admin -c "SELECT 1 FROM pg_roles WHERE rolname = '${database}'")" ]]; then
  psql_admin -c "CREATE ROLE ${database} LOGIN PASSWORD '${password}'"
fi
# The admin must be able to act as the owner to create the database for it.
psql_admin -c "GRANT ${database} TO ${admin_username}"
if [[ -z "$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = '${database}'")" ]]; then
  psql_admin -c "CREATE DATABASE ${database} OWNER ${database}"
fi
# Other profiles' logins must not be able to connect to this database.
psql_admin -c "REVOKE ALL ON DATABASE ${database} FROM PUBLIC"

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
  DATABASE_URL: postgres://${database}:${password}@${host}:${port}/${database}?sslmode=no-verify
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
