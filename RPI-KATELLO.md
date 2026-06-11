# Katello aarch64 content for the Raspberry Pi bootc image

The aarch64 RPM content `Containerfile.rpi` installs from **already exists in
Foreman** (built out separately, confirmed live 2026-06-09). This is a reference to
what's there and how the image wires to it — there is nothing to create.

Org is **Garaventaville** (id 4).

## What exists

| object | id | detail |
|--------|----|--------|
| Product `AlmaLinux 10 aarch64` | 30 | label `AlmaLinux_10_aarch64`, 49 repos |
| Content view `AlmaLinux 10 aarch64` | 21 | 7 repos, promoted to **Production** |
| Activation key `AlmaLinux 10 aarch64` | 11 | env Production, CV `AlmaLinux_10_aarch64` |

Repos in CV 21 (all `arch=aarch64`), content label
`Garaventaville_AlmaLinux_10_aarch64_AlmaLinux_10_-_<repo>`:

- **BaseOS, AppStream, CRB** — AlmaLinux core (aarch64).
- **EPEL** — htop/btop/atop/nmon/ocl-icd/git-credential-oauth **and `duo_unix`**
  (aarch64 `duo_unix` comes from EPEL, since Duo's own repo has no aarch64).
- **Foreman Client** — synced from the `el10/x86_64/` URL but tagged `arch=aarch64`;
  serves the **noarch** `katello-host-tools[-tracer]`.
- **RPI** — the AlmaLinux Raspberry Pi kernel/firmware repo.
- **PBS Client** — Proxmox Backup client (not used by this image).

## How the image consumes it

`Containerfile.rpi` registers with `--activationkey 'AlmaLinux 10 aarch64'`, which
resolves to CV `AlmaLinux_10_aarch64` @ Production — an **aarch64-only** view. So
arch separation is by **content view**, not by the content-label name. That's why
the build reuses the *same* `--enablerepo='Garaventaville_AlmaLinux_10_*'` glob as
the x86 `./Containerfile`: the consumer's CV only contains aarch64 repos, so the
glob can only match aarch64 content. The only Katello-facing difference between the
two Containerfiles is the activation key (and the base image).

This mirrors the x86 setup exactly: key `AlmaLinux 10` (id 13) → CV `AlmaLinux_10`
@ Production. Two parallel per-arch CVs/keys, same Containerfile pattern.

## Verify (read-only)

```bash
# the x86 side, for comparison / drift:
sudo foreman-rake console < foreman/ops/inspect_almalinux_content.rb

# the aarch64 key resolves to the aarch64 CV @ Production:
hammer activation-key info --organization Garaventaville --name "AlmaLinux 10 aarch64"
# a repo carries packages:
hammer repository info --organization Garaventaville \
  --product "AlmaLinux 10 aarch64" --name "AlmaLinux 10 - BaseOS"   # Packages: > 0
```

## Notes

- **Nothing blocks the build on the Katello side.** `Containerfile.rpi`'s package
  set is fully satisfiable from CV 21. The remaining work is the build host + the
  flashable-image pipeline (see `RPI.md`).
- **`duo_unix` source differs from x86.** x86 pulls it from Duo's official repo;
  aarch64 pulls EPEL's community `duo_unix`. Same package, different maintainer —
  fine, but worth knowing if MFA behaviour ever diverges.
- If CV 21 needs refreshing to pick up newly-synced RPMs, it must be republished +
  promoted to Production (the weekly job handles the x86 CV similarly). Confirm the
  aarch64 CV is on a refresh cadence before relying on package freshness.
