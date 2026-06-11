#!/usr/bin/env python3
"""Set up the weekly bootc-image build automation in Ascender (AWX).

Idempotently creates / updates these objects in the Garaventaville organization:

  1. Project           "foreman-bootc"              (this git repo, SCM = git)
  2. Job Template      "Build bootc Images Weekly"  (runs main.yml on nexus + cthun)
  3. Workflow JT       "Weekly bootc Image Build"   (content refresh -> build)
  4. Schedule          "Weekly bootc Image Build"   (Sundays 03:00 America/New_York,
                                                     on the workflow, not the JT)

The job template reuses the existing inventory, machine credential, execution
environment, and a Vault credential (whose password must match the one used to
`ansible-vault encrypt vars/vault.yml`).

The workflow guarantees freshness: node 1 runs the existing content JT
"Sync, Publish, Promote, and Cleanup Foreman Content Views" (syncs the AlmaLinux
repos + republishes/promotes the RPM CVs to Production), and only on its SUCCESS
does node 2 run the build JT. Combined with `--no-cache` in the build scripts and
`--pull=always` on the base, every weekly run bakes the latest OS updates. The
schedule lives on the workflow; any same-named schedule still on the JT is moved.

Nothing is created until you run this. It only talks to the Ascender API; it does
not touch the build host. Re-running is safe (find-or-create, then PATCH to match).

Usage:
    export ASCENDER_TOKEN=...            # required; never hardcode it
    ./ascender/setup_weekly_builds.py    # create/update everything
    ./ascender/setup_weekly_builds.py --dry-run
    ./ascender/setup_weekly_builds.py --vault-credential 'Kubernetes Vault'

Override the schedule with --weekday (MO..SU), --hour, --minute, --timezone.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE_DEFAULT = "https://ascender.garaventaville.com/api/v2"

# Existing Ascender objects we attach to (names, resolved to ids at runtime).
ORG_NAME = "Garaventaville"
INVENTORY_NAME = "Garaventaville Servers"
MACHINE_CRED_NAME = "Ansible User"           # connects to nexus + cthun, sudo -> bootcbuild
EE_NAME = "Garaventaville AWX EE (latest)"
SCM_CRED_NAME = "AWX Git"                     # reads the foreman-bootc repo
DEFAULT_VAULT_CRED = "Kubernetes Vault"       # decrypts vars/vault.yml on main

PROJECT_NAME = "foreman-bootc"
PROJECT_SCM_URL = "https://git.garaventaville.com/Garaventaville/foreman-bootc.git"
JT_NAME = "Build bootc Images Weekly"
# Existing content JT that syncs repos + publishes/promotes the RPM CVs to
# Production. The workflow runs this first so the build pulls current content.
CONTENT_JT_NAME = "Sync, Publish, Promote, and Cleanup Foreman Content Views"
WORKFLOW_NAME = "Weekly bootc Image Build"   # content refresh -> build; carries the schedule
SCHEDULE_NAME = "Weekly bootc Image Build"
PLAYBOOK = "main.yml"
# Both build hosts, by arch: nexus (x86_64) builds base + k8s; cthun (aarch64)
# builds the Raspberry Pi image. --limit filters every play, so both must be listed
# or main.yml's per-host build play silently matches nothing.
LIMIT = "nexus.garaventaville.com:cthun.garaventaville.com"

WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]


class Api:
    def __init__(self, base: str, token: str, verify: bool):
        self.base = base.rstrip("/")
        self.token = token
        self.ctx = None if verify else ssl._create_unverified_context()

    def _req(self, method: str, path: str, body: dict | None = None) -> dict:
        url = path if path.startswith("http") else f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, context=self.ctx) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            sys.exit(f"ERROR {e.code} on {method} {url}\n{detail}")

    def get(self, path: str) -> dict:
        return self._req("GET", path)

    def post(self, path: str, body: dict) -> dict:
        return self._req("POST", path, body)

    def patch(self, path: str, body: dict) -> dict:
        return self._req("PATCH", path, body)

    def delete(self, path: str) -> None:
        self._req("DELETE", path)

    def find(self, endpoint: str, name: str) -> dict | None:
        q = urllib.parse.urlencode({"name": name})
        results = self.get(f"/{endpoint}/?{q}").get("results", [])
        for r in results:                       # exact match (API filter is a contains)
            if r.get("name") == name:
                return r
        return None

    def require(self, endpoint: str, name: str) -> dict:
        obj = self.find(endpoint, name)
        if not obj:
            sys.exit(f"ERROR: required {endpoint[:-1]} '{name}' not found in Ascender.")
        return obj

    def sync_project(self, project_id: int, timeout: int = 300) -> None:
        """Trigger a project update and block until it finishes (the playbook
        list isn't valid until the SCM sync completes)."""
        update = self.post(f"/projects/{project_id}/update/", {})
        upd_id = update.get("id")
        print(f"  syncing project (update {upd_id})...", end="", flush=True)
        deadline = time.time() + timeout
        while time.time() < deadline:
            status = self.get(f"/project_updates/{upd_id}/").get("status")
            if status in ("successful",):
                print(" ok")
                return
            if status in ("failed", "error", "canceled"):
                sys.exit(f"\nERROR: project sync ended '{status}'.")
            print(".", end="", flush=True)
            time.sleep(3)
        sys.exit(f"\nERROR: project sync did not finish within {timeout}s.")


def ensure(api: Api, endpoint: str, name: str, desired: dict) -> dict:
    """Find-or-create an object by name, PATCHing it to match `desired`."""
    existing = api.find(endpoint, name)
    if existing:
        api.patch(f"/{endpoint}/{existing['id']}/", desired)
        print(f"  updated {endpoint[:-1]} '{name}' (id {existing['id']})")
        return api.get(f"/{endpoint}/{existing['id']}/")
    created = api.post(f"/{endpoint}/", {"name": name, **desired})
    print(f"  created {endpoint[:-1]} '{name}' (id {created['id']})")
    return created


def ensure_wf_node(api: Api, wfjt_id: int, ujt_id: int, label: str) -> dict:
    """Find-or-create the workflow node that runs `ujt_id` within the workflow.
    Nodes are nameless, so they're identified by their unified_job_template."""
    nodes = api.get(f"/workflow_job_templates/{wfjt_id}/workflow_nodes/").get("results", [])
    for n in nodes:
        if n.get("unified_job_template") == ujt_id:
            print(f"  node '{label}' exists (id {n['id']})")
            return n
    created = api.post(f"/workflow_job_templates/{wfjt_id}/workflow_nodes/",
                       {"unified_job_template": ujt_id})
    print(f"  created node '{label}' (id {created['id']})")
    return created


def ensure_success_link(api: Api, src: dict, dst: dict) -> None:
    """Make `dst` run on success of `src` (idempotent)."""
    current = api.get(
        f"/workflow_job_template_nodes/{src['id']}/success_nodes/").get("results", [])
    if any(n["id"] == dst["id"] for n in current):
        print("  success link already present")
        return
    api.post(f"/workflow_job_template_nodes/{src['id']}/success_nodes/", {"id": dst["id"]})
    print("  linked: content refresh --on success--> build")


def next_weekday(weekday: str, hour: int, minute: int, tz_now: dt.datetime) -> dt.datetime:
    """First occurrence of `weekday` at hour:minute that is strictly in the future."""
    target = WEEKDAYS.index(weekday)
    candidate = tz_now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    delta = (target - candidate.weekday()) % 7
    candidate += dt.timedelta(days=delta)
    if candidate <= tz_now:
        candidate += dt.timedelta(days=7)
    return candidate


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default=os.environ.get("ASCENDER_BASE", BASE_DEFAULT))
    ap.add_argument("--vault-credential", default=DEFAULT_VAULT_CRED,
                    help="Vault credential that decrypts vars/vault.yml")
    ap.add_argument("--scm-branch", default="main",
                    help="git branch the Ascender project tracks (default: main)")
    ap.add_argument("--weekday", default="SU", choices=WEEKDAYS)
    ap.add_argument("--hour", type=int, default=3)
    ap.add_argument("--minute", type=int, default=0)
    ap.add_argument("--timezone", default="America/New_York")
    ap.add_argument("--verify-tls", action="store_true",
                    help="verify the Ascender TLS cert (default: skip, internal CA)")
    ap.add_argument("--dry-run", action="store_true",
                    help="resolve dependencies and print the plan, change nothing")
    args = ap.parse_args()

    token = os.environ.get("ASCENDER_TOKEN")
    if not token:
        sys.exit("ERROR: set ASCENDER_TOKEN in the environment.")

    api = Api(args.base, token, verify=args.verify_tls)

    # Resolve the existing objects we depend on.
    org = api.require("organizations", ORG_NAME)
    inventory = api.require("inventories", INVENTORY_NAME)
    machine_cred = api.require("credentials", MACHINE_CRED_NAME)
    vault_cred = api.require("credentials", args.vault_credential)
    ee = api.require("execution_environments", EE_NAME)
    scm_cred = api.require("credentials", SCM_CRED_NAME)
    content_jt = api.require("job_templates", CONTENT_JT_NAME)

    # Compute the weekly schedule's first run + rrule.
    try:
        from zoneinfo import ZoneInfo
        now = dt.datetime.now(ZoneInfo(args.timezone))
    except Exception:
        now = dt.datetime.now()
    first = next_weekday(args.weekday, args.hour, args.minute, now)
    dtstart = first.strftime("%Y%m%dT%H%M%S")
    rrule = (f"DTSTART;TZID={args.timezone}:{dtstart} "
             f"RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY={args.weekday}")

    print("Plan:")
    print(f"  org={org['id']} inventory={inventory['id']} machine_cred={machine_cred['id']} "
          f"vault_cred={vault_cred['id']} ee={ee['id']} scm_cred={scm_cred['id']}")
    print(f"  project '{PROJECT_NAME}' <- {PROJECT_SCM_URL} (branch {args.scm_branch})")
    print(f"  job template '{JT_NAME}' -> {PLAYBOOK} limit={LIMIT}")
    print(f"  workflow '{WORKFLOW_NAME}': '{CONTENT_JT_NAME}' (id {content_jt['id']}) "
          f"--success--> '{JT_NAME}'")
    print(f"  schedule '{SCHEDULE_NAME}' (on workflow): {rrule}")
    if args.dry_run:
        print("\n--dry-run: no changes made.")
        return

    # 1. Project (SCM = git, update on launch so each run builds the latest commit).
    print("\nProject:")
    project = ensure(api, "projects", PROJECT_NAME, {
        "description": "AlmaLinux 10 bootc images (base + Kubernetes node images).",
        "organization": org["id"],
        "scm_type": "git",
        "scm_url": PROJECT_SCM_URL,
        "scm_branch": args.scm_branch,
        "credential": scm_cred["id"],
        "scm_update_on_launch": True,
        "scm_clean": True,
        "scm_delete_on_update": False,
    })
    # Block until the SCM sync completes — the JT's playbook field is validated
    # against the synced project, so creating it before the sync finishes 400s.
    api.sync_project(project["id"])

    # 2. Job template.
    print("\nJob template:")
    jt = ensure(api, "job_templates", JT_NAME, {
        "description": "Weekly build/test/push of the bootc images (main.yml on nexus + cthun).",
        "job_type": "run",
        "organization": org["id"],
        "inventory": inventory["id"],
        "project": project["id"],
        "playbook": PLAYBOOK,
        "execution_environment": ee["id"],
        "limit": LIMIT,
        "become_enabled": True,
        "verbosity": 1,
    })

    # Attach credentials (machine + vault). Skip any already attached: this AWX
    # rejects re-POSTing a machine credential that's already present ("Cannot
    # assign multiple Machine credentials"), so the loop must be idempotent itself.
    print("  attaching credentials:")
    attached = {c["id"] for c in
                api.get(f"/job_templates/{jt['id']}/credentials/").get("results", [])}
    for cred in (machine_cred, vault_cred):
        if cred["id"] in attached:
            print(f"    = {cred['name']} (id {cred['id']}) already attached")
            continue
        api.post(f"/job_templates/{jt['id']}/credentials/", {"id": cred["id"]})
        print(f"    + {cred['name']} (id {cred['id']})")

    # 3. Workflow: content refresh (node 1) --on success--> build (node 2).
    # Running the content JT first (sync + publish/promote the RPM CVs to
    # Production) guarantees the build pulls the latest OS updates.
    print("\nWorkflow:")
    wfjt = ensure(api, "workflow_job_templates", WORKFLOW_NAME, {
        "description": "Refresh Foreman content, then build the bootc images.",
        "organization": org["id"],
    })
    refresh_node = ensure_wf_node(api, wfjt["id"], content_jt["id"], CONTENT_JT_NAME)
    build_node = ensure_wf_node(api, wfjt["id"], jt["id"], JT_NAME)
    ensure_success_link(api, refresh_node, build_node)

    # 4. Weekly schedule — on the WORKFLOW, not the JT. A schedule can't be
    # reparented via PATCH, so if one of this name still hangs off the JT (the
    # pre-workflow layout), delete it and recreate it on the workflow.
    print("\nSchedule:")
    sched_body = {"rrule": rrule, "description": "Sundays 03:00 ET by default.",
                  "enabled": True}
    existing_sched = api.find("schedules", SCHEDULE_NAME)
    if existing_sched and existing_sched.get("unified_job_template") != wfjt["id"]:
        api.delete(f"/schedules/{existing_sched['id']}/")
        print(f"  removed stale schedule from job template (id {existing_sched['id']})")
        existing_sched = None
    if existing_sched:
        api.patch(f"/schedules/{existing_sched['id']}/", sched_body)
        print(f"  updated schedule '{SCHEDULE_NAME}' (id {existing_sched['id']})")
    else:
        created = api.post(f"/workflow_job_templates/{wfjt['id']}/schedules/",
                           {"name": SCHEDULE_NAME, **sched_body})
        print(f"  created schedule '{SCHEDULE_NAME}' on workflow (id {created['id']})")

    print(f"\nDone. First run: {first.isoformat()}  ({args.timezone})")
    print("Reminder: commit an encrypted vars/vault.yml (registry creds) before the "
          "first scheduled run, or launch will fail to decrypt.")


if __name__ == "__main__":
    main()
