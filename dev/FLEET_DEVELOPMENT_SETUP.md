# Fleet Development Setup and Image Workflow

This guide is for developers working on Fleet locally and testing changes in:

- a local Rancher + k3d environment
- a local standalone Fleet environment
- an existing predeployed cluster that can pull custom images from a registry

It is written as a practical workflow document, not a reference for every script.

## Mental model

There are two different image workflows in this repository:

- Local k3d workflow: build `rancher/fleet:dev` and `rancher/fleet-agent:dev`, then import those images into the k3d node container runtimes.
- Predeployed cluster workflow: tag the images with a registry/repository that the cluster can pull from, push them to that registry, then update Fleet to use those image references.

You do not "push an image into Rancher". Rancher does not store container images. Rancher deploys workloads that reference images. Those images must either:

- already exist in the node runtime, or
- be available in a registry the cluster can pull from.

## Prerequisites

At minimum:

- `docker`
- `kubectl`
- `helm`
- `jq`
- `k3d`
- `go`
- `rancher` CLI if you use the Rancher registration scripts
- `ginkgo` if you want to run the e2e suites

Examples:

```bash
brew install helm jq k3d rancher-cli
go install github.com/onsi/ginkgo/v2/ginkgo@latest
export PATH="$PATH:$(go env GOPATH)/bin"
```

## Architecture matters

Build the binaries and images for the same architecture as your cluster nodes.

- For Apple Silicon or other arm64 environments: `GOARCH=arm64`
- For typical x86_64 Linux environments: `GOARCH=amd64`

Examples:

```bash
GOARCH=arm64 ./dev/build-fleet
GOARCH=amd64 ./dev/build-fleet
```

## Recommended local multi-cluster config

Create `env.multi-cluster` in the repo root instead of editing the defaults:

```bash
cat > env.multi-cluster <<'EOF'
export FLEET_E2E_NS=fleet-local
export FLEET_E2E_NS_DOWNSTREAM=fleet-default

export FLEET_E2E_CLUSTER=k3d-upstream
export FLEET_E2E_CLUSTER_DOWNSTREAM=k3d-downstream1

export GIT_HTTP_USER=fleet-ci
export GIT_HTTP_PASSWORD=foo

export CI_OCI_USERNAME=fleet-ci
export CI_OCI_PASSWORD=foo
EOF

source env.multi-cluster
```

## Local Rancher + k3d setup

This is the best workflow if you want to validate Fleet changes as they behave inside Rancher.

### 1. Recreate the clusters

```bash
./dev/k3d-clean
./dev/setup-k3d
./dev/setup-k3ds-downstream
```

Sanity check:

```bash
kubectl --context k3d-upstream get nodes
kubectl --context k3d-downstream1 get nodes
```

### 2. Set the public Rancher hostname

The Rancher setup script expects a hostname that the downstream cluster can resolve. A `sslip.io` hostname derived from the upstream node IP works well enough for cluster-to-cluster communication.

```bash
export public_hostname="$(docker inspect k3d-upstream-server-0 | jq -r '.[0].NetworkSettings.Networks.fleet.IPAddress')"
```

The setup script appends `.sslip.io` if you pass a raw IPv4 address.

### 3. Install Rancher into the upstream cluster

Pass the Rancher version without a leading `v`.

```bash
./dev/setup-rancher-clusters 2.11.3
```

What this does:

- installs cert-manager
- installs Rancher in `cattle-system`
- waits for the Fleet installation Rancher manages
- registers the downstream cluster
- labels the downstream Fleet cluster for the multi-cluster tests

### 4. Open the Rancher UI

On macOS, the `*.sslip.io` hostname often works for in-cluster communication but not from the host browser. Rancher is also served over HTTPS, not HTTP.

Use a port-forward:

```bash
kubectl --context k3d-upstream -n cattle-system port-forward svc/rancher 9443:443
```

Then open:

```text
https://127.0.0.1:9443
```

You will get a local certificate warning.

## Build local Fleet images

From the Fleet repo root:

```bash
GOARCH=arm64 ./dev/build-fleet
```

This produces:

- `rancher/fleet:dev`
- `rancher/fleet-agent:dev`

For amd64 environments:

```bash
GOARCH=amd64 ./dev/build-fleet
```

## Use your local image in the local Rancher + k3d environment

### Preferred model

For local k3d, the cluster nodes do not need a registry push. The fastest route is:

1. build the local images
2. import them into the k3d nodes
3. upgrade the Rancher-managed Fleet release to use `:dev`

### 1. Import the images into the k3d nodes

If `k3d image import` works reliably in your environment, use:

```bash
./dev/import-images-k3d
```

If the direct import path is flaky, the manual fallback is:

