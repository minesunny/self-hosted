#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

NAMESPACE="arc-runners"
LISTENER_NAMESPACE="arc-systems"
RELEASE="arc-runner-set"
VERSION="0.15.0"
CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
VALUES="values.yaml"
TIMEOUT="5m"


ACTION="${1:-start}"
[[ $# -le 1 ]] || { echo "Usage: $0 {start|stop|restart|status|help}" >&2; exit 2; }
case "$ACTION" in
  help|-h|--help) echo "Usage: $0 {start|stop|restart|status}"; exit 0 ;;
  start|stop|restart|status) ;;
  *) echo "Unknown command: $ACTION" >&2; exit 2 ;;
esac

for command in helm kubectl python3; do
  command -v "$command" >/dev/null || { echo "ERROR: missing command: $command" >&2; exit 1; }
done

remove_runners() {
    # 按 Helm 所属标记查找本 release 的集合，避免影响其他仓库。
    SETS_JSON=$(kubectl get autoscalingrunnersets \
      -n "$NAMESPACE" -o json)

    SET_NAMES=$(python3 -c '
import json, sys
release, namespace = sys.argv[1:3]
for item in json.load(sys.stdin)["items"]:
    annotations = item["metadata"].get("annotations") or {}
    if (
        annotations.get("meta.helm.sh/release-name") == release
        and annotations.get("meta.helm.sh/release-namespace") == namespace
    ):
        print(item["metadata"]["name"])
' "$RELEASE" "$NAMESPACE" <<< "$SETS_JSON")

    # 卸载前记录 listener 名称；旧集合删除后可能留下它们。
    LISTENERS_JSON=$(kubectl get autoscalinglisteners \
      -n "$LISTENER_NAMESPACE" -o json)

    LISTENER_NAMES=$(python3 -c '
import json, sys
namespace = sys.argv[1]
sets = set(sys.argv[2].split())
for item in json.load(sys.stdin)["items"]:
    spec = item.get("spec") or {}
    if (
        spec.get("autoscalingRunnerSetNamespace") == namespace
        and spec.get("autoscalingRunnerSetName") in sets
    ):
        print(item["metadata"]["name"])
' "$NAMESPACE" "$SET_NAMES" <<< "$LISTENERS_JSON")

    echo "==> Uninstalling old runner scale set..."
    helm uninstall "$RELEASE" \
      --namespace "$NAMESPACE" \
      --wait \
      --timeout "$TIMEOUT"

    # 仅清理刚才记录的旧 listener。
    while IFS= read -r listener; do
      [[ -n "$listener" ]] || continue
      kubectl delete autoscalinglistener "$listener" \
        -n "$LISTENER_NAMESPACE" \
        --ignore-not-found \
        --wait=true \
        --timeout="$TIMEOUT"
    done <<< "$LISTENER_NAMES"

    # 确认旧集合消失后才允许重新安装。
    while IFS= read -r set_name; do
      [[ -n "$set_name" ]] || continue
      remaining=$(kubectl get autoscalingrunnerset "$set_name" \
        -n "$NAMESPACE" --ignore-not-found -o name)

      if [[ -n "$remaining" ]]; then
        kubectl wait --for=delete "$remaining" \
          -n "$NAMESPACE" --timeout="$TIMEOUT"
      fi
    done <<< "$SET_NAMES"
}

status() {
  helm list -a -n "$NAMESPACE"
  kubectl get autoscalingrunnersets,ephemeralrunnersets -n "$NAMESPACE"
  kubectl get autoscalinglisteners -n "$LISTENER_NAMESPACE"
  kubectl get pods,pvc -n "$NAMESPACE"
}

start() {
  [[ -f "$VALUES" ]] || { echo "ERROR: $VALUES not found" >&2; return 1; }
  python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: install python3-yaml first" >&2; return 1; }
  local new_url old_url
  new_url=$(python3 - "$VALUES" <<'PYURL'
import sys,yaml
v=yaml.safe_load(open(sys.argv[1])) or {}
u=v.get("githubConfigUrl")
if not isinstance(u,str) or not u.strip(): sys.exit("ERROR: invalid githubConfigUrl")
print(u.strip().rstrip("/"))
PYURL
)
  # Query separately: connection errors must never be mistaken for an absent release.
  local exists
  exists=$(helm list -a -n "$NAMESPACE" -o json)
  if python3 -c 'import json,sys; sys.exit(0 if any(x["name"]==sys.argv[1] for x in json.load(sys.stdin)) else 1)' "$RELEASE" <<< "$exists"; then
    local deployed
    deployed=$(helm get values "$RELEASE" -n "$NAMESPACE" -o json)
    old_url=$(python3 -c 'import json,sys; print(str((json.load(sys.stdin) or {}).get("githubConfigUrl") or "").strip().rstrip("/"))' <<< "$deployed")
    [[ -n "$old_url" ]] || { echo "ERROR: cannot determine deployed githubConfigUrl" >&2; return 1; }
    if [[ "$old_url" != "$new_url" ]]; then
      echo "==> Repository changed: $old_url -> $new_url"
      remove_runners
    fi
  fi
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  # Optional manifests live beside this script. Existing PVCs are never deleted.
  if [[ -f cache-pv.yaml ]]; then kubectl apply -f cache-pv.yaml; fi
  if [[ -f registry-cache.yaml ]]; then kubectl apply -f registry-cache.yaml; fi
  local cache
  cache=$(kubectl get deployment registry-cache -n "$NAMESPACE" --ignore-not-found -o name)
  if [[ -n "$cache" ]]; then
    kubectl scale "$cache" -n "$NAMESPACE" --replicas=1
    kubectl rollout status "$cache" -n "$NAMESPACE" --timeout="$TIMEOUT"
  fi
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" --create-namespace --version "$VERSION" \
    --values "$VALUES" --wait --timeout "$TIMEOUT"
  echo "==> Deployment completed; Helm readiness does not guarantee GitHub runner connectivity."
  status
}

stop() {
  echo "==> Stopping runners (active jobs may be interrupted)..."
  local releases exists cache
  releases=$(helm list -a -n "$NAMESPACE" -o json)
  exists=$(python3 -c 'import json,sys; print("yes" if any(x["name"]==sys.argv[1] for x in json.load(sys.stdin)) else "no")' "$RELEASE" <<< "$releases")
  if [[ "$exists" == yes ]]; then remove_runners; else echo "==> Runner release already absent."; fi
  cache=$(kubectl get deployment registry-cache -n "$NAMESPACE" --ignore-not-found -o name)
  if [[ -n "$cache" ]]; then
    kubectl scale "$cache" -n "$NAMESPACE" --replicas=0
    kubectl rollout status "$cache" -n "$NAMESPACE" --timeout="$TIMEOUT"
    kubectl wait --for=delete pod -n "$NAMESPACE" -l app=registry-cache --timeout="$TIMEOUT"
  fi
  echo "==> Stopped. PVCs, PVs, Secrets and shared ARC controller retained."
}

case "$ACTION" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
esac
