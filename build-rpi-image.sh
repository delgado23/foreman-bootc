#!/usr/bin/env bash
#
# build-rpi-image.sh — turn the almalinux10-bootc-rpi container into a flashable
# Raspberry Pi disk image (GPT .raw, for Pi 4/5).
#
# bootc-image-builder alone can't produce a bootable Pi image (the Pi bootloader
# isn't laid down), so this mirrors AlmaLinux's bootc-images-rpi pipeline:
#   1. bootc-image-builder -> output/image/disk.raw   (3 parts per bib-config.toml)
#   2. loop-mount it; write the cloud-init NoCloud seed (user-data/meta-data/
#      README.txt) onto the CIDATA partition
#   3. run `rpi-bootc-bootloader sync` from inside the image to lay down the Pi
#      firmware/bootloader onto the boot partitions
#   4. emit a flashable GPT .raw (optionally xz-compressed with COMPRESS=1)
#
# MUST run rootful on an aarch64 host (needs loop devices + privileged podman):
#   sudo ./build-rpi-image.sh
# Designated builder: cthun.garaventaville.com (native Pi 4).
#
# The image comes from root's podman storage. If it isn't there yet, the script
# loads it from the rootless build (podman save | podman load) or, failing that,
# pulls IMAGE_REF — so either build it first with build-push.sh, or set
# IMAGE_REF to a registry ref the root user can pull.
set -euo pipefail

# --- Config (override via environment) -------------------------------------
REGISTRY="${REGISTRY:-foreman.garaventaville.com}"
IMAGE_REF="${IMAGE_REF:-${REGISTRY}/garaventaville/bootc/almalinux10-bootc-rpi:10}"
BIB="${BIB:-quay.io/centos-bootc/bootc-image-builder:latest}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-${HERE}/image/rpi/bib-config.toml}"
SEED_DIR="${SEED_DIR:-${HERE}/image/rpi}"        # holds user-data/meta-data/README.txt
OUTDIR="${OUTDIR:-${HERE}/output}"
OUT_RAW="${OUT_RAW:-${OUTDIR}/almalinux10-bootc-rpi.raw}"
ROOTLESS_USER="${ROOTLESS_USER:-${SUDO_USER:-}}" # whose rootless store to import from

if [ "$(id -u)" -ne 0 ]; then
  echo "!! Must run as root (loop devices + privileged podman). Use: sudo $0" >&2
  exit 1
fi
if [ "$(uname -m)" != "aarch64" ]; then
  echo "!! This produces an aarch64 Pi image and must run on an aarch64 host." >&2
  exit 1
fi
# fatlabel comes from dosfstools; losetup/mount/udevadm from util-linux/systemd.
missing=""
for c in podman losetup fatlabel mount udevadm; do command -v "$c" >/dev/null || missing="${missing} $c"; done
if [ -n "${missing}" ]; then
  echo "!! Missing required commands:${missing}" >&2
  echo "   Install with:  sudo dnf install -y podman dosfstools util-linux" >&2
  exit 1
fi

cleanup() {
  set +e
  [ -n "${MNT:-}" ] && mountpoint -q "${MNT}" && umount "${MNT}"
  [ -n "${LOOP:-}" ] && losetup -d "${LOOP}" 2>/dev/null
  [ -n "${MNT:-}" ] && rmdir "${MNT}" 2>/dev/null
}
trap cleanup EXIT

# --- 0. Make sure the image is in root's podman store ----------------------
if ! podman image exists "${IMAGE_REF}"; then
  echo ">> ${IMAGE_REF} not in root's store"
  if [ -n "${ROOTLESS_USER}" ] && sudo -u "${ROOTLESS_USER}" podman image exists "${IMAGE_REF}" 2>/dev/null; then
    echo ">> importing it from ${ROOTLESS_USER}'s rootless store"
    sudo -u "${ROOTLESS_USER}" podman save "${IMAGE_REF}" | podman load
  else
    echo ">> pulling ${IMAGE_REF}"
    podman pull "${IMAGE_REF}"
  fi
