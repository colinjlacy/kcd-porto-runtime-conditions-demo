#!/usr/bin/env bash
# Kratix configure pipeline: renders a Deployment from a Workload request and selects the
# Destinations to deliver it to. The Deployment, its init-container checks and its environment come
# from the request spec; nothing about the application is known here.
set -euo pipefail

object=/kratix/input/object.yaml
target_namespace="${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"

request_name="$(yq -r '.metadata.name' "$object")"
request_namespace="$(yq -r '.metadata.namespace' "$object")"
spec="$(yq -o=json -I=0 '.spec' "$object")"

mkdir -p /kratix/output /kratix/metadata

jq '[{matchLabels: .destinationLabels}]' <<<"$spec" | yq -P > /kratix/metadata/destination-selectors.yaml

jq -n \
  --arg name "$request_name" --arg namespace "$target_namespace" \
  --arg requestNamespace "$request_namespace" --argjson spec "$spec" '
  {
    apiVersion: "apps/v1", kind: "Deployment",
    metadata: {
      name: $name, namespace: $namespace,
      labels: {"app.kubernetes.io/name": $name, "app.kubernetes.io/instance": $name, "app.kubernetes.io/managed-by": "kratix"},
      annotations: {"platform.runtimeconditions.io/request-namespace": $requestNamespace, "platform.runtimeconditions.io/request-name": $name}
    },
    spec: {
      replicas: $spec.replicas,
      selector: {matchLabels: {"app.kubernetes.io/instance": $name}},
      template: {
        metadata: {labels: {"app.kubernetes.io/name": $name, "app.kubernetes.io/instance": $name}},
        spec: {
          initContainers: (($spec.checks // []) | map({name, image, command, env: (.env // [])})),
          containers: [{
            name: "app", image: $spec.image, env: ($spec.env // []),
            securityContext: {
              runAsNonRoot: true, runAsUser: $spec.runAsUser,
              allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}
            }
          }]
        }
      }
    }
  }' | yq -P > /kratix/output/deployment.yaml

cat > /kratix/metadata/status.yaml <<EOF
deployment: ${request_name}
image: $(jq -r '.image' <<<"$spec")
EOF
