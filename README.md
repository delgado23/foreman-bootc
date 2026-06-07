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
