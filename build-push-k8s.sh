#!/usr/bin/env bash
#
# build-push-k8s.sh — build the three Kubernetes image-mode (bootc) images and
# push them into the Katello internal registry on foreman.garaventaville.com.
#
#   almalinux10-bootc:<base>                         (existing base, see Containerfile)
#     └── kubernetes-common:<tag>                    (containerd + kubelet/kubeadm/kubectl)
#           ├── kubernetes-controlplane:<tag>        (+ keepalived, haproxy)
#           └── kubernetes-worker:<tag>              (+ lvm2, gdisk, iscsi)
#
# Usage:
#   ./build-push-k8s.sh [TAG]
#   TAG defaults to "1.35.5" (matches the pinned K8S_VERSION in the common
#   Containerfile). Override REGISTRY/ORG/PRODUCT via env vars.
#
# Login first (interactive, once per session / until token expires):
#   podman login "$REGISTRY"
#
# The build host / is small — prune.sh runs at the end to reclaim disk. common
# is the base for controlplane/worker, so it is NOT pruned until all three are
# built and pushed.
set -euo pipefail

# --- Config (override via environment) -------------------------------------
REGISTRY="${REGISTRY:-foreman.garaventaville.com}"
ORG="${ORG:-garaventaville}"     # org label "Garaventaville", lowercased
PRODUCT="${PRODUCT:-bootc}"      # Katello product the images are pushed into
TAG="${1:-${TAG:-1.35.5}}"
CONTEXT="${CONTEXT:-$(dirname "$0")}"   # repo root — Containerfiles COPY from kubernetes/files/

COMMON="kubernetes-common"
CP="kubernetes-controlplane"
WORKER="kubernetes-worker"

# --- Build: common first (pulls the base), then the two role images ---------
echo ">> Building ${COMMON}:${TAG} (FROM ${REGISTRY}/${ORG}/${PRODUCT}/almalinux10-bootc)"
podman build --pull=always -t "${COMMON}:${TAG}" \
  -f "${CONTEXT}/kubernetes/common/Containerfile" "${CONTEXT}"

# controlplane/worker build FROM the local kubernetes-common — do NOT --pull
# (it isn't in the registry yet) and pass the tag so FROM resolves.
echo ">> Building ${CP}:${TAG} (FROM ${COMMON}:${TAG})"
podman build --pull=false --build-arg "K8S_IMAGE_TAG=${TAG}" -t "${CP}:${TAG}" \
  -f "${CONTEXT}/kubernetes/controlplane/Containerfile" "${CONTEXT}"

echo ">> Building ${WORKER}:${TAG} (FROM ${COMMON}:${TAG})"
podman build --pull=false --build-arg "K8S_IMAGE_TAG=${TAG}" -t "${WORKER}:${TAG}" \
  -f "${CONTEXT}/kubernetes/worker/Containerfile" "${CONTEXT}"

# --- Smoke test: the bootc win is testing the OS as a container first -------
echo ">> Smoke test: bootc version + baked package presence"
podman run --rm "${COMMON}:${TAG}" bootc --version
podman run --rm "${COMMON}:${TAG}" rpm -q kubeadm kubelet kubectl containerd \
  && echo "   common: kube* + containerd present: OK"
podman run --rm "${CP}:${TAG}" rpm -q keepalived haproxy \
  && echo "   controlplane: keepalived + haproxy present: OK"
podman run --rm "${WORKER}:${TAG}" rpm -q lvm2 gdisk iscsi-initiator-utils \
  && echo "   worker: lvm2 + gdisk + iscsi present: OK"

# --- Confirm logged in, then push all three --------------------------------
if ! podman login --get-login "${REGISTRY}" >/dev/null 2>&1; then
  echo "!! Not logged in to ${REGISTRY}. Run:  podman login ${REGISTRY}" >&2
  exit 1
fi

for img in "${COMMON}" "${CP}" "${WORKER}"; do
  remote="${REGISTRY}/${ORG}/${PRODUCT}/${img}:${TAG}"
  echo ">> Tagging  ${img}:${TAG} -> ${remote}"
  podman tag "${img}:${TAG}" "${remote}"
  echo ">> Pushing  ${remote}"
  podman push "${remote}"
done

echo ">> Done. Images available at:"
for img in "${COMMON}" "${CP}" "${WORKER}"; do
  echo "     ${REGISTRY}/${ORG}/${PRODUCT}/${img}:${TAG}"
done
echo "   Set the controlplane/worker refs as the 'ostreecontainer' host-group param."

# --- Reclaim disk -----------------------------------------------------------
if [ -x "${CONTEXT}/prune.sh" ]; then
  echo ">> Pruning build host..."
  "${CONTEXT}/prune.sh"
fi
