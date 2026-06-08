# foreman-bootc

Provisioning and managing **AlmaLinux 10 image-mode (bootc)** hosts with
Foreman/Katello at `https://foreman.garaventaville.com`
(Foreman 3.18.1 / Katello 4.20.1).

Image-mode hosts boot from an OCI **bootc** container image instead of a
package install. Foreman provisions them with Anaconda's `ostreecontainer`
command and then manages them (booted/staged/rollback status, `bootc
upgrade`/`switch`/`rollback` via remote execution).

## Layout

```
Containerfile            AlmaLinux 10 bootc image (FROM quay.io/almalinuxorg/almalinux-bootc:10)
build-push.sh            build -> smoke-test -> push to the Katello registry
prune.sh                 reclaim disk on the build host after a build
build-push-k8s.sh        build+push the 3 Kubernetes images (common/controlplane/worker)
kubernetes/
  common/Containerfile        FROM almalinux10-bootc: containerd + kubelet/kubeadm/kubectl (pinned)
  controlplane/Containerfile  FROM kubernetes-common: + keepalived, haproxy
  worker/Containerfile        FROM kubernetes-common: + lvm2, gdisk, iscsi
  files/                      baked node config (containerd cfg, k8s modules/sysctl)
templates/
  kickstart_almalinux10_bootc.erb   provision template: ostreecontainer install
  pxegrub2_almalinux10_bootc.erb    UEFI boot entry: supplies inst.stage2
foreman/
  create_product.rb      create the Katello "bootc" product (correct, via dynflow)
  setup_content_view.rb  create the gated "bootc" content view, publish + promote
  set_unauth_pull.rb     move anonymous pull from Library (staging) to Production
  load_templates.rb      load both templates into Foreman + set as OS defaults
  ops/                   one-off recovery/inspection scripts (incident reference)
                         (incl. inspect_content_view.rb — read-only CV/path report)
main.yml                 Ansible playbook: weekly build/test/push of all images
vars/vault.yml           registry + Foreman API creds for the weekly build (Vault, encrypted)
ascender/
  setup_weekly_builds.py idempotent Ascender API setup (project + JT + schedule)
```

## Build host

Built on **nexus.garaventaville.com** as the rootless user `bootcbuild`
(`sudo -iu bootcbuild`, files in `~/build`). The build host `/` is small
(~14 GB free) — run `prune.sh` after pushes.

## Workflow

```bash
# on nexus, as bootcbuild, in ~/build
podman login foreman.garaventaville.com
./build-push.sh           # detects the AlmaLinux release (e.g. 10.2) from the image and pushes
                          #   :10  (floating — what hosts pin)  :10.2  (release)
./prune.sh
```

The base image tag **follows the AlmaLinux release**: `build-push.sh` reads
`VERSION_ID` from the built image and tags `:<release>` (e.g. `10.2`) plus the
floating `:<major>` (`10`). The `AlmaLinux 10/Image Mode` host group pins `:10`,
so hosts auto-follow the newest gated point release. Pass a release explicitly to
override the detection: `./build-push.sh 10.2`.

`build-push.sh` pushes into the **Library** environment and (with `SMOKE_PULL=1`,
the default) re-pulls the image and re-checks it. Library is private staging; the
image becomes installable only once promoted to **Production** (the weekly build
does this on a passing smoke test — see below).

To build a host, put it in the `AlmaLinux 10/Image Mode` host group — it sets the
`ostreecontainer` param for you, pointed at the **Production** content-view path
(set by `foreman/setup_image_mode_hostgroup.rb`, which resolves the promoted path
from Katello). Don't set `ostreecontainer` to the raw `…/garaventaville/bootc/…`
Library path by hand; that bypasses the gate.

## Kubernetes node images

Three images layer the Kubernetes node software on top of the base, so CP/worker
nodes boot pre-built instead of being assembled at runtime by the
`kubernetes-cluster-provisioning` Ansible playbook (that playbook detects
image-mode via `/run/ostree-booted` and skips the now-baked package installs).

