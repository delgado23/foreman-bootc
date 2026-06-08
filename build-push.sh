#!/usr/bin/env bash
#
# build-push.sh — build the AlmaLinux 10 bootc image and push it into the
# Katello internal registry on foreman.garaventaville.com.
#
# Usage:
#   ./build-push.sh [TAG]
#   TAG defaults to "10.0". Override REGISTRY/ORG/ENV/IMAGE via env vars.
#   EXTRA_TAGS (space-separated) publishes the same image under additional tags
#   (e.g. a dated tag for the weekly Ascender build: EXTRA_TAGS="10.0-20260607").
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

# Publish under the pinned TAG plus any EXTRA_TAGS (e.g. a weekly dated tag).
# shellcheck disable=SC2206
EXTRA=(${EXTRA_TAGS:-})
ALL_TAGS=("${TAG}" "${EXTRA[@]}")
for t in "${ALL_TAGS[@]}"; do
  remote="${REGISTRY}/${ORG}/${PRODUCT}/${IMAGE}:${t}"
  echo ">> Tagging  ${LOCAL_REF} -> ${remote}"
  podman tag "${LOCAL_REF}" "${remote}"
  echo ">> Pushing  ${remote}"
  podman push "${remote}"
done

# --- Pull-back smoke test (the promotion gate) -----------------------------
# Re-pull the image we just pushed from the Katello registry (Library) and
# re-run the container checks against that round-tripped artifact, not the local
# build. This is what gates promotion to Production in the weekly run; a non-zero
# exit here stops the playbook before anything is promoted. Opt out of the extra
# pull on a manual run with SMOKE_PULL=0.
if [ "${SMOKE_PULL:-1}" != "0" ]; then
  echo ">> Pull-back smoke test: re-pulling ${REMOTE_REF} from the registry"
  podman rmi -f "${REMOTE_REF}" >/dev/null 2>&1 || true
  podman pull "${REMOTE_REF}"
  podman run --rm "${REMOTE_REF}" bootc --version
  podman run --rm "${REMOTE_REF}" rpm -q qemu-guest-agent >/dev/null \
    && echo "   pulled image OK: baked packages present"
fi

echo ">> Done. Image available at:"
for t in "${ALL_TAGS[@]}"; do
  echo "     ${REGISTRY}/${ORG}/${PRODUCT}/${IMAGE}:${t}"
done
echo "   Set the pinned ref as the host parameter 'ostreecontainer'."
