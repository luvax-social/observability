#!/bin/bash
# Places this repository's tree onto the production host at /data/luvax/observability, which
# compose.prod.yaml's bind mounts read directly.
# This is the only sanctioned way to put these files on the host: runbook step R1 calls this
# script and nothing else, so the host tree, compose.prod.yaml and this script never drift apart.
#
# This repository used to be the observability/ subdirectory of the root aggregator, and this
# script cloned that repository and rsynced its observability/ subdirectory. Once the stack moved
# into its own repository (luvax-social/observability), that subdirectory stopped existing on the
# clone: the root repository now only carries a submodule pointer here, which a plain
# `git clone` does not check out. Cloning this repository directly, at its own root, is the fix.
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/luvax-social/observability.git}
BRANCH=${BRANCH:-main}
TARGET_DIR=${TARGET_DIR:-/data/luvax/observability}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

sudo install -d -m 0755 "$TARGET_DIR"

git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP_DIR/observability"
# ClickHouse's entrypoint writes users.d/default-user.xml on the host at first boot, to disable the
# passwordless "default" user. It is not tracked, so --delete would remove it and leave that user
# open over HTTP on the coolify network until the container is recreated. Excluding it also
# protects it from --delete.
sudo rsync -a --delete --exclude .git --exclude /clickhouse/users.d/default-user.xml     "$TMP_DIR/observability/" "$TARGET_DIR/"

sudo chmod 0755 "$TARGET_DIR"/clickhouse/initdb/*.sh
sudo chown -R 472:0 "$TARGET_DIR/grafana"

echo "Synced observability/ to $TARGET_DIR"
