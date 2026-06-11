#!/usr/bin/env bash
#
# build-push.sh — build an AlmaLinux bootc image and push it into the Katello
# internal registry on foreman.garaventaville.com.
#
# Usage:
#   ./build-push.sh [RELEASE]
#   RELEASE is the AlmaLinux point release used as the image tag (e.g. "10.2").
#   If omitted it is auto-detected from the built image's /etc/os-release
#   VERSION_ID, so the tag FOLLOWS the upstream release without manual edits.
#
# Which image to build is set by env vars (so one script serves every variant):
#   CONTAINERFILE  Containerfile to build      (default: <CONTEXT>/Containerfile)
#   IMAGE          pushed image name           (default: almalinux10-bootc)
#   SMOKE_PKG      package whose presence the smoke test asserts is baked in
#                  (default: qemu-guest-agent — pick one the image actually installs)
#   PLATFORM       podman --platform value     (default: unset = host arch)
# e.g. the Raspberry Pi (aarch64) image, built natively on an arm64 host:
#   CONTAINERFILE=Containerfile.rpi IMAGE=almalinux10-bootc-rpi \
#     SMOKE_PKG=cloud-init ./build-push.sh
#
# Each run publishes three tags so hosts auto-follow point releases while
# snapshots stay pinnable:
#   :<major>            floating (e.g. :10) — what the Image Mode host group pins;
#                       always the latest gated release
#   :<release>          e.g. :10.2 — the point release, refreshed in place
#   :<release>-<date>   immutable weekly snapshot, when DATE_STAMP is set
# plus anything in EXTRA_TAGS (space-separated) for ad-hoc tags.
# Override REGISTRY/ORG/PRODUCT via env vars too.
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
CONTAINERFILE="${CONTAINERFILE:-${CONTEXT}/Containerfile}"
SMOKE_PKG="${SMOKE_PKG:-qemu-guest-agent}"

# Build to a working local tag — the release tag isn't known until the image
# exists (we read it from the built image below).
LOCAL_REF="${IMAGE}:build"

echo ">> Building ${LOCAL_REF} from ${CONTAINERFILE}"
# --pull=always   : always re-pull the bootc base, so a rebased AlmaLinux base
#                   (kernel/firmware/core updates) is picked up every build.
# --no-cache      : do NOT reuse buildah's layer cache. The `dnf upgrade`/install
#                   layer is keyed on instruction text + parent layers, so when
#                   the base digest and Containerfile are unchanged buildah would
#                   reuse it and NEVER re-query Katello — silently baking stale
#                   RPMs. This is a weekly job on a native host, so we eat the
#                   full rebuild to guarantee every run pulls the latest OS
#                   updates Katello has synced. (See gate 3: the aarch64 repos
#                   must be synced + the CV published for new RPMs to be visible.)
podman build --pull=always --no-cache ${PLATFORM:+--platform "${PLATFORM}"} \
  -t "${LOCAL_REF}" -f "${CONTAINERFILE}" "${CONTEXT}"

# --- Smoke test: the bootc win is testing the OS as a container first ------
echo ">> Smoke test: bootc status + presence of ${SMOKE_PKG} inside the container"
podman run --rm "${LOCAL_REF}" bootc --version
podman run --rm "${LOCAL_REF}" rpm -q "${SMOKE_PKG}" >/dev/null \
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
  podman run --rm "${RELEASE_REF}" rpm -q "${SMOKE_PKG}" >/dev/null \
    && echo "   pulled image OK: baked packages present"
fi

echo ">> Done. Image available at:"
for t in "${TAGS[@]}"; do
  echo "     ${REGISTRY}/${ORG}/${PRODUCT}/${IMAGE}:${t}"
done
echo "   The Image Mode host group pins :${MAJOR}; :${RELEASE} is the release, dated tags are snapshots."
