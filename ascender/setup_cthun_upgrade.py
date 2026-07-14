#!/usr/bin/env python3
"""Set up the standalone image-mode host bootc-upgrade automation in Ascender (AWX).

Idempotently creates / updates:

  1. Job Template  "Bootc Upgrade - Standalone Hosts"  (runs bootc-upgrade.yml
                                                         against the aarch64
                                                         image-mode group —
                                                         currently just cthun)
  2. Workflow node for that JT inside the existing "Daily bootc Image Build
     Workflow", wired to run on success of the "Daily bootc Image Build" node —
     the same freshly-built/pushed image the new JT pulls via `bootc upgrade`.

Reuses the existing "foreman-bootc" project, inventory, machine credential, and
execution environment (same ones "Daily bootc Image Build" already uses to reach
cthun). No vault/registry credential is needed: JT 49 (Kubernetes Cluster
Maintenance) already proves `bootc upgrade` pulls from Production without an
explicit registry login on image-mode hosts.

Usage:
    export ASCENDER_TOKEN=...              # required; never hardcode it
    ./ascender/setup_cthun_upgrade.py
    ./ascender/setup_cthun_upgrade.py --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE_DEFAULT = "https://ascender.garaventaville.com/api/v2"

ORG_NAME = "Garaventaville"
INVENTORY_NAME = "Garaventaville Servers"
MACHINE_CRED_NAME = "Ansible User"            # connects to cthun, sudo -> root
EE_NAME = "Garaventaville AWX EE (latest)"
SCM_CRED_NAME = "AWX Git"                      # reads the foreman-bootc repo

PROJECT_NAME = "foreman-bootc"
JT_NAME = "Bootc Upgrade - Standalone Hosts"
PLAYBOOK = "bootc-upgrade.yml"
LIMIT = "foreman_almalinux10aarch64_imagemode"  # currently just cthun

WORKFLOW_NAME = "Daily bootc Image Build Workflow"
BUILD_JT_NAME = "Daily bootc Image Build"       # existing node this hangs off of


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
            if status == "successful":
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
    print(f"  linked: '{BUILD_JT_NAME}' --on success--> '{JT_NAME}'")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default=os.environ.get("ASCENDER_BASE", BASE_DEFAULT))
    ap.add_argument("--scm-branch", default="main",
                    help="git branch the Ascender project tracks (default: main)")
    ap.add_argument("--verify-tls", action="store_true",
                    help="verify the Ascender TLS cert (default: skip, internal CA)")
    ap.add_argument("--dry-run", action="store_true",
                    help="resolve dependencies and print the plan, change nothing")
    args = ap.parse_args()

    token = os.environ.get("ASCENDER_TOKEN")
    if not token:
        sys.exit("ERROR: set ASCENDER_TOKEN in the environment.")

    api = Api(args.base, token, verify=args.verify_tls)

    org = api.require("organizations", ORG_NAME)
    inventory = api.require("inventories", INVENTORY_NAME)
    machine_cred = api.require("credentials", MACHINE_CRED_NAME)
    ee = api.require("execution_environments", EE_NAME)
    project = api.require("projects", PROJECT_NAME)
    wfjt = api.require("workflow_job_templates", WORKFLOW_NAME)
    build_jt = api.require("job_templates", BUILD_JT_NAME)

    print("Plan:")
    print(f"  org={org['id']} inventory={inventory['id']} machine_cred={machine_cred['id']} "
          f"ee={ee['id']} project={project['id']}")
    print(f"  job template '{JT_NAME}' -> {PLAYBOOK} limit={LIMIT}")
    print(f"  workflow '{WORKFLOW_NAME}' (id {wfjt['id']}): "
          f"'{BUILD_JT_NAME}' (id {build_jt['id']}) --success--> '{JT_NAME}'")
    if args.dry_run:
        print("\n--dry-run: no changes made.")
        return

    # Re-sync the project so bootc-upgrade.yml (just added to the repo) is
    # visible to the job template before it's created/updated.
    print("\nProject:")
    api.sync_project(project["id"])

    print("\nJob template:")
    jt = ensure(api, "job_templates", JT_NAME, {
        "description": "Rolling bootc upgrade for standalone (non-cluster) "
                        "image-mode hosts (bootc-upgrade.yml).",
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

    print("  attaching credentials:")
    attached = {c["id"] for c in
                api.get(f"/job_templates/{jt['id']}/credentials/").get("results", [])}
    if machine_cred["id"] in attached:
        print(f"    = {machine_cred['name']} (id {machine_cred['id']}) already attached")
    else:
        api.post(f"/job_templates/{jt['id']}/credentials/", {"id": machine_cred["id"]})
        print(f"    + {machine_cred['name']} (id {machine_cred['id']})")

    print("\nWorkflow node:")
    build_node = ensure_wf_node(api, wfjt["id"], build_jt["id"], BUILD_JT_NAME)
    upgrade_node = ensure_wf_node(api, wfjt["id"], jt["id"], JT_NAME)
    ensure_success_link(api, build_node, upgrade_node)

    print("\nDone.")


if __name__ == "__main__":
    main()
