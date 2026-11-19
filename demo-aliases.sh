# Source this file: source ./demo-aliases.sh
if [ -n "${BASH_VERSION:-}" ]; then
  RC_DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
elif [ -n "${ZSH_VERSION:-}" ]; then
  RC_DEMO_ROOT="$(cd "$(dirname "${(%):-%x}")" && pwd -P)"
else
  printf 'Use Bash or Zsh to source demo-aliases.sh.\n' >&2
  return 1
fi
export RC_DEMO_ROOT
export RC_DEMO_KUBECONFIG="${RC_DEMO_KUBECONFIG:-$RC_DEMO_ROOT/infra/platform/.terraform/headlamp.kubeconfig}"
export KUBECONFIG="$RC_DEMO_KUBECONFIG"
export RC_DEMO_PROFILE_NAMESPACE="${RC_DEMO_PROFILE_NAMESPACE:-runtime-conditions}"
export RC_DEMO_PROFILE_NAME="${RC_DEMO_PROFILE_NAME:-shipment-notifier}"

alias km='kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" --context rc-demo-management'
alias kd='kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" --context rc-demo-dev'
alias kp='kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" --context rc-demo-production'
alias kcm='kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" config use-context rc-demo-management'
alias kcd='kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" config use-context rc-demo-dev'
alias kcp='kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" config use-context rc-demo-production'
alias demo-down='bash "$RC_DEMO_ROOT/scripts/teardown-application.sh" --kubeconfig "$RC_DEMO_KUBECONFIG" --management-context rc-demo-management --dev-context rc-demo-dev --production-context rc-demo-production'
unalias nats-dev-forward nats-prod-forward 2>/dev/null || true
nats-dev-forward() { kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" --context rc-demo-dev -n nats port-forward service/nats 4222:4222 "$@"; }
nats-prod-forward() { kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" --context rc-demo-production -n nats port-forward service/nats 5222:4222 "$@"; }

demo-status() (
  set -euo pipefail
  local rc_context
  for rc_context in rc-demo-dev rc-demo-production; do
    printf '\n%s\n' "$rc_context"
    kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" --context "$rc_context" -n application-support \
      get deploy,sts,svc,job,pvc,pod,secret
  done
)

mailhog-forward() (
  set -euo pipefail
  local rc_uid rc_hash
  rc_uid="$(kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" --context rc-demo-management \
    -n "$RC_DEMO_PROFILE_NAMESPACE" get rcprofile "$RC_DEMO_PROFILE_NAME" -o jsonpath='{.metadata.uid}')"
  test -n "$rc_uid"
  rc_hash="$(printf '%s' "$rc_uid" | shasum -a 256 | cut -c1-12)"
  kubectl --kubeconfig "$RC_DEMO_KUBECONFIG" --context rc-demo-dev -n application-support \
    port-forward "service/dev-email-$rc_hash" 8025:8025
)

demo-databases() (
  set -euo pipefail
  local rc_access rc_region rc_cluster rc_secret
  rc_access="$(tofu -chdir="$RC_DEMO_ROOT/infra/platform" output -json shared_postgres)"
  rc_region="$(jq -er .region <<<"$rc_access")"
  rc_cluster="$(jq -er .cluster_arn <<<"$rc_access")"
  rc_secret="$(jq -er .admin_secret_arn <<<"$rc_access")"
  aws rds-data execute-statement --region "$rc_region" --resource-arn "$rc_cluster" \
    --secret-arn "$rc_secret" --database postgres \
    --sql "select datname::text as datname from pg_database where left(datname::text, 3) = 'db_' order by datname" \
    --format-records-as JSON --query formattedRecords --output text
)

# Rebuild only the dedicated local kubeconfig; do not modify ~/.kube/config.
demo-kubeconfig() (
  set -euo pipefail
  umask 077
  local rc_clusters rc_account rc_actual rc_aws_path rc_profile rc_temp rc_yaml rc_environment rc_name rc_region
  rc_clusters="$(tofu -chdir="$RC_DEMO_ROOT/infra/foundation" output -json clusters)"
  rc_account="$(jq -er '.management.arn | split(":")[4]' <<<"$rc_clusters")"
  rc_aws_path="$(command -v aws)"
  rc_profile="${1:-${AWS_PROFILE:-}}"
  local -a rc_aws=("$rc_aws_path")
  if [ -n "$rc_profile" ]; then rc_aws+=(--profile "$rc_profile"); fi
  rc_actual="$("${rc_aws[@]}" sts get-caller-identity --query Account --output text)"
  if [ "$rc_actual" != "$rc_account" ]; then
    printf 'Selected AWS credentials do not match the foundation account.\n' >&2
    exit 1
  fi
  mkdir -p "$(dirname "$RC_DEMO_KUBECONFIG")"
  rc_temp="$(mktemp "${RC_DEMO_KUBECONFIG}.XXXXXX")"
  rc_yaml="${rc_temp}.yaml"
  trap 'rm -f "$rc_temp" "$rc_yaml"' EXIT
  for rc_environment in management dev production; do
    rc_name="$(jq -er --arg e "$rc_environment" '.[$e].name' <<<"$rc_clusters")"
    rc_region="$(jq -er --arg e "$rc_environment" '.[$e].arn | split(":")[3]' <<<"$rc_clusters")"
    "${rc_aws[@]}" eks update-kubeconfig --region "$rc_region" --name "$rc_name" \
      --alias "rc-demo-$rc_environment" --user-alias "rc-demo-$rc_environment" --kubeconfig "$rc_temp"
  done
  kubectl --kubeconfig "$rc_temp" config use-context rc-demo-management >/dev/null
  kubectl --kubeconfig "$rc_temp" config view --raw -o json |
    jq --arg command "$rc_aws_path" '(.users[].user.exec.command) = $command' |
    kubectl --kubeconfig /dev/stdin config view --raw -o yaml > "$rc_yaml"
  chmod 600 "$rc_yaml"
  mv "$rc_yaml" "$RC_DEMO_KUBECONFIG"
  rm -f "$rc_temp"
  trap - EXIT
  printf 'Headlamp kubeconfig: %s\n' "$RC_DEMO_KUBECONFIG"
)

# Uses the existing local publisher; event IDs and timestamps are generated automatically.
send-dev() (
  env -u NATS_USERNAME -u NATS_PASSWORD NATS_URL=nats://127.0.0.1:4222 NATS_TLS=false \
    NATS_STREAM=SHIPMENTS NATS_SUBJECT=orders.shipped NATS_CONSUMER=shipment-notifier \
    npm --prefix "$RC_DEMO_ROOT/app" run publish:sample -- "$@"
)
send-prod() (
  env -u NATS_USERNAME -u NATS_PASSWORD NATS_URL=nats://127.0.0.1:5222 NATS_TLS=false \
    NATS_STREAM=SHIPMENTS NATS_SUBJECT=orders.shipped NATS_CONSUMER=shipment-notifier \
    npm --prefix "$RC_DEMO_ROOT/app" run publish:sample -- "$@"
)