fi

# --- 1. bootc-image-builder -> disk.raw ------------------------------------
# REUSE_RAW=1 skips the (slow) bib build and reuses an existing disk.raw — handy
# when iterating on the post-processing below.
mkdir -p "${OUTDIR}"
if [ "${REUSE_RAW:-0}" = "1" ] && [ -f "${OUTDIR}/image/disk.raw" ]; then
  echo ">> REUSE_RAW=1: reusing ${OUTDIR}/image/disk.raw (skipping bootc-image-builder)"
else
  cp "${CONFIG}" "${OUTDIR}/bib-config.toml"
  echo ">> bootc-image-builder: ${IMAGE_REF} -> raw"
  podman run --rm -i --privileged --security-opt label=type:unconfined_t \
    -v "${OUTDIR}":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BIB}" \
    --no-default-kernel-args \
    --config /output/bib-config.toml \
    --type raw --rootfs xfs --local \
    "${IMAGE_REF}"
fi
[ -f "${OUTDIR}/image/disk.raw" ] || { echo "!! bib did not produce image/disk.raw" >&2; exit 1; }
cp "${OUTDIR}/image/disk.raw" "${OUT_RAW}"

# --- 2. seed cloud-init NoCloud onto the CIDATA (p1) partition --------------
echo ">> Seeding cloud-init NoCloud on the CIDATA partition"
LOOP="$(losetup -f --show -P "${OUT_RAW}")"
# Wait for the kernel to create the partition device nodes (loopNp1...).
for _ in 1 2 3 4 5; do [ -e "${LOOP}p1" ] && break; udevadm settle 2>/dev/null || true; sleep 1; done
[ -e "${LOOP}p1" ] || { echo "!! ${LOOP}p1 never appeared after losetup -P" >&2; exit 1; }
MNT="$(mktemp -d)"
fatlabel "${LOOP}p1" CIDATA
mount "${LOOP}p1" "${MNT}"
cp "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" "${MNT}/"
[ -f "${SEED_DIR}/network-config" ] && cp "${SEED_DIR}/network-config" "${MNT}/"
[ -f "${SEED_DIR}/README.txt" ] && cp "${SEED_DIR}/README.txt" "${MNT}/"
umount "${MNT}"

# --- 3. lay down the Pi bootloader (the bit bib can't do) -------------------
# Run inside the image: mount the raw's root (p3) and boot (p2), copy the ostree
# boot payload onto the boot/efi partition, then rpi-bootc-bootloader sync.
echo ">> rpi-bootc-bootloader sync (laying down the Pi bootloader)"
mount "${LOOP}p1" "${MNT}"
podman run --rm -i --privileged --security-opt label=type:unconfined_t \
  -v /dev:/dev -v "${MNT}":/tmp \
  --entrypoint /bin/bash "${IMAGE_REF}" -c "
    set -e
    mount ${LOOP}p3 /sysroot
    mount ${LOOP}p2 /boot
    rpi-bootc-bootloader version
    cp -a --no-preserve=links /usr/lib/ostree-boot/* /tmp/ 2>/dev/null || true
    rpi-bootc-bootloader sync
  "
umount "${MNT}"
losetup -d "${LOOP}"; LOOP=""
rmdir "${MNT}"; MNT=""

# --- 4. done (optional compression) ----------------------------------------
if [ "${COMPRESS:-0}" = "1" ]; then
  echo ">> Compressing ${OUT_RAW} -> ${OUT_RAW}.xz"
  xz -T0 -f "${OUT_RAW}"
  OUT_RAW="${OUT_RAW}.xz"
fi

echo ">> Done. Flashable GPT image: ${OUT_RAW}"
echo "   Flash with:  sudo dd if=${OUT_RAW%.xz} of=/dev/sdX bs=4M status=progress conv=fsync"
echo "   (or pipe through 'xzcat' first if compressed). Pi 4/5 only."
