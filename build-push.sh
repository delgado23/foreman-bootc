#!/usr/bin/env bash
#
# build-push.sh — build the AlmaLinux 10 bootc image and push it into the
# Katello internal registry on foreman.garaventaville.com.
#
# Usage:
#   ./build-push.sh [TAG]
#   TAG defaults to "10.0". Override REGISTRY/ORG/ENV/IMAGE via env vars.
#
# Login first (interactive, once per session / until token expires):
#   podman login "$REGISTRY"
#
set -euo pipefail

# --- Config (override via environment) -------------------------------------
REGISTRY="${REGISTRY:-foreman.garaventaville.com}"
# Katello container PUSH requires a 3-part path: <org_label>/<product_label>/<name>
# (matched case-insensitively by Katello, but podman requires lowercase here).
ORG="${ORG:-garaventaville}"     # org label "Garaventaville", lowercased
PRODUCT="${PRODUCT:-bootc}"      # Katello product created for bootc images
IMAGE="${IMAGE:-almalinux10-bootc}"
TAG="${1:-${TAG:-10.0}}"
CONTEXT="${CONTEXT:-$(dirname "$0")}"

LOCAL_REF="${IMAGE}:${TAG}"
REMOTE_REF="${REGISTRY}/${ORG}/${PRODUCT}/${IMAGE}:${TAG}"

echo ">> Building ${LOCAL_REF} from ${CONTEXT}/Containerfile"
podman build --pull=always -t "${LOCAL_REF}" -f "${CONTEXT}/Containerfile" "${CONTEXT}"

# --- Smoke test: the bootc win is testing the OS as a container first ------
echo ">> Smoke test: bootc status + package presence inside the container"
podman run --rm "${LOCAL_REF}" bootc --version
podman run --rm "${LOCAL_REF}" rpm -q qemu-guest-agent >/dev/null \
  && echo "   baked packages present: OK"

# --- Confirm logged in, then push ------------------------------------------
if ! podman login --get-login "${REGISTRY}" >/dev/null 2>&1; then
  echo "!! Not logged in to ${REGISTRY}. Run:  podman login ${REGISTRY}" >&2
  exit 1
fi

echo ">> Tagging  ${LOCAL_REF} -> ${REMOTE_REF}"
podman tag "${LOCAL_REF}" "${REMOTE_REF}"

echo ">> Pushing  ${REMOTE_REF}"
podman push "${REMOTE_REF}"

echo ">> Done. Image available at:"
echo "     ${REMOTE_REF}"
echo "   Set this as the host parameter 'ostreecontainer'."
