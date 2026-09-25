#!/bin/bash
set -euo pipefail
clickhouse client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery <<SQL
CREATE DATABASE IF NOT EXISTS otel;
CREATE USER IF NOT EXISTS grafana_reader IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_GRAFANA_PASSWORD}' SETTINGS PROFILE 'reader';
GRANT SELECT ON otel.* TO grafana_reader;
GRANT SELECT ON system.databases TO grafana_reader;
GRANT SELECT ON system.tables TO grafana_reader;
GRANT SELECT ON system.columns TO grafana_reader;
SQL
