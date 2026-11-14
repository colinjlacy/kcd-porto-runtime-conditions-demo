#!/usr/bin/env bash
# Kratix configure pipeline: renders the application Deployment for one source profile in one
# environment. The Deployment reads its settings from the dependency ConfigMaps and Secrets that
# the integration Promises name after the same source profile UID, and an init container per
# dependency keeps the application from starting until that dependency is usable. A request
# without an image renders nothing, so the profile gets its dependencies only.
set -euo pipefail

object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"
postgres_image="${POSTGRES_CLIENT_IMAGE:?POSTGRES_CLIENT_IMAGE must be set}"
curl_image="${CURL_IMAGE:?CURL_IMAGE must be set}"
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
environment="$(read_field .spec.environment)"
replicas="$(read_field .spec.replicas)"
image="$(yq -r '.spec.image // ""' "$object")"
mapfile -t dependencies < <(yq -r '(.spec.dependencies // [])[]' "$object")

mkdir -p /kratix/output /kratix/metadata
cat > /kratix/metadata/destination-selectors.yaml <<EOF
- matchLabels:
    environment: ${environment}
EOF

hash="$(printf '%s' "$source_uid" | sha256sum | cut -c1-12)"
id="app-${hash}"

cat > /kratix/metadata/status.yaml <<EOF
environment: ${environment}
image: "${image}"
deployment: ${id}
EOF

if [[ -z "$image" ]]; then
  exit 0
fi

env_from=""
init_containers=""
for dependency in "${dependencies[@]}"; do
  case "$dependency" in
    postgres) name="pg-${hash}" ;;
    smtp) name="smtp-${hash}" ;;
    nats) name="nats-${hash}" ;;
    *)
      echo "unsupported dependency ${dependency}" >&2
      exit 1
      ;;
  esac

  if [[ "$dependency" != "postgres" ]]; then
    env_from+="            - configMapRef:
                name: ${name}
"
  fi
  env_from+="            - secretRef:
                name: ${name}-credentials
"
  # The checks use the same credentials the application will use, from inside the workload cluster.
  case "$dependency" in
    postgres)
      init_containers+="        - name: wait-for-postgres
          image: ${postgres_image}
          envFrom:
            - secretRef:
                name: ${name}-credentials
          command:
            - sh
            - -c
            - |
              url=\$(printf '%s' \"\$DATABASE_URL\" | sed 's/sslmode=no-verify/sslmode=require/')
              until psql \"\$url\" -v ON_ERROR_STOP=1 -tAc 'select 1' >/dev/null; do sleep 5; done
"
      ;;
    smtp)
      init_containers+="        - name: wait-for-smtp
          image: ${curl_image}
          envFrom:
            - configMapRef:
                name: ${name}
            - secretRef:
                name: ${name}-credentials
          command:
            - sh
            - -c
            - |
              scheme=smtp
              flags=
              case \"\$SMTP_TLS_MODE\" in
                starttls) flags=--ssl-reqd ;;
                implicit) scheme=smtps ;;
              esac
              until curl --silent --show-error --max-time 20 \$flags \\
                --user \"\$SMTP_USERNAME:\$SMTP_PASSWORD\" -X NOOP \\
                \"\$scheme://\$SMTP_HOST:\$SMTP_PORT\"; do sleep 5; done
"
      ;;
    nats)
      init_containers+="        - name: wait-for-nats
          image: ${nats_box_image}
          envFrom:
            - configMapRef:
                name: ${name}
            - secretRef:
                name: ${name}-credentials
          command:
            - sh
            - -c
            - |
              until nats --server \"\$NATS_URL\" --user \"\$NATS_USERNAME\" --password \"\$NATS_PASSWORD\" \\
                consumer info \"\$NATS_STREAM\" \"\$NATS_CONSUMER\" >/dev/null; do sleep 5; done
"
      ;;
  esac
done

labels="{app.kubernetes.io/name: shipment-notifier, app.kubernetes.io/instance: ${id}, demo.runtimeconditions.io/source-uid: \"${source_uid}\"}"
annotations="{demo.runtimeconditions.io/source-namespace: \"${source_namespace}\", demo.runtimeconditions.io/source-name: \"${source_name}\"}"

cat > /kratix/output/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${id}
  namespace: ${target_namespace}
  labels: ${labels}
  annotations: ${annotations}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app.kubernetes.io/instance: ${id}
  template:
    metadata:
      labels: ${labels}
    spec:
      initContainers:
${init_containers}      containers:
        - name: app
          image: ${image}
          envFrom:
${env_from}          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF
