#!/usr/bin/env bash
#
# mirror-to-github.sh — publish the Gitea repo to GitHub with secrets stripped.
#
# Gitea (git.garaventaville.com) is the source of truth. GitHub is a public
# mirror that must NOT contain vars/vault.yml (even though it's ansible-vault
# encrypted). Because we rewrite history to drop that file, GitHub's commit
# SHAs diverge from Gitea's — so this always force-pushes, and you should only
# ever push TO GitHub via this script, never pull/merge from it.
#
# Each run is a clean clone in a temp dir; your working copy is never touched.
#
# Requires: git-filter-repo  (pip install --user git-filter-repo)
#           plus ~/.local/bin on PATH if installed with --user.
#
# Usage:
#   ./mirror-to-github.sh            # mirror all branches, stripping vault.yml
#   ./mirror-to-github.sh --dry-run  # do everything except the final push

set -euo pipefail

# --- config -----------------------------------------------------------------
SOURCE_URL="git@git.garaventaville.com:Garaventaville/foreman-bootc.git"
TARGET_URL="git@github.com:delgado23/foreman-bootc.git"
DEFAULT_BRANCH="main"

# Branches to publish (anything else on Gitea — incl. refs/pull/* — is dropped).
BRANCHES=(main master automate-weekly-builds image-mode-k8s)

# Paths scrubbed from ALL history before pushing.
EXCLUDE_PATHS=(vars/vault.yml)
# ----------------------------------------------------------------------------

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

die() { echo "!! $*" >&2; exit 1; }

command -v git-filter-repo >/dev/null 2>&1 || die \
  "git-filter-repo not found. Install it:  pip install --user git-filter-repo  (ensure ~/.local/bin is on PATH)"

work="$(mktemp -d /tmp/fbootc-mirror.XXXXXX)"
trap 'rm -rf "$work"' EXIT

echo ">> cloning $SOURCE_URL"
git clone --mirror "$SOURCE_URL" "$work/repo.git" >/dev/null 2>&1
cd "$work/repo.git"

# Drop every ref that isn't a branch we want to publish (kills refs/pull/*,
# refs/tags we don't care about, etc.) so filter-repo only rewrites our heads.
echo ">> pruning non-published refs"
keep_re="$(printf 'refs/heads/%s\n' "${BRANCHES[@]}" | paste -sd'|' -)"
git for-each-ref --format='%(refname)' \
  | grep -Ev "^(${keep_re})$" \
  | sed 's/^/delete /' \
  | git update-ref --stdin

# Scrub the secret paths from all remaining history.
echo ">> stripping: ${EXCLUDE_PATHS[*]}"
path_args=()
for p in "${EXCLUDE_PATHS[@]}"; do path_args+=(--path "$p"); done
git filter-repo --force --invert-paths "${path_args[@]}"

# Sanity check: none of the scrubbed paths may survive on any published branch.
for p in "${EXCLUDE_PATHS[@]}"; do
  if git log --oneline "${BRANCHES[@]}" -- "$p" 2>/dev/null | grep -q .; then
    die "ABORT: '$p' still present in history after filtering"
  fi
done
echo ">> verified: scrubbed paths absent from all published branches"

git remote add github "$TARGET_URL"

if [[ "$DRY_RUN" == 1 ]]; then
  echo ">> [dry-run] would force-push: ${BRANCHES[*]}"
  echo ">> [dry-run] refs that would be sent:"
  git for-each-ref --format='   %(refname)' refs/heads
  exit 0
fi

# Force-push the default branch first (keeps GitHub's default branch correct on
# a fresh repo), then the rest.
echo ">> pushing $DEFAULT_BRANCH"
git push --force github "refs/heads/${DEFAULT_BRANCH}:refs/heads/${DEFAULT_BRANCH}"

rest=()
for b in "${BRANCHES[@]}"; do
  [[ "$b" == "$DEFAULT_BRANCH" ]] && continue
  rest+=("refs/heads/$b:refs/heads/$b")
done
if ((${#rest[@]})); then
  echo ">> pushing: ${rest[*]}"
  git push --force github "${rest[@]}"
fi

echo ">> done. GitHub mirror updated: $TARGET_URL"
