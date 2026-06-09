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

Create the arch-led product, then a repo per entry the inspector listed. Canonical
AlmaLinux 10 aarch64 URLs (confirm against the inspector output — your x86 set may
differ):

```bash
ORG=Garaventaville

hammer product create --organization "$ORG" \
  --name "AlmaLinux 10 aarch64" --label aarch64_AlmaLinux_10

# repo label MUST match the x86 sibling's label; only the product prefix changes.
for r in \
  "BaseOS|https://repo.almalinux.org/almalinux/10/BaseOS/aarch64/os/|RPM-GPG-KEY-AlmaLinux-10" \
  "AppStream|https://repo.almalinux.org/almalinux/10/AppStream/aarch64/os/|RPM-GPG-KEY-AlmaLinux-10" \
  "CRB|https://repo.almalinux.org/almalinux/10/CRB/aarch64/os/|RPM-GPG-KEY-AlmaLinux-10" \
  "raspberrypi|https://repo.almalinux.org/almalinux/10/raspberrypi/aarch64/os/|RPM-GPG-KEY-AlmaLinux-10" \
  "EPEL|https://dl.fedoraproject.org/pub/epel/10/Everything/aarch64/|RPM-GPG-KEY-EPEL-10" \
  "Foreman_client|https://yum.theforeman.org/client/<VER>/el10/aarch64/|RPM-GPG-KEY-foreman" \
; do
  IFS='|' read -r label url gpg <<<"$r"
  hammer repository create --organization "$ORG" \
    --product "AlmaLinux 10 aarch64" \
    --name "$label" --label "$label" \
    --content-type yum --url "$url" \
    --download-policy on_demand \
    --gpg-key "$gpg"
done
```

Repos to confirm before relying on them (these are why this is a runbook, not a
one-shot):

- **`raspberrypi`** — the AlmaLinux Pi kernel/firmware repo. Sync it so a rebuilt
  Pi image can `dnf upgrade` the kernel to the synced level (same freshness
  guarantee the x86 image gets). Without it the image only carries whatever Pi
  kernel the `almalinux-bootc-rpi` base shipped.
- **`Foreman_client`** — set `<VER>` to the same Foreman client version the x86
  `Foreman_client` repo uses (from the inspector). Provides `katello-host-tools*`.
- **`EPEL`** — provides `htop`/`btop`/`nmon`/`ocl-icd`. Confirm each is built for
  aarch64 (most are).
- **`Duo`** (`duo_unix`) — Duo's RHEL repo aarch64 coverage is **not guaranteed**.
  If there is no aarch64 `duo_unix`, drop it from `Containerfile.rpi`'s install
  list (Pi MFA story is then an open item, not a blocker).

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
(idempotent). No per-repo content overrides are needed — the build force-enables
repos via `--enablerepo`, just like the x86 key. The script also reports whether
the aarch64 product is synced yet. (Equivalent hammer: `hammer activation-key
create --organization "$ORG" --name "AlmaLinux 10 aarch64" --lifecycle-environment
Library --content-view "Default Organization View" --unlimited-hosts`.)

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
