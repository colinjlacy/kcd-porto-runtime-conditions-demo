#!/usr/bin/env bash
# Kratix configure pipeline: renders a MailHog Deployment and Service and a service-binding Secret
# for one EmailSender request. Outputs are named after the request. Kratix delivers /kratix/output
# to the dev Destination. MailHog accepts any credentials; the generated ones keep the binding
# identical to the production sender.
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

request_kind="$(read_field .kind)"
request_api_version="$(read_field .apiVersion)"
request_name="$(read_field .metadata.name)"
request_uid="$(read_field .metadata.uid)"
request_namespace="$(read_field .metadata.namespace)"
sender="$(read_field .spec.sender)"

name="$request_name"
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

mkdir -p /kratix/output /kratix/metadata
manifests="$(jq -n \
  --arg name "$name" --arg namespace "$target_namespace" \
  --arg requestNamespace "$request_namespace" --arg requestName "$request_name" \
  --arg host "$host" --arg password "$password" --arg sender "$sender" --arg image "$mailhog_image" '
  def meta: {
    name: $name, namespace: $namespace,
    labels: {"app.kubernetes.io/name": "mailhog", "app.kubernetes.io/instance": $name, "app.kubernetes.io/managed-by": "kratix"},
    annotations: {"platform.runtimeconditions.io/request-namespace": $requestNamespace, "platform.runtimeconditions.io/request-name": $requestName}
  };
  [
    {
      apiVersion: "v1", kind: "Secret", metadata: meta, type: "Opaque",
      stringData: {type: "smtp", host: $host, port: "1025", username: $name, password: $password, tlsMode: "disabled", sender: $sender}
    },
    {
      apiVersion: "v1", kind: "Service", metadata: meta,
      spec: {
        selector: {"app.kubernetes.io/instance": $name},
        ports: [{name: "smtp", port: 1025, targetPort: "smtp"}, {name: "http", port: 8025, targetPort: "http"}]
      }
    },
    {
      apiVersion: "apps/v1", kind: "Deployment", metadata: meta,
      spec: {
        replicas: 1, strategy: {type: "Recreate"},
        selector: {matchLabels: {"app.kubernetes.io/instance": $name}},
        template: {
          metadata: {labels: {"app.kubernetes.io/name": "mailhog", "app.kubernetes.io/instance": $name}},
          spec: {
            containers: [{
              name: "mailhog", image: $image,
              ports: [{name: "smtp", containerPort: 1025}, {name: "http", containerPort: 8025}],
              readinessProbe: {tcpSocket: {port: "smtp"}, periodSeconds: 5},
              securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
            }]
          }
        }
      }
    }
  ]')"
for kind in $(jq -r '.[].kind | ascii_downcase' <<<"$manifests"); do
  jq --arg kind "$kind" '.[] | select(.kind | ascii_downcase == $kind)' <<<"$manifests" |
    yq -P > "/kratix/output/${kind}.yaml"
done

cat > /kratix/metadata/status.yaml <<EOF
bindingSecret: ${name}
host: ${host}
port: 1025
inboxService: ${name}:8025
EOF