```bash
docker save rancher/fleet:dev rancher/fleet-agent:dev -o /tmp/fleet-dev-images.tar

docker cp /tmp/fleet-dev-images.tar k3d-upstream-server-0:/tmp/fleet-dev-images.tar
docker cp /tmp/fleet-dev-images.tar k3d-upstream-server-1:/tmp/fleet-dev-images.tar
docker cp /tmp/fleet-dev-images.tar k3d-upstream-server-2:/tmp/fleet-dev-images.tar
docker cp /tmp/fleet-dev-images.tar k3d-downstream1-server-0:/tmp/fleet-dev-images.tar

docker exec k3d-upstream-server-0 ctr -n k8s.io images import /tmp/fleet-dev-images.tar
docker exec k3d-upstream-server-1 ctr -n k8s.io images import /tmp/fleet-dev-images.tar
docker exec k3d-upstream-server-2 ctr -n k8s.io images import /tmp/fleet-dev-images.tar
docker exec k3d-downstream1-server-0 ctr -n k8s.io images import /tmp/fleet-dev-images.tar
```

Verify:

```bash
docker exec k3d-upstream-server-0 crictl images | rg 'rancher/fleet|rancher/fleet-agent'
docker exec k3d-downstream1-server-0 crictl images | rg 'rancher/fleet|rancher/fleet-agent'
```

### 2. Upgrade Rancher-managed Fleet to those images

Use the repo helper:

```bash
FLEET_E2E_CLUSTER=k3d-upstream \
FLEET_E2E_CLUSTER_DOWNSTREAM=k3d-downstream1 \
./.github/scripts/upgrade-rancher-fleet-to-dev-fleet.sh
```

That upgrades:

- the Fleet CRD chart
- the Fleet chart in `cattle-fleet-system`
- the downstream Fleet agent bundle

### 3. Verify the deployment is on your images

Upstream controller:

```bash
kubectl --context k3d-upstream -n cattle-fleet-system \
  get deploy fleet-controller \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

Downstream agent:

```bash
kubectl --context k3d-downstream1 -n cattle-fleet-system \
  get statefulset fleet-agent \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

Expected output includes:

- `rancher/fleet:dev`
- `rancher/fleet-agent:dev`

## Day-to-day edit, rebuild, retest loop

Typical loop:

1. edit Fleet code
2. rebuild images
3. import images into the local k3d nodes
4. upgrade Fleet in Rancher again
5. rerun the relevant tests

Example:

```bash
GOARCH=arm64 ./dev/build-fleet
./dev/import-images-k3d
FLEET_E2E_CLUSTER=k3d-upstream \
FLEET_E2E_CLUSTER_DOWNSTREAM=k3d-downstream1 \
./.github/scripts/upgrade-rancher-fleet-to-dev-fleet.sh
```

For a faster loop when you only changed one binary:

- controller only: [`dev/update-controller-k3d`](./update-controller-k3d)
- agent only: [`dev/update-agent-k3d`](./update-agent-k3d)

Those are most useful for the standalone Fleet-on-k3d flow. For Rancher-managed Fleet, the full build/import/upgrade cycle is the safer path.

## Run tests locally

### Rancher-backed multi-cluster tests

The multi-cluster suite defaults to a downstream Fleet cluster named `second`. In a Rancher-registered setup, the actual Fleet cluster name is usually the Rancher cluster ID such as `c-zzsqm`.

Set it explicitly:

```bash
export CI_REGISTERED_CLUSTER="$(
  kubectl --context k3d-upstream -n fleet-default \
    get clusters.fleet.cattle.io \
    -o jsonpath='{.items[0].metadata.name}'
)"
```

Then run:

```bash
FLEET_E2E_NS=fleet-local \
FLEET_E2E_NS_DOWNSTREAM=fleet-default \
FLEET_E2E_CLUSTER=k3d-upstream \
FLEET_E2E_CLUSTER_DOWNSTREAM=k3d-downstream1 \
CI_REGISTERED_CLUSTER="$CI_REGISTERED_CLUSTER" \
ginkgo --poll-progress-after=30s --poll-progress-interval=30s e2e/multi-cluster
```

### Standalone Fleet tests

The standalone path is simpler and documented in [`dev/README.md`](./README.md), but it is not the same as the Rancher-managed flow described above.

## Use the same image in a predeployed cluster

For a predeployed cluster, node-local k3d imports are not enough. The cluster must be able to pull the image from a registry.

### 1. Build the images

```bash
GOARCH=amd64 ./dev/build-fleet
```

Use `arm64` if the target cluster nodes are arm64.

### 2. Retag the images for your registry

Example:

```bash
export IMAGE_REPO=ghcr.io/<org-or-user>
export IMAGE_TAG=$(git rev-parse --short HEAD)

docker tag rancher/fleet:dev "$IMAGE_REPO/fleet:$IMAGE_TAG"
docker tag rancher/fleet-agent:dev "$IMAGE_REPO/fleet-agent:$IMAGE_TAG"
```

### 3. Push them to the registry

```bash
docker push "$IMAGE_REPO/fleet:$IMAGE_TAG"
docker push "$IMAGE_REPO/fleet-agent:$IMAGE_TAG"
```

If the target cluster cannot pull from that registry anonymously, configure registry credentials first.

### 4. Point Fleet at those images

There are two common cases.

#### Case A: standalone Fleet on a cluster

If you are running Fleet directly on a cluster without Rancher managing the Fleet install, update the Fleet charts with Helm and point them at your registry images:

```bash
helm upgrade --install fleet-crd charts/fleet-crd \
  --namespace cattle-fleet-system \
  --create-namespace

helm upgrade --install fleet charts/fleet \
  --namespace cattle-fleet-system \
  --create-namespace \
  --set image.repository="$IMAGE_REPO/fleet" \
  --set image.tag="$IMAGE_TAG" \
  --set agentImage.repository="$IMAGE_REPO/fleet-agent" \
  --set agentImage.tag="$IMAGE_TAG" \
  --set agentImage.imagePullPolicy=IfNotPresent
```

That is the generic path for a predeployed standalone cluster.

The helper [`deploy-fleet.sh`](../.github/scripts/deploy-fleet.sh) is still useful for the local standalone k3d flow, but it is written around the local k3d assumptions in this repository and should not be treated as the generic predeployed-cluster workflow.

The important chart values are:

- `image.repository`
- `image.tag`
- `agentImage.repository`
- `agentImage.tag`

#### Case B: Rancher-managed Fleet on a cluster

If the target environment already has Rancher and Rancher manages Fleet, upgrade the Fleet chart Rancher installed:

```bash
FLEET_E2E_CLUSTER=<rancher-cluster-context> \
FLEET_E2E_CLUSTER_DOWNSTREAM=<downstream-cluster-context> \
./.github/scripts/upgrade-rancher-fleet-to-dev-fleet.sh \
  "$IMAGE_REPO/fleet:$IMAGE_TAG" \
  "$IMAGE_REPO/fleet-agent:$IMAGE_TAG"
```

This is the correct equivalent of "use my custom Fleet image in Rancher".

### 5. Verify the running image in the predeployed cluster

Controller:

```bash
kubectl -n cattle-fleet-system get deploy fleet-controller \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

Agent:

```bash
kubectl -n cattle-fleet-system get statefulset fleet-agent \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

## Troubleshooting

### Rancher UI does not open on `http://<ip>.sslip.io`

- Rancher is on HTTPS, not HTTP.
- On macOS, the `sslip.io` hostname may work for cluster-internal traffic but not from the host browser.
- Use:

```bash
kubectl --context k3d-upstream -n cattle-system port-forward svc/rancher 9443:443
```

Then open:

```text
https://127.0.0.1:9443
```

### The build works on amd64 but not arm64

Set:

```bash
export GOARCH=arm64
```

Then rebuild.

### The local test suite fails looking for cluster `second`

This is expected in Rancher-backed setups unless you set `CI_REGISTERED_CLUSTER` to the actual Fleet cluster name.

### `charts/fleet/Chart.yaml` or `charts/fleet-crd/Chart.yaml` became dirty

The Rancher Fleet upgrade helper bumps the chart version to `9000` locally to prevent Rancher downgrading your test deployment. That dirty state is expected after the upgrade helper runs.

## Suggested workflow summary

If your goal is "I changed Fleet code and want to validate it in Rancher locally", the shortest reliable path is:

```bash
source env.multi-cluster
./dev/k3d-clean
./dev/setup-k3d
./dev/setup-k3ds-downstream
export public_hostname="$(docker inspect k3d-upstream-server-0 | jq -r '.[0].NetworkSettings.Networks.fleet.IPAddress')"
./dev/setup-rancher-clusters 2.11.3
GOARCH=arm64 ./dev/build-fleet
./dev/import-images-k3d
FLEET_E2E_CLUSTER=k3d-upstream FLEET_E2E_CLUSTER_DOWNSTREAM=k3d-downstream1 ./.github/scripts/upgrade-rancher-fleet-to-dev-fleet.sh
export CI_REGISTERED_CLUSTER="$(kubectl --context k3d-upstream -n fleet-default get clusters.fleet.cattle.io -o jsonpath='{.items[0].metadata.name}')"
ginkgo e2e/multi-cluster
```

If `./dev/import-images-k3d` is unreliable in your environment, use the manual `docker save` + `docker cp` + `ctr images import` fallback shown earlier in this guide.