```
almalinux10-bootc:10.0
  └── kubernetes-common:1.35.5        containerd + config, kubelet/kubeadm/kubectl
                                       (PINNED NVR), cri-tools, firewalld, k8s
                                       modules/sysctl, iptables firewall backend
        ├── kubernetes-controlplane:1.35.5   + keepalived, haproxy
        └── kubernetes-worker:1.35.5         + lvm2, gdisk, iscsi (iscsid enabled)
```

The **tag is the Kubernetes version** — image-mode is the version pin. To upgrade
k8s, bump `K8S_VERSION` in `kubernetes/common/Containerfile`, rebuild with the
new tag, and point the host-group `ostreecontainer` params at it.

```bash
# on nexus, as bootcbuild, in the repo checkout
podman login foreman.garaventaville.com
./build-push-k8s.sh 1.35.5
# -> foreman.garaventaville.com/garaventaville/bootc/kubernetes-common:1.35.5
#    foreman.garaventaville.com/garaventaville/bootc/kubernetes-controlplane:1.35.5
#    foreman.garaventaville.com/garaventaville/bootc/kubernetes-worker:1.35.5
```

The Kubernetes host groups (`AlmaLinux 10/Kubernetes Controlplane Node` id 29,
`… Worker Node` id 30) are converted to image-mode in place: each gets
`ostreecontainer` (the controlplane/worker image), `ansible_pkg_mgr=dnf`,
`remote_execution_ssh_user=root`, and the bootc template combinations — same
toggle as the `Image Mode` group below, but bound to the existing k8s groups so
the Ansible inventory group names are unchanged. They keep the
`AlmaLinux 10 Kubernetes` activation key.

## Weekly automated builds (Ascender)

All four images are rebuilt, smoke-tested, and pushed once a week by Ascender
(`https://ascender.garaventaville.com`) so they pick up upstream security/package
updates under their pinned tags. The job runs `main.yml` against
`nexus.garaventaville.com`, becoming the rootless `bootcbuild` user and reusing the
same `build-push.sh` / `build-push-k8s.sh` scripts (which build → push to Library →
re-pull from the registry and re-check).

**The promotion gate:** each script pushes to **Library** (private staging) and
then pull-back-smoke-tests the pushed image. Only if every smoke test passes does
the final `main.yml` play publish the `bootc` content view and **promote it to
Production** (via the `theforeman.foreman` collection). Ansible aborts the run on
the first failed task, so a failed smoke test stops everything *before* promotion
and Production keeps its prior good version. Production is what hosts install from.

Each run publishes a refreshed pinned tag plus an immutable dated snapshot. For
the **base image** that is three tags: the floating `:10` (what hosts pin), the
detected release `:10.2`, and the snapshot `:10.2-20260607`. For the **k8s
images** it is the two tags `:1.35.5` and `:1.35.5-20260607` (the tag is the
Kubernetes version — see below). `build-push.sh` honors `DATE_STAMP` for the
dated snapshot; both scripts honor `EXTRA_TAGS="<tag> [tag...]"` for ad-hoc tags.

```
main.yml                target nexus, sudo -> bootcbuild, git pull, login,
                        ./build-push.sh 10.0  +  ./build-push-k8s.sh 1.35.5
vars/vault.yml          registry_username / registry_password (ansible-vault)
ascender/setup_weekly_builds.py   creates the Ascender objects via the API
```

**One-time setup**

1. **Registry + Foreman creds** — `cp vars/vault.yml.example vars/vault.yml`, fill
   in the Katello registry user/password **and** the Foreman API user/password
   (`foreman_username`/`foreman_password`/`foreman_hostname`, used by the
   publish/promote play; the user needs content-view publish + promote rights),
   then `ansible-vault encrypt vars/vault.yml` using the password of the Vault
   credential the job will attach (`linux provisiong` by default). Commit the
   encrypted file. The Ascender execution environment must have the
   `theforeman.foreman` collection (the `foreman-content-views` job already uses it).
2. **Build host** — ensure the Ascender machine credential (`Ansible User`) can
   `sudo` to `bootcbuild` on nexus, and lingering is on so rootless podman has a
   runtime dir: `loginctl enable-linger bootcbuild`.
3. **Create the Ascender objects** — project (`foreman-bootc`), job template
   (`Build bootc Images Weekly`), and a weekly schedule (Sundays 03:00 ET):

   ```bash
   export ASCENDER_TOKEN=...                 # a token, never committed
   ./ascender/setup_weekly_builds.py --dry-run   # resolve deps, print the plan
   ./ascender/setup_weekly_builds.py             # create/update (idempotent)
   ```

   Re-running is safe (find-or-create + PATCH). Override cadence with
   `--weekday/--hour/--minute/--timezone`, or the Vault credential with
   `--vault-credential`.

## Content-view gating (one-time Foreman setup)

The `bootc` content view (Library → Production) and the move of anonymous pull to
Production are set up once, in this order, to avoid an install outage (each step
runs on Foreman: `sudo foreman-rake console < foreman/<script>.rb`):

1. **Confirm + inspect** — `foreman/ops/inspect_content_view.rb` (read-only):
   verify the bootc push repos are CV-eligible on this Katello build and capture
   the Production lifecycle-environment label/id.
2. **Create the CV** — `foreman/setup_content_view.rb`: creates the `bootc` CV,
   adds the four push repos, publishes a version, and promotes it to Production.
   It prints the promoted pull paths.
3. **Enable Production pull** — `foreman/set_unauth_pull.rb`: enables anonymous
   pull on Production. It leaves Library pullable for now (it only locks Library
   down once the host-group refs point at Production — see step 5), so in-flight
   provisions don't break.
4. **Repoint refs** — `setup_image_mode_hostgroup.rb` and
   `setup_kubernetes_image_mode.rb` resolve the Production path from Katello and
   update the host-group `ostreecontainer` params. **Provision one test bootc
   host** and confirm `%pre` pulls anonymously from the Production path.
5. **Lock down Library** — re-run `foreman/set_unauth_pull.rb`. Now that the refs
   point at Production it sets Library `unauth_pull=false`. (The script is
   self-sequencing on the Image Mode host group's `ostreecontainer` value, so the
   order is enforced — no env flags, which `foreman-rake` would strip anyway.)

From then on the weekly Ascender build keeps Production current behind the smoke
gate.

## Switching between image-mode (bootc) and RPM hosts

Foreman picks provisioning templates by precedence (most specific wins):
1. **Template Combination** — binds a template to a host group (± environment)
2. **OS default template** — the per-OS fallback

There is no per-host template dropdown, so **the host group is the toggle**:

- **RPM (default):** any normal AlmaLinux 10 host group → stock `Kickstart
  default` / `Kickstart default PXEGrub2` (the OS default).
- **bootc (opt-in):** put the host in host group **`AlmaLinux 10/Image Mode`**
  (id 31). Template combinations there select the bootc Kickstart + PXEGrub2,
  and the group sets `ostreecontainer`, `ansible_pkg_mgr=dnf`,
  `kt_activation_keys`.

So building a bootc host = choose the `Image Mode` host group; building an RPM
host = choose any other group (or none). Set up by
`foreman/setup_image_mode_hostgroup.rb`. NOTE: don't set the bootc templates as
the OS *default* — that forces bootc on every AlmaLinux 10 host (incl. existing
RPM/Kubernetes groups that rely on the default).

## bootc hosts can't be configured via %post — bake it into the image

On a bootc/ostree host `/root -> var/roothome` and `/home -> var/home`, and
`/var` is initialized separately at first boot. So anything Anaconda's `%post`
writes under `/var` (e.g. the `remote_execution_ssh_keys` snippet putting the
rex key in `/root/.ssh`) is **lost** on first boot. Image-mode config must live
in the image:

- **Management SSH (root):** the Foreman rex pubkey **and** the Ascender/AWX
  "Global Root" pubkey are baked to `/usr/share/foreman-rex/root.keys` with an
  sshd `AuthorizedKeysFile` drop-in (see `image/foreman-rex.root.keys`), so both
  systems can SSH in as root from first boot. The `AlmaLinux 10/Image Mode` host
  group sets `remote_execution_ssh_user=root` (rex's global user is `ansible`,
  which we don't bake); Ascender's machine credential is already `root`. Add any
  other management system's key to that file and `bootc upgrade`.
- **Image-mode facts:** AlmaLinux's subscription-manager has no bootc fact
  collector, so `image/bootc-rhsm-facts` (a systemd timer) writes
  `bootc.booted.image` etc. to `/etc/rhsm/facts/bootc.facts` on boot + every
  30 min. That's what lights up the booted/staged/rollback cards.

## Building from Katello content (not public mirrors)

The Containerfile registers to Katello with the **`AlmaLinux 10` activation key**
(`subscription-manager register --org Garaventaville --activationkey 'AlmaLinux 10'`)
and installs with `--disablerepo='*' --enablerepo='Garaventaville_AlmaLinux_10_*'`,
then unregisters — so the image is built from your synced/governed repos
(BaseOS/AppStream/CRB/EPEL/Duo/Foreman client), not public mirrors. The only
public fetch is `subscription-manager` itself (needed before Katello is
reachable). A failed build can leave an orphaned Katello consumer to clean up.

**Caveat — certbot:** `certbot`/`python3-certbot-dns-cloudflare` are temporarily
dropped. EPEL upstream currently ships a broken `python3-pyOpenSSL 26.2.0` that
requires `python3-cryptography >= 46`, which AlmaLinux 10 doesn't provide (it has
43). This is an upstream EPEL bug, not stale content — re-add certbot once EPEL
reverts pyOpenSSL and you re-sync the EPEL repo.

## Gotchas learned the hard way

- **Push path is 3-part**: `<org_label>/<product_label>/<name>`, lowercased.
  Katello matches the org/product case-insensitively (`LOWER(label)`), but
  podman requires lowercase. Org label `Garaventaville` -> `garaventaville`.
- **A Katello product must exist to push into**, and it MUST be created
  through Katello's orchestration (the `Actions::Katello::Product::Create`
  dynflow action — see `foreman/create_product.rb`). Creating it with a bare
  `Katello::Product.create!` in the rails console leaves it **unregistered in
  Candlepin** (`cp_id = nil`), and the push fails with a 500 / CandlepinError
  (`/candlepin/owners/<org>/products//content/...` — note the empty id).
- **`ostreecontainer` replaces `url`/`repo`/`%packages`** in the kickstart;
  Anaconda's installer runtime (stage2) still comes over the network, supplied
  as `inst.stage2=` by the PXEGrub2 template.
- bootc image hygiene: don't `rm -rf /run/*` in the Containerfile — buildah
  keeps live mounts there (`/run/secrets`, `/run/.containerenv`). `/run` is
  tmpfs at boot anyway, so the `nonempty-run-tmp` lint warning is harmless.
- **Install-time pull auth**: Katello's registry refuses anonymous pulls even
  when the repo's `unprotected=true`. Pull authorization is per *lifecycle
  environment* (`KTEnvironment#registry_unauthenticated_pull`, checked live in
  `registry_proxies_controller.rb`). Anaconda pulls in `%pre` *before* the host
  registers, so the install-time environment must allow unauthenticated pull.
  That is now **Production** (see `foreman/set_unauth_pull.rb`), not Library:
  hosts install only the smoke-test-gated content the weekly build promoted to
  Production. **Library is private staging** (`unauth_pull=false`) — fresh pushes
  land there but aren't installable until they pass the gate.
