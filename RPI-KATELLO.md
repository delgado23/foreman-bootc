# Katello aarch64 content + activation key (Raspberry Pi bootc)

This is blocker #1 from `RPI.md`: the Pi image (`Containerfile.rpi`) installs its
package set from Katello-synced repos with public mirrors disabled, exactly like
the x86 image — but all our AlmaLinux RPM content is **x86_64 only**. This is the
runbook to add the aarch64 side. It is Foreman/Katello-side work; nothing here
lives in this repo's build except the two helper scripts noted below.

Org is **Garaventaville** (id 4). The existing x86 content lives in a product
labelled **`AlmaLinux_10`**, and the build enables `Garaventaville_AlmaLinux_10_*`.

## The model (why two arches don't collide)

The build registers transiently, then runs:

```
dnf --disablerepo='*' --enablerepo='Garaventaville_<glob>_*' upgrade/install
```

The repo IDs in `redhat.repo` are Katello **content labels**:
`<org label>_<product label>_<repo label>`. Under Simple Content Access, a key
bound to Library + the Default Organization View exposes *all* synced Library
content, so the `--enablerepo` glob is what actually selects the repos — not the
key.

That means if we named the aarch64 product `AlmaLinux_10_aarch64`, its content
labels would be `Garaventaville_AlmaLinux_10_aarch64_*` — which **still matches
the x86 glob `Garaventaville_AlmaLinux_10_*`**. An x86 build would then pull
aarch64 repo metadata too. Harmless (dnf ignores wrong-arch RPMs) but messy and
slower.

**Decision: lead the product label with the arch** so the two globs are disjoint:

| arch    | product label          | content-label glob the build enables          |
|---------|------------------------|-----------------------------------------------|
| x86_64  | `AlmaLinux_10`         | `Garaventaville_AlmaLinux_10_*`                |
| aarch64 | `aarch64_AlmaLinux_10` | `Garaventaville_aarch64_AlmaLinux_10_*`        |

`Containerfile.rpi` already uses the aarch64 glob. The x86 `Containerfile` is
untouched, and its glob can never match the new repos.

## Step 0 — dump the x86 setup to mirror it

```
sudo foreman-rake console < foreman/ops/inspect_almalinux_content.rb
```

This prints the `AlmaLinux_10` product's repos (name, label, URL, download
policy, GPG key) plus the env/CV the `AlmaLinux 10` key uses. Recreate each repo
for aarch64 with the **same repo label** (so only the product prefix differs) and
the **same GPG key**, substituting `aarch64` in the URL.

## Step 1 — product + repos (hammer)

These are the **actual** x86 repos `Containerfile.rpi`'s install list draws from,
read live from Foreman (`inspect_almalinux_content.rb`, 2026-06-09), with the URL
switched to aarch64 and the existing content-credential reused by name. The x86
product has more repos (Docker, Weewx, MySQL, Nvidia, Kubernetes) — those are NOT
needed for the base Pi image, so they're omitted. `raspberrypi` is aarch64-only
(no x86 sibling). All x86 repos use download policy `immediate`; mirrored here.

```bash
ORG=Garaventaville

hammer product create --organization "$ORG" \
  --name "AlmaLinux 10 aarch64" --label aarch64_AlmaLinux_10

# name|url|content-credential  (empty credential => omit --gpg-key, as on x86)
REPOS=(
  "AlmaLinux 10 - BaseOS|https://repo.almalinux.org/almalinux/10/BaseOS/aarch64/os/|"
  "AlmaLinux 10 - AppStream|https://repo.almalinux.org/almalinux/10/AppStream/aarch64/os/|AlmaLinux 10"
  "AlmaLinux 10 - CRB|https://repo.almalinux.org/almalinux/10/CRB/aarch64/os/|AlmaLinux 10"
  "AlmaLinux 10 - raspberrypi|https://repo.almalinux.org/almalinux/10/raspberrypi/aarch64/os/|AlmaLinux 10"
  "AlmaLinux 10 - EPEL|https://dl.fedoraproject.org/pub/epel/10/Everything/aarch64/|Extra Packages for Enterprise Linux 10"
)
# NOT included (no aarch64 builds exist — confirmed 2026-06-09, see below):
#   Duo            https://pkg.duosecurity.com/RedHat/10/aarch64           -> 404
#   Foreman Client https://yum.theforeman.org/client/latest/el10/aarch64   -> 404
for r in "${REPOS[@]}"; do
  IFS='|' read -r name url gpg <<<"$r"
  hammer repository create --organization "$ORG" \
    --product "AlmaLinux 10 aarch64" \
    --name "$name" --content-type yum --url "$url" \
    --download-policy immediate \
    ${gpg:+--gpg-key "$gpg"}
done
```

