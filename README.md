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
templates/
  kickstart_almalinux10_bootc.erb   provision template: ostreecontainer install
  pxegrub2_almalinux10_bootc.erb    UEFI boot entry: supplies inst.stage2
foreman/
  create_product.rb      create the Katello "bootc" product (correct, via dynflow)
  load_templates.rb      load both templates into Foreman + set as OS defaults
  ops/                   one-off recovery/inspection scripts (incident reference)
```

## Build host

Built on **nexus.garaventaville.com** as the rootless user `bootcbuild`
(`sudo -iu bootcbuild`, files in `~/build`). The build host `/` is small
(~14 GB free) — run `prune.sh` after pushes.

## Workflow

```bash
# on nexus, as bootcbuild, in ~/build
podman login foreman.garaventaville.com
./build-push.sh 10.0      # -> foreman.garaventaville.com/garaventaville/bootc/almalinux10-bootc:10.0
./prune.sh
```

Then create a host on AlmaLinux 10 with host parameter:

```
ostreecontainer = foreman.garaventaville.com/garaventaville/bootc/almalinux10-bootc:10.0
```

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
  registers, so we enabled unauthenticated pull on **Library** (see
  `foreman/enable_unauth_pull.rb`) — no creds needed in the kickstart.
