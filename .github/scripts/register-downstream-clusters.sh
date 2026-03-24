#!/bin/bash

set -euxo pipefail


public_hostname="${public_hostname-172.28.0.2.sslip.io}"
rancher_url="${rancher_url-https://$public_hostname}"
cluster_downstream="${cluster_downstream-${FLEET_E2E_CLUSTER_DOWNSTREAM-k3d-downstream1}}"
ctx=$(kubectl config current-context)

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

  echo "unable to resolve kube context for downstream cluster: $requested" >&2
  return 1
}

cluster_downstream=$(resolve_k3d_context "$cluster_downstream")

# hardcoded token, cluster is ephemeral and private
token="token-ci:zfllcbdr4677rkj4hmlr8rsmljg87l7874882928khlfs2pmmcq7l5"

user=$(kubectl get users -l authz.management.cattle.io/bootstrapping=admin-user -o go-template='{{range .items }}{{.metadata.name}}{{"\n"}}{{end}}' | tail -1)
sed "s/user-zvnsr/$user/" <<'EOF' | kubectl apply -f -
apiVersion: management.cattle.io/v3
kind: Token
authProvider: local
metadata:
  labels:
    authn.management.cattle.io/kind: kubeconfig
    authn.management.cattle.io/token-userId: user-zvnsr
    cattle.io/creator: norman
  name: token-ci
ttl: 0
token: zfllcbdr4677rkj4hmlr8rsmljg87l7874882928khlfs2pmmcq7l5
userId: user-zvnsr
userPrincipal:
  displayName: Default Admin
  loginName: admin
  me: true
  metadata:
    creationTimestamp: null
    name: local://user-zvnsr
  principalType: user
  provider: local
EOF

# Log into the 4th project listed by `rancher login`, which should be the local cluster's default project.
echo -e "4\n" | rancher login "$rancher_url" --token "$token" --skip-verify

rancher clusters create second --import
until rancher cluster ls --format json | jq -r 'select(.Name=="second") | .ID' | grep -Eq "c-[a-z0-9]" ; do sleep 1; done
id=$( rancher cluster ls --format json | jq -r 'select(.Name=="second") | .ID' )

until rancher cluster import "$id" | grep -q curl; do sleep 1; done
kubectl config use-context "$cluster_downstream"
rancher cluster import "$id" | grep curl | sh

until rancher cluster ls --format json | jq -r 'select(.Name=="second") | .Cluster.state' | grep -q active; do
  echo waiting for cluster registration
  sleep 5
done

kubectl config use-context "$ctx"

# Wait for Fleet agent to be ready on downstream cluster
until kubectl get bundles -n fleet-default | grep -q "fleet-agent-$id.*1/1"; do sleep 3; done
