#!/usr/bin/env bash
# prune.sh — reclaim disk after a build/push. nexus / is small (~14G free),
# so run this once an image is safely pushed to Katello.
set -euo pipefail
echo ">> Before:"; df -h --output=avail / | tail -1
podman image prune -af          # dangling + unused images
podman builder prune -af 2>/dev/null || true   # buildah/build cache
podman system prune -f          # stopped containers, networks, dangling
echo ">> After:"; df -h --output=avail / | tail -1
