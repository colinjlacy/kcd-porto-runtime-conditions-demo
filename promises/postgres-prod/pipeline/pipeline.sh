#!/usr/bin/env bash
# Kratix pipeline: "configure" creates one database and one login for a request on the shared
# production Aurora cluster and publishes the connection details as a service-binding Secret
# named after the request; "delete" drops that database and login. The cluster itself is owned
# by the platform.
set -euo pipefail

mode="${1:?usage: pipeline.sh configure|delete}"
object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"
admin_secret="${POSTGRES_ADMIN_SECRET:-shared-postgres}"
admin_namespace="${POSTGRES_ADMIN_NAMESPACE:?POSTGRES_ADMIN_NAMESPACE must be set}"

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
# The database and login share one name, derived from the request UID so a recreated request
# never reuses an old database. Hex digits only, so it is safe in SQL; PostgreSQL reserves the
# pg_ prefix for roles, so the name cannot start with it.
database="db_$(printf '%s' "$request_uid" | sha256sum | cut -c1-12)"

admin="$(kubectl get secret "$admin_secret" -n "$admin_namespace" -o json)"
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

if [[ "$mode" == "delete" ]]; then
  psql_admin -c "DROP DATABASE IF EXISTS ${database} WITH (FORCE)" -c "DROP ROLE IF EXISTS ${database}"
  exit 0
fi

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

if [[ -z "$(psql_admin -c "SELECT 1 FROM pg_roles WHERE rolname = '${database}'")" ]]; then
  psql_admin -c "CREATE ROLE ${database} LOGIN PASSWORD '${password}'"
fi
# The admin must be able to act as the owner to create the database for it.
psql_admin -c "GRANT ${database} TO ${admin_username}"
if [[ -z "$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = '${database}'")" ]]; then
  psql_admin -c "CREATE DATABASE ${database} OWNER ${database}"
fi
# Other requests' logins must not be able to connect to this database.
psql_admin -c "REVOKE ALL ON DATABASE ${database} FROM PUBLIC"

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
  port: "${port}"
  database: ${database}
  username: ${database}
  password: ${password}
  uri: postgres://${database}:${password}@${host}:${port}/${database}?sslmode=no-verify
EOF

cat > /kratix/metadata/status.yaml <<EOF
bindingSecret: ${name}
host: ${host}
port: ${port}
database: ${database}
EOF
