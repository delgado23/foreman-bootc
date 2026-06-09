# Raspberry Pi bootc support — findings (branch `raspberry-pi-bootc`)

Status: **investigation**. This documents step #1 — is the deploy lane viable? —
not a finished, wired-up build. Nothing here runs in the weekly Ascender job yet.

## TL;DR

Yes, the deploy lane is viable, but it is a **separate pipeline** from the x86
fleet's PXE → kickstart → Anaconda lane, and even from our own `build-push.sh`.
Two distinct outputs are needed:

1. **A container image** pushed to the Katello registry — this is what a running
   Pi pulls via `bootc upgrade`, exactly like the x86 hosts. Built from
   `Containerfile.rpi` (this branch).
2. **A one-time flashable disk image** (`.raw`) to do the *initial* bare-metal
   install onto a Pi. There is no PXE on these boards; you flash an SD/USB/M.2
   and boot. After first boot, day-2 updates come from the container in (1).

Both must be produced on/for **aarch64**.

## Base image

`quay.io/almalinuxorg/almalinux-bootc-rpi:10` (arm64-only, **experimental**).
It bakes in the Pi firmware, a Pi kernel (rebased on Raspberry Pi OS sources),
device-tree handling, and `rpi-bootc-bootloader` (the tool that copies bootloader
files onto the boot partition). Because the base handles firmware/boot, there is
**no UEFI-vs-native decision** — the Pi boots natively. Covers Pi 5/4/3/Zero 2 W.

Upstream: https://github.com/AlmaLinux/bootc-images-rpi

## Why `bootc-image-builder` alone isn't enough (the deploy-lane catch)

AlmaLinux flags this directly: *"firmware updating … bootc-image-builder alone
isn't enough to build a raw boot image."* Their CI
(`.github/actions/shared-steps/action.yml`) does this to make a flashable image —
this is the recipe we'd reproduce for our derived image:

1. Build our derived container (`Containerfile.rpi`).
2. (AlmaLinux uses a separate "bootstrap-image" layer to add cloud-init +
   growpart. We bake that into `Containerfile.rpi` directly, so we can skip the
   extra layer.)
3. Run `quay.io/centos-bootc/bootc-image-builder:latest`, **privileged**, with
   `bib-config.toml` (3 partitions: CIDATA/vfat→/boot/efi, boot/xfs→/boot,
   root/xfs→/), flags `--no-default-kernel-args --type raw --rootfs xfs --local`.
   → produces `disk.raw`.
4. **Post-process the raw image** (the part bib can't do), all needing
   `losetup`/loop devices + `sgdisk`/`sfdisk`/`fatlabel` on the host:
   - loop-mount, label partition 1 `CIDATA`, drop in NoCloud `user-data` +
     `meta-data` (this is where our Foreman/cloud-init first-boot config goes).
   - run the derived container privileged to mount the partitions and execute
     **`rpi-bootc-bootloader sync`** — copies `/usr/lib/ostree-boot/*` (Pi
     firmware/bootloader) onto the boot partition. **This is the missing piece
     bib doesn't handle.**
   → this is the **GPT** image (Pi 5/4).
5. The **FAT** image (older Pis) is the same raw with partition-1 type flipped
   to `0700`/`e` via `sgdisk`/`sfdisk`.
6. Flash `.raw` (or `.raw.xz`) to SD/USB/M.2.

Practical consequence: the image-build host must be **aarch64** and able to run
**privileged podman + loop devices**. AlmaLinux's CI runs it on `ubuntu-24.04-arm`.
This does not fit the current rootless `bootcbuild` flow on `nexus` without
changes.

## Files added on this branch

- `Containerfile.rpi` — derived image FROM the rpi base, mirroring `Containerfile`.
  The Katello RUN block is present but **blocked** (see below); comment it out to
  smoke-test the derive + flashable path today.
- `image/rpi/10-bootc-growpart.cfg` — points growpart at `/sysroot` for ostree.

## Blockers / open items (in rough order)

1. **Katello aarch64 content (biggest).** `Containerfile.rpi`'s install block
   registers to `'AlmaLinux 10 aarch64'` and pulls from
   `Garaventaville_aarch64_AlmaLinux_10_*` — those repos don't exist yet (all our
   AlmaLinux RPM content is x86_64). **Runbook: `RPI-KATELLO.md`** (product +
   repos + key, with helper scripts `foreman/ops/inspect_almalinux_content.rb`
   and `foreman/setup_aarch64_activation_key.rb`). Note duo_unix aarch64
   availability is unverified there.
2. **Build host.** aarch64 + privileged podman + loop devices. Decide: emulate on
   nexus vs a native arm64 builder. (Deferred earlier.)
3. **First-boot/registration model.** The x86 lane registers via kickstart
   `%post` + activation key. On the Pi that has to move into NoCloud `user-data`
   (the CIDATA partition) baked at flash time. Decide what goes in `user-data`
   vs baked in the image.
4. **Experimental base.** AlmaLinux's own caveat. Validate `bootc upgrade` works
   on a real Pi before committing. Watch SD/USB write endurance.
5. **Wiring into the weekly job** (`main.yml`, Ascender) — last, once 1–4 land.

## How to smoke-test the derive path right now (no Katello needed)

On an aarch64 host (or x86 with qemu-user-static + binfmt registered):

```bash
# comment out the KATELLO RUN block + the bootc-rhsm-facts timer enable first
podman build --platform linux/arm64 -f Containerfile.rpi -t almalinux10-bootc-rpi:test .
podman run --rm --platform linux/arm64 almalinux10-bootc-rpi:test bootc --version
```
