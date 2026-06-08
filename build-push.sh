#!/usr/bin/env bash
#
# build-push.sh — build the AlmaLinux 10 bootc image and push it into the
# Katello internal registry on foreman.garaventaville.com.
#
# Usage:
#   ./build-push.sh [RELEASE]
#   RELEASE is the AlmaLinux point release used as the image tag (e.g. "10.2").
#   If omitted it is auto-detected from the built image's /etc/os-release
#   VERSION_ID, so the tag FOLLOWS the upstream release without manual edits.
#
# Each run publishes three tags so hosts auto-follow point releases while
# snapshots stay pinnable:
#   :<major>            floating (e.g. :10) — what the Image Mode host group pins;
#                       always the latest gated release
#   :<release>          e.g. :10.2 — the point release, refreshed in place
#   :<release>-<date>   immutable weekly snapshot, when DATE_STAMP is set
# plus anything in EXTRA_TAGS (space-separated) for ad-hoc tags.
# Override REGISTRY/ORG/PRODUCT/IMAGE via env vars.
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
CONTEXT="${CONTEXT:-$(dirname "$0")}"

# Build to a working local tag — the release tag isn't known until the image
# exists (we read it from the built image below).
LOCAL_REF="${IMAGE}:build"

echo ">> Building ${LOCAL_REF} from ${CONTEXT}/Containerfile"
podman build --pull=always -t "${LOCAL_REF}" -f "${CONTEXT}/Containerfile" "${CONTEXT}"

# --- Smoke test: the bootc win is testing the OS as a container first ------
echo ">> Smoke test: bootc status + package presence inside the container"
podman run --rm "${LOCAL_REF}" bootc --version
podman run --rm "${LOCAL_REF}" rpm -q qemu-guest-agent >/dev/null \
  && echo "   baked packages present: OK"

# --- Resolve the release tag (arg overrides; else detect from the image) ---
RELEASE="${1:-${RELEASE:-}}"
if [ -z "${RELEASE}" ]; then
  RELEASE="$(podman run --rm "${LOCAL_REF}" sh -c '. /etc/os-release && printf "%s" "$VERSION_ID"')"
fi
if [ -z "${RELEASE}" ]; then
  echo "!! Could not determine AlmaLinux release (VERSION_ID) from the image." >&2
  exit 1
fi
MAJOR="${RELEASE%%.*}"   # 10.2 -> 10 (the floating tag hosts track)
echo ">> Release ${RELEASE} (floating major tag :${MAJOR})"

# Tag set: floating major, the release, an optional dated snapshot, plus EXTRA_TAGS.
# shellcheck disable=SC2206
TAGS=("${MAJOR}" "${RELEASE}")
[ -n "${DATE_STAMP:-}" ] && TAGS+=("${RELEASE}-${DATE_STAMP}")
TAGS+=(${EXTRA_TAGS:-})

# --- Confirm logged in, then push ------------------------------------------
if ! podman login --get-login "${REGISTRY}" >/dev/null 2>&1; then
  echo "!! Not logged in to ${REGISTRY}. Run:  podman login ${REGISTRY}" >&2
  exit 1
fi

for t in "${TAGS[@]}"; do
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
RELEASE_REF="${REGISTRY}/${ORG}/${PRODUCT}/${IMAGE}:${RELEASE}"
if [ "${SMOKE_PULL:-1}" != "0" ]; then
  echo ">> Pull-back smoke test: re-pulling ${RELEASE_REF} from the registry"
  podman rmi -f "${RELEASE_REF}" >/dev/null 2>&1 || true
  podman pull "${RELEASE_REF}"
  podman run --rm "${RELEASE_REF}" bootc --version
  podman run --rm "${RELEASE_REF}" rpm -q qemu-guest-agent >/dev/null \
    && echo "   pulled image OK: baked packages present"
fi

echo ">> Done. Image available at:"
for t in "${TAGS[@]}"; do
  echo "     ${REGISTRY}/${ORG}/${PRODUCT}/${IMAGE}:${t}"
done
echo "   The Image Mode host group pins :${MAJOR}; :${RELEASE} is the release, dated tags are snapshots."
