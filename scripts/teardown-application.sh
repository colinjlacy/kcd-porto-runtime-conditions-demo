#!/usr/bin/env bash
# Remove one profile's Promise-created resources; retain the shared platform and kubeconfig.
set -euo pipefail
export LC_ALL=C
umask 077
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${RC_DEMO_PROFILE_NAME:-${PROFILE_NAME:-shipment-notifier}}"; namespace="${RC_DEMO_PROFILE_NAMESPACE:-${PROFILE_NAMESPACE:-runtime-conditions}}"
mgmt="${MGMT_CONTEXT:-rc-demo-management}"; dev="${DEV_CONTEXT:-rc-demo-dev}"; prod="${PROD_CONTEXT:-rc-demo-production}"
kubeconfig=; timeout=1200
if [[ -z ${KUBECONFIG:-} && -f "$root/infra/platform/.terraform/headlamp.kubeconfig" ]]; then kubeconfig="$root/infra/platform/.terraform/headlamp.kubeconfig"; fi
usage() {
  cat <<'HELP'
Usage: scripts/teardown-application.sh [--profile NAME] [--namespace NAME]
       [--kubeconfig FILE] [--management-context NAME] [--dev-context NAME]
       [--production-context NAME] [--timeout SECONDS]
Defaults: shipment-notifier in runtime-conditions; rc-demo-* contexts; 1200 seconds.
Reads KUBECONFIG, or infra/platform/.terraform/headlamp.kubeconfig when present.
Deletes the selected RCProfile to stop recreation, its Kratix requests, delivered
application resources, and attributable NATS streams. Production delete workflows
remove that profile's database/login and SMTP credentials. EKS, platform services,
shared Aurora, brokers, state buckets, and kubeconfig are retained.
Stop concurrent publishing before running. A shared or unverifiable NATS
stream causes refusal; a stream that predates the request is removed. Resolve the conflict and rerun to resume the saved inventory.
HELP
}
die() { printf 'Teardown stopped: %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --profile|--namespace|--kubeconfig|--management-context|--dev-context|--production-context|--timeout)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in
        --profile) profile=$2 ;; --namespace) namespace=$2 ;; --kubeconfig) kubeconfig=$2 ;;
        --management-context) mgmt=$2 ;; --dev-context) dev=$2 ;; --production-context) prod=$2 ;; --timeout) timeout=$2 ;;
      esac; shift 2 ;;
    *) die "Unknown argument $1; use --help" ;;
  esac
done
for tool in kubectl jq shasum; do command -v "$tool" >/dev/null || die "$tool is required"; done
[[ $namespace =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && $profile =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die 'Invalid profile name or namespace'
[[ $timeout =~ ^[1-9][0-9]*$ && ${#timeout} -le 5 ]] && ((timeout <= 86400)) || die 'Timeout must be 1–86400 seconds'
[[ -n $mgmt && -n $dev && -n $prod && $mgmt != "$dev" && $mgmt != "$prod" && $dev != "$prod" ]] || die 'Supply three different contexts'
k() {
  local context=$1; shift
  [[ -n $context ]] || die 'A Kubernetes context is required'
  if [[ -n $kubeconfig ]]; then kubectl --kubeconfig "$kubeconfig" --context "$context" --request-timeout=60s "$@"
  else kubectl --context "$context" --request-timeout=60s "$@"; fi
}
context_for() { case "$1" in dev) printf '%s' "$dev" ;; production) printf '%s' "$prod" ;; *) die "Invalid environment $1" ;; esac; }
identity() {
  local server uid
  server=$(k "$1" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  uid=$(k "$1" get namespace kube-system -o jsonpath='{.metadata.uid}')
  [[ -n $server && -n $uid ]] || die "Cannot identify cluster $1"
  printf '%s/%s' "$server" "$uid"
}
m_id=$(identity "$mgmt"); d_id=$(identity "$dev"); p_id=$(identity "$prod")
[[ $m_id != "$d_id" && $m_id != "$p_id" && $d_id != "$p_id" ]] || die 'Contexts must target distinct clusters'
clusters=$(jq -cn --arg m "$m_id" --arg d "$d_id" --arg p "$p_id" '{management:$m,dev:$d,production:$p}')
key=$(printf '%s' "$clusters/$namespace/$profile" | shasum -a 256 | cut -c1-24)
state_dir="$root/infra/platform/.terraform/application-teardown"; mkdir -p "$state_dir"
record="$state_dir/$key.json"; lock="$record.lock"
mkdir "$lock" 2>/dev/null || die "Another teardown may be active. If it stopped, remove $lock and rerun."
clients=; pod="rc-teardown-$$-$RANDOM"
cleanup() {
  for environment in $clients; do k "$(context_for "$environment")" -n nats delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true; done
  rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
save() {
  local value=$1
  jq -e 'type=="object" and (.uid|type=="string") and (.requests|type=="array")' <<<"$value" >/dev/null || die 'Invalid inventory update; previous record was retained'
  printf '%s\n' "$value" > "$record.tmp.$$"; mv "$record.tmp.$$" "$record"
}
get_profile() { k "$mgmt" -n "$namespace" get runtimeconditionsprofiles.runtimeconditions.io "$profile" --ignore-not-found -o json; }
current=$(get_profile); current_uid=
if [[ -n $current ]]; then current_uid=$(jq -er .metadata.uid <<<"$current"); fi
if [[ -f $record ]]; then
  jq -e --argjson c "$clusters" --arg n "$namespace" --arg p "$profile" '.clusters==$c and .namespace==$n and .profile==$p' "$record" >/dev/null || die 'Resume record does not match the selected target'
  uid=$(jq -er .uid "$record")
  if [[ -n $current_uid && $current_uid != "$uid" ]]; then
    jq -e '.complete==true' "$record" >/dev/null || die 'Profile was recreated during an unfinished teardown; stop publishing and resolve the old run first'
    uid=$current_uid
  elif [[ -z $current_uid ]] && jq -e '.complete==true' "$record" >/dev/null; then printf 'Rechecking the completed application teardown.\n'; fi
else uid=$current_uid; fi
[[ -n $uid ]] || die 'No profile or saved inventory exists; cannot safely infer ownership of leftover infrastructure'
if [[ ! -f $record ]] || [[ $(jq -r .uid "$record") != "$uid" ]]; then
  save "$(jq -cn --argjson c "$clusters" --arg n "$namespace" --arg p "$profile" --arg u "$uid" '{clusters:$c,namespace:$n,profile:$p,uid:$u,requests:[],streams:{},complete:false}')"
fi
save "$(jq '.complete=false' "$record")"
printf 'Target: %s/%s (%s)\nResume inventory: %s\n' "$namespace" "$profile" "$uid" "$record"
selector="app.kubernetes.io/managed-by=rcprofile-watcher,demo.runtimeconditions.io/source-uid=$uid"
types='workloads.platform.runtimeconditions.io,postgresdatabases.dev.platform.runtimeconditions.io,emailsenders.dev.platform.runtimeconditions.io,natsstreams.dev.platform.runtimeconditions.io,postgresdatabases.production.platform.runtimeconditions.io,emailsenders.production.platform.runtimeconditions.io,natsstreams.production.platform.runtimeconditions.io'
deadline=$((SECONDS + timeout))
remaining() { ((SECONDS < deadline)) || die "Timed out waiting for $1; retain $record and inspect Kratix/Flux before rerunning"; }
ensure_no_replacement() {
  local live id
  live=$(get_profile); id=
  if [[ -n $live ]]; then id=$(jq -er .metadata.uid <<<"$live"); fi
  [[ -z $id || $id == "$uid" ]] || die 'A replacement profile appeared; stop publishing before resuming'
}
snapshot() {
  local objects entries
  objects=$(k "$mgmt" -n promise-workflows get "$types" -l "$selector" -o json)
  entries=$(jq -c '[.items[] | {name:.metadata.name,uid:.metadata.uid,apiVersion,kind,environment:.metadata.labels["demo.runtimeconditions.io/environment"],created:.metadata.creationTimestamp,stream:(.spec.stream//null)}]' <<<"$objects")
  save "$(jq --argjson additions "$entries" '.requests=(.requests+$additions|unique_by([.uid,.stream]))' "$record")"
  count=$(jq '.items|length' <<<"$objects")
}
start_clients() {
  local environment context
  for environment in dev production; do
    if jq -e --arg e "$environment" '. as $r|.requests|any(.kind=="NatsStream" and .environment==$e and $r.streams[.environment+"/"+.stream].done!=true)' "$record" >/dev/null && [[ " $clients " != *" $environment "* ]]; then
      context=$(context_for "$environment")
      k "$context" -n nats run "$pod" --image=natsio/nats-box:0.14.5 --restart=Never --labels=app.kubernetes.io/managed-by=rcprofile-teardown --command -- sleep "$((timeout+300))" >/dev/null
      clients="$clients $environment"
      k "$context" -n nats wait --for=condition=Ready "pod/$pod" --timeout=3m >/dev/null
    fi
  done
}
nats_cli() { local environment=$1; shift; k "$(context_for "$environment")" -n nats exec "$pod" -- nats --server nats://nats.nats.svc.cluster.local:4222 "$@"; }
check_streams() {
  local mode=$1 rows environment stream key others names info created saved_created
  rows=$(jq -r '.requests|map(select(.kind=="NatsStream"))|group_by([.environment,.stream])[]|[.[0].environment,.[0].stream]|@tsv' "$record")
  while IFS=$'\t' read -r environment stream; do
    [[ -n $environment ]] || continue
    [[ $stream =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die 'Unverifiable stream name in inventory'
    key="$environment/$stream"
    if jq -e --arg k "$key" '.streams[$k].done==true' "$record" >/dev/null; then continue; fi
    others=$(k "$mgmt" get "natsstreams.$environment.platform.runtimeconditions.io" -A -o json)
    jq -e --arg s "$stream" --arg u "$uid" '[.items[]|select(.spec.stream==$s and .metadata.labels["demo.runtimeconditions.io/source-uid"]!=$u)]|length==0' <<<"$others" >/dev/null || die "Stream $key is referenced by another request; nothing shared will be removed"
    others=$(k "$mgmt" get runtimeconditionsprofiles.runtimeconditions.io -A -o json)
    jq -e --arg s "$stream" --arg u "$uid" '[.items[]|select(.metadata.uid!=$u)|.conditions[]?|select(.kind=="nats.service")|.interface.operations[]?|objects|select(.stream==$s)]|length==0' <<<"$others" >/dev/null || die "Another profile declares stream $key; refusing removal"
    names=$(nats_cli "$environment" stream ls --names)
    if grep -Fxq -- "$stream" <<<"$names"; then
      info=$(nats_cli "$environment" stream info --json -- "$stream")
      created=$(jq -er .created <<<"$info")
      saved_created=$(jq -r --arg k "$key" '.streams[$k].created//empty' "$record")
      [[ -z $saved_created || $saved_created == "$created" ]] || die "Stream $key was recreated; ownership needs review"
      save "$(jq --arg k "$key" --arg c "$created" '.streams[$k]={created:$c,done:false}' "$record")"
      if [[ $mode == remove ]]; then nats_cli "$environment" stream rm --force -- "$stream"; fi
    fi
    if [[ $mode == remove ]]; then save "$(jq --arg k "$key" '.streams[$k].done=true' "$record")"; fi
  done <<<"$rows"
}
snapshot; start_clients; check_streams inspect
remaining 'preflight ownership checks'
if [[ -n $current_uid ]]; then
  printf 'Deleting source profile; this stops its requests being recreated.\n'
  jq -cn --arg uid "$uid" '{apiVersion:"v1",kind:"DeleteOptions",preconditions:{uid:$uid}}' |
    k "$mgmt" delete --raw="/apis/runtimeconditions.io/v1alpha1/namespaces/$namespace/runtimeconditionsprofiles/$profile" -f - >/dev/null
fi
while :; do
  current=$(get_profile); [[ -n $current ]] || break
  ensure_no_replacement; remaining 'source profile deletion'; sleep 5
done
printf 'Waiting for request deletion, including production database and SMTP delete workflows.\n'
empty=0
while ((empty < 2)); do
  ensure_no_replacement; snapshot
  if ((count == 0)); then empty=$((empty+1)); else
    empty=0; start_clients; check_streams inspect
    k "$mgmt" -n promise-workflows delete "$types" -l "$selector" --ignore-not-found --wait=false >/dev/null
  fi
  remaining 'Kratix requests'; sleep 5
done
for environment in dev production; do
  names=$(jq -r --arg e "$environment" '[.requests[]|select(.environment==$e)|.name]|unique|join(",")' "$record")
  [[ -n $names ]] || continue
  printf 'Waiting for Flux to prune %s resources.\n' "$environment"
  while :; do
    ensure_no_replacement
    objects=$(k "$(context_for "$environment")" -n application-support get deploy,sts,svc,secret,job,pvc,pod -l "app.kubernetes.io/instance in ($names)" -o name)
    [[ -n $objects ]] || break
    remaining "$environment delivered resources/PVCs"; sleep 5
  done
done
ensure_no_replacement; snapshot
((count == 0)) || die 'Requests reappeared; rerun to finish cleanup before removing streams'
check_streams remove
save "$(jq '.complete=true' "$record")"
printf 'Application teardown complete. Shared platform and kubeconfig were retained.\n'
