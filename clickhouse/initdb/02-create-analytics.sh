#!/bin/bash
# Provisions the luvax_analytics database, its three application users and their settings
# profiles, and Grafana's read access. Idempotent: CREATE ... IF NOT EXISTS makes each object,
# ALTER ... brings its settings and password to the values below on every run, and GRANT is a
# no-op when already held. Runs from initdb on an empty volume; on an existing volume the runbook
# runs this same file with docker exec, because initdb never runs twice.
set -euo pipefail
: "${CLICKHOUSE_ANALYTICS_WRITER_PASSWORD:?must be set on the clickhouse service}"
: "${CLICKHOUSE_ANALYTICS_READER_PASSWORD:?must be set on the clickhouse service}"
: "${CLICKHOUSE_ANALYTICS_MIGRATOR_PASSWORD:?must be set on the clickhouse service}"

clickhouse client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery <<SQL
CREATE DATABASE IF NOT EXISTS luvax_analytics;

CREATE SETTINGS PROFILE IF NOT EXISTS analytics_writer;
ALTER SETTINGS PROFILE analytics_writer SETTINGS
    max_memory_usage = 268435456 MAX 536870912,
    max_memory_usage_for_user = 536870912 CONST,
    max_threads = 2 MAX 2,
    max_execution_time = 30 MAX 60,
    async_insert = 1,
    wait_for_async_insert = 1,
    async_insert_use_adaptive_busy_timeout = 1,
    async_insert_busy_timeout_min_ms = 5,
    async_insert_busy_timeout_max_ms = 20,
    async_insert_max_data_size = 10485760,
    async_insert_deduplicate = 0;

CREATE SETTINGS PROFILE IF NOT EXISTS analytics_reader;
ALTER SETTINGS PROFILE analytics_reader SETTINGS
    readonly = 2,
    max_memory_usage = 536870912 MAX 1073741824,
    max_memory_usage_for_user = 1073741824 CONST,
    max_threads = 2 MAX 2,
    max_execution_time = 20 MAX 300,
    max_result_rows = 100000,
    max_concurrent_queries_for_user = 8 CONST;

CREATE SETTINGS PROFILE IF NOT EXISTS analytics_migrator;
ALTER SETTINGS PROFILE analytics_migrator SETTINGS
    max_memory_usage = 268435456 MAX 536870912,
    max_memory_usage_for_user = 536870912 CONST,
    max_threads = 2 MAX 2,
    max_execution_time = 300 MAX 600;

CREATE USER IF NOT EXISTS luvax_analytics_writer IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_ANALYTICS_WRITER_PASSWORD}';
ALTER USER luvax_analytics_writer IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_ANALYTICS_WRITER_PASSWORD}' SETTINGS PROFILE 'analytics_writer';
CREATE USER IF NOT EXISTS luvax_analytics_reader IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_ANALYTICS_READER_PASSWORD}';
ALTER USER luvax_analytics_reader IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_ANALYTICS_READER_PASSWORD}' SETTINGS PROFILE 'analytics_reader';
CREATE USER IF NOT EXISTS luvax_analytics_migrator IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_ANALYTICS_MIGRATOR_PASSWORD}';
ALTER USER luvax_analytics_migrator IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_ANALYTICS_MIGRATOR_PASSWORD}' SETTINGS PROFILE 'analytics_migrator';

GRANT INSERT ON luvax_analytics.* TO luvax_analytics_writer;
GRANT SELECT ON luvax_analytics.* TO luvax_analytics_reader;
GRANT CREATE TABLE, CREATE VIEW, ALTER TABLE, ALTER VIEW, DROP TABLE, DROP VIEW, TRUNCATE, OPTIMIZE, SELECT, INSERT, SHOW TABLES ON luvax_analytics.* TO luvax_analytics_migrator;
GRANT SELECT ON luvax_analytics.* TO grafana_reader;
GRANT SELECT ON system.asynchronous_insert_log TO grafana_reader;
SQL