Repo labels auto-derive from the names (e.g. `AlmaLinux_10_-_BaseOS`), so content
labels become `Garaventaville_aarch64_AlmaLinux_10_AlmaLinux_10_-_BaseOS` — caught
by the build's `Garaventaville_aarch64_AlmaLinux_10_*` glob, never by the x86 glob.

Availability checked live 2026-06-09 (HEAD on `…/repodata/repomd.xml`):

- **Available (200):** BaseOS, AppStream, CRB, EPEL, and `raspberrypi` aarch64.
- **`raspberrypi`** — AlmaLinux Pi kernel/firmware (aarch64-only). Sync it so a
  rebuilt Pi image can `dnf upgrade` the kernel to the synced level; without it the
  image carries whatever Pi kernel the `almalinux-bootc-rpi` base shipped.
- **Duo — NO aarch64 (404).** `…/RedHat/10/aarch64` does not exist (x86_64 does).
  `duo_unix` is dropped from `Containerfile.rpi`. **Pi host MFA is an open item.**
- **Foreman Client — NO el10 aarch64 (404).** `client/latest/el10/` lists only
  `x86_64/` + `source/`. So `katello-host-tools` / `katello-host-tools-tracer` are
  unavailable on aarch64 and are dropped from `Containerfile.rpi`. Impact is small
  for an image-mode host: tracer (RPM "needs-restart") is meaningless on a
  read-only ostree root that updates via bootc reboot, and image-mode reporting to
  Katello is already handled by our own `image/bootc-rhsm-facts`. The only real
  loss is package-profile / enabled-repo upload. **Open item** if we want that back
  (would need a Foreman aarch64 client build, or building the RPMs ourselves).

Then sync (slow; downloads metadata/packages):

```bash
hammer product synchronize --organization "$ORG" --name "AlmaLinux 10 aarch64"
# or per-repo: hammer repository synchronize --organization "$ORG" \
#   --product "AlmaLinux 10 aarch64" --name BaseOS
```

## Step 2 — activation key

```
sudo foreman-rake console < foreman/setup_aarch64_activation_key.rb
```

Creates **`AlmaLinux 10 aarch64`** bound to Library + Default Organization View
(idempotent). The script also reports whether the aarch64 product is synced yet.
(Equivalent hammer: `hammer activation-key create --organization "$ORG" --name
"AlmaLinux 10 aarch64" --lifecycle-environment Library --content-view "Default
Organization View" --unlimited-hosts`.)

**This deliberately does NOT mirror the x86 key.** The inspector shows
`AlmaLinux 10` is bound to a *custom* CV (`AlmaLinux_10`) promoted to
**Production**, with per-repo content overrides enabling each repo. We skip all of
that for aarch64 on purpose:

- **Default Org View + Library** auto-exposes every synced repo with no CV
  publish/promote step — repos are usable the moment the sync finishes. A custom
  CV would need republishing on every weekly sync to pick up updates.
- **No content overrides needed** — the build does `--disablerepo='*'
  --enablerepo='Garaventaville_aarch64_AlmaLinux_10_*'`, which force-enables
  regardless of the override default. (The x86 overrides set BaseOS/AppStream/…=1
  and MySQL=0, but that only changes the *default* enabled state.)
- **No gating is lost.** The x86 CV exists to gate content; here the gated artifact
  is the bootc *image* (the `bootc` CV → Production path, see `RPI.md`), not the
  upstream RPM feed. Gating the RPM feed too would be redundant.

Trade-off: under Default Org View the aarch64 consumer also sees the x86 repos in
`redhat.repo` — harmless, because the arch-led glob never enables them.

## Step 3 — verify, then unblock the build

```bash
# the key resolves and sees the repos:
hammer activation-key info --organization "$ORG" --name "AlmaLinux 10 aarch64"
# repos carry packages:
hammer repository info --organization "$ORG" \
  --product "AlmaLinux 10 aarch64" --name BaseOS   # Packages: > 0
```

Once those pass, the Katello RUN block in `Containerfile.rpi` is unblocked: it
registers with `AlmaLinux 10 aarch64` and installs from
`Garaventaville_aarch64_AlmaLinux_10_*`. Build it on an aarch64 host (build-host
decision still open — see `RPI.md`).

## Notes / open items

- **RPM content only.** This unblocks the Pi *container* build. It does NOT touch
  the bootc image content-view gating (the `bootc` CV / Library→Production
  promotion) or the flashable-image pipeline — those are separate (`RPI.md`).
- **Day-2 updates** to deployed Pis still come from the container image via
  `bootc upgrade`, not from these RPM repos directly. The RPM repos only feed the
  image build.
- If you'd rather the aarch64 key mirror the exact env/CV of the x86 key instead
  of Default Org View (e.g. the x86 key uses a restricted CV), point the aarch64
  key at the same CV and add the aarch64 product's repos to it. The script header
  notes this.
