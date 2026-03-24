#!/bin/bash

set -euxo pipefail

# only supports sha tags, e.g.: ghcr.io/rancher/fleet:sha-49f6f81
if [ $# -ge 2 ] && [ -n "$1" ] && [ -n "$2" ]; then
  fleetRepo="${1%:*}"
  fleetTag="${1#*:}"
  agentRepo="${2%:*}"
  agentTag="${2#*:}"
else
  fleetRepo="rancher/fleet"
  fleetTag="dev"
  agentRepo="rancher/fleet-agent"
  agentTag="dev"
fi

upstream_ctx="${FLEET_E2E_CLUSTER-k3d-upstream}"
downstream_ctx="${FLEET_E2E_CLUSTER_DOWNSTREAM-k3d-downstream1}"

resolve_k3d_context() {
  local requested="$1"
  local prefix="${requested%[0-9]*}"
  local context

  if kubectl config get-contexts -o name | grep -Fxq "$requested"; then
    printf '%s\n' "$requested"
    return 0
  fi

  while IFS= read -r context; do
    case "$context" in
      ${prefix}|${prefix}[0-9]*)
        printf '%s\n' "$context"
        return 0
        ;;
    esac
  done < <(kubectl config get-contexts -o name)

  echo "unable to resolve kube context: $requested" >&2
  return 1
}

downstream_ctx=$(resolve_k3d_context "$downstream_ctx")

inplace_version_bump() {
  local chart_file="$1"
  sed -i.bak 's/^version: 0/version: 9000/' "$chart_file"
  rm -f "${chart_file}.bak"
}

helm_status_is_deployed() {
  local kube_ctx="$1"
  local release="$2"
  local namespace="$3"
  local status_output

  status_output="$(helm --kube-context "$kube_ctx" -n "$namespace" status "$release" 2>/dev/null || true)"
  [[ "$status_output" == *"STATUS: deployed"* ]]
}

wait_for_bundle_image() {
  local namespace="$1"
  local bundle_name="${2-}"
  local desired_image="$3"
  local bundle_resources

  while true; do
    if [ -n "$bundle_name" ]; then
      bundle_resources="$(kubectl --context "$upstream_ctx" get bundles -n "$namespace" "$bundle_name" -ojsonpath='{.spec.resources}' 2>/dev/null || true)"
    else
      bundle_resources="$(kubectl --context "$upstream_ctx" get bundles -n "$namespace" -ojsonpath='{.items[*].spec.resources}' 2>/dev/null || true)"
    fi

    if [[ "$bundle_resources" == *"image: ${desired_image}"* ]]; then
      return 0
    fi

    echo "waiting for bundle image ${desired_image} in namespace ${namespace}"
    sleep 3
  done
}

wait_for_downstream_agent_rollout() {
  local desired_image="$1"
  local resource_kind
  local resource_images

  while true; do
    resource_kind=""

    if kubectl --context "$downstream_ctx" -n cattle-fleet-system get statefulset fleet-agent >/dev/null 2>&1; then
      resource_kind="statefulset/fleet-agent"
    elif kubectl --context "$downstream_ctx" -n cattle-fleet-system get deploy fleet-agent >/dev/null 2>&1; then
      resource_kind="deploy/fleet-agent"
    fi

    if [ -z "$resource_kind" ]; then
      echo "waiting for downstream fleet-agent workload"
      sleep 2
      continue
    fi

    resource_images="$(kubectl --context "$downstream_ctx" -n cattle-fleet-system get "$resource_kind" -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null || true)"
    if [[ "$resource_images" != *"${desired_image}"* ]]; then
      echo "waiting for downstream fleet-agent to use ${desired_image}"
      sleep 2
      continue
    fi

    kubectl --context "$downstream_ctx" -n cattle-fleet-system rollout status "$resource_kind"
    return 0
  done
}

until helm_status_is_deployed "$upstream_ctx" fleet-crd cattle-fleet-system; do echo waiting for original fleet-crd chart to be deployed; sleep 1; done

# avoid a downgrade by rancher
inplace_version_bump charts/fleet-crd/Chart.yaml
helm --kube-context "$upstream_ctx" upgrade fleet-crd charts/fleet-crd --wait -n cattle-fleet-system

until helm_status_is_deployed "$upstream_ctx" fleet cattle-fleet-system; do echo waiting for original fleet chart to be deployed; sleep 3; done

# avoid a downgrade by rancher
inplace_version_bump charts/fleet/Chart.yaml

helm --kube-context "$upstream_ctx" upgrade fleet charts/fleet \
  --reset-then-reuse-values \
  --wait -n cattle-fleet-system \
  --create-namespace \
  --set image.repository="$fleetRepo" \
  --set image.tag="$fleetTag" \
  --set agentImage.repository="$agentRepo" \
  --set agentImage.tag="$agentTag" \
  --set agentImage.imagePullPolicy=IfNotPresent

kubectl --context "$upstream_ctx" -n cattle-fleet-system rollout status deploy/fleet-controller
helm --kube-context "$upstream_ctx" list -A

# wait for local and downstream bundle images to update
wait_for_bundle_image fleet-local fleet-agent-local "${agentRepo}:${agentTag}"
wait_for_bundle_image fleet-default "" "${agentRepo}:${agentTag}"

# wait for fleet agent bundle for downstream cluster
sleep 5
{ grep -E -q -m 1 "fleet-agent-c.*1/1"; kill $!; } < <(kubectl --context "$upstream_ctx" get bundles -n fleet-default -w)

wait_for_downstream_agent_rollout "${agentRepo}:${agentTag}"

helm --kube-context "$downstream_ctx" list -A
