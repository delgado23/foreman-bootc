# Testing the Library → Production content-view gate

Validate the gating workflow in order, **cheapest/reversible checks first** and
the irreversible Library lock-down last. Stop and reassess if any phase fails.

Where each step runs:
- `foreman/*.rb` → on **foreman.garaventaville.com**: `sudo foreman-rake console < <script>`
- build steps → on **nexus.garaventaville.com** as `bootcbuild`, in the repo checkout
- `main.yml` promote play / hammer → wherever the `theforeman.foreman` collection
  and Foreman API creds are available (the Ascender EE, or any controller)

Org is **Garaventaville** (id 4).

---

## Phase 0 — Confirm feasibility (read-only, do first)

```bash
# on foreman.garaventaville.com
sudo foreman-rake console < foreman/ops/inspect_content_view.rb
```

Confirm in the output:
- [ ] `PUSH_REPOS count=4` with the four image names → push repos are identifiable
- [ ] an `ENV` line with `label=Production` (note its label/id)
- [ ] four `REPO` lines under the bootc product

If push repos are **not** CV-eligible on this Katello build, stop — use the
synced-repo fallback (see the plan) and revisit before continuing.

## Phase 1 — Create the content view (one-time, additive)

```bash
sudo foreman-rake console < foreman/setup_content_view.rb        # create + publish + promote
sudo foreman-rake console < foreman/ops/inspect_content_view.rb  # re-inspect
```

Confirm:
- [ ] `bootc` CV exists with 4 repos and a version in `[library,Production]`
- [ ] `PROD_PATH` lines print the real Production pull path for each image

This does not change what hosts pull yet.

## Phase 2 — Production path live, Library still open (no outage)

```bash
sudo foreman-rake console < foreman/set_unauth_pull.rb            # enables Production; KEEPS Library (refs not moved yet)
sudo foreman-rake console < foreman/setup_image_mode_hostgroup.rb # repoint base ref -> Production
sudo foreman-rake console < foreman/setup_kubernetes_image_mode.rb # repoint k8s refs -> Production
```

`set_unauth_pull.rb` is self-sequencing: it leaves Library pullable until the
Image Mode host group's `ostreecontainer` param points at a Production path, so
this first run prints `ENV_KEPT Library` — that's expected. Then:
- [ ] provision one throwaway host in host group `AlmaLinux 10/Image Mode` (id 31)
- [ ] confirm Anaconda `%pre` pulls anonymously from the **Production** path and the host boots
      (booted/staged cards light up via `bootc-rhsm-facts`)

## Phase 3 — Lock down Library (irreversible; only after Phase 2 passes)

```bash
sudo foreman-rake console < foreman/set_unauth_pull.rb   # refs now on Production -> sets Library unauth_pull=false
```

Verify from a host with **no** registry creds (`podman logout foreman.garaventaville.com` first):
- [ ] `podman pull foreman.garaventaville.com/<PROD_PATH>:10.0` → **succeeds**
- [ ] `podman pull foreman.garaventaville.com/garaventaville/bootc/almalinux10-bootc:10.0` → **403**

## Phase 4 — The smoke gate (independent of phases 0–3)

Build-side smoke test (no Foreman change needed):

```bash
# on nexus as bootcbuild, in the repo checkout
podman login foreman.garaventaville.com
SMOKE_PULL=1 ./build-push.sh 10.0          # build -> push to Library -> re-pull -> re-check
```

- [ ] **Positive:** completes through the pull-back checks
- [ ] **Negative (important):** break a check (e.g. point `rpm -q` at a package
      that isn't baked) and confirm the script exits non-zero. Under `main.yml`
      that aborts the run *before* the promote play — Production keeps its prior version.

Promote play (needs `vars/vault.yml` filled + encrypted and the `theforeman.foreman`
collection):

```bash
hammer content-view version list --content-view bootc --organization Garaventaville
```
- [ ] a new CV version is promoted to Production after a passing run

## Phase 5 — The weekly Ascender run

`main.yml` checks out `repo_version: main`, but this work is on
`automate-weekly-builds`. Either **merge to `main`** first, or point the Ascender
project/JT scm-branch at `automate-weekly-builds` for the test, then **Launch**
the "Build bootc Images Weekly" job manually and watch build → smoke → promote.
- [ ] one manual job run goes green end to end
