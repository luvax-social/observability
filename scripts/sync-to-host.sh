#!/bin/bash
# Places this repository's observability/ tree onto the production host at
# /data/luvax/observability, which compose.prod.yaml's bind mounts read directly.
# This is the only sanctioned way to put these files on the host: runbook step R1 calls this
# script and nothing else, so the host tree, compose.prod.yaml and this script never drift apart.
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/luvax-social/Luvax.git}
BRANCH=${BRANCH:-main}
TARGET_DIR=${TARGET_DIR:-/data/luvax/observability}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

sudo install -d -m 0755 "$TARGET_DIR"

git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP_DIR/luvax-root"
sudo rsync -a --delete "$TMP_DIR/luvax-root/observability/" "$TARGET_DIR/"

sudo chmod 0755 "$TARGET_DIR/clickhouse/initdb/01-create-users.sh"
sudo chown -R 472:0 "$TARGET_DIR/grafana"

echo "Synced observability/ to $TARGET_DIR"
