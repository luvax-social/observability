# Observability stack (Phase 1)

Traces and logs over OpenTelemetry, metrics over Prometheus, dashboards and alerting in Grafana.
Phase 1 scope is monitoring only.

## Components

As of Phase 1.5, this stack is five Coolify resources, not one. Splitting the exporters out lets
each be redeployed or have its credential rotated independently, without restarting Prometheus or
Grafana.

| Resource | Services | Role |
|---|---|---|
| `luvax-observability` (core) | `clickhouse`, `prometheus`, `grafana`, `otel-collector`, `docker-socket-proxy`, `blackbox-exporter` | Traces/logs/metrics storage, dashboards, alerting, exporter discovery, origin TLS probing |
| `luvax-observability-host` | `node-exporter`, `cadvisor` | Host and container metrics; paired because neither ever redeploys independently of the other |
| `luvax-postgres-exporter` | `postgres-exporter` | Postgres metrics, its own credential |
| `luvax-redis-exporter` | `redis-exporter` | Redis metrics, its own credential |
| `luvax-elasticsearch-exporter` | `elasticsearch-exporter` | Elasticsearch metrics, its own credential |

Each of the four datastore/host exporters opts into Prometheus's discovery with a
`luvax.prometheus.scrape=true` label (see `prometheus/prometheus.prod.yml`, job
`luvax-exporters`); Prometheus finds them through `docker-socket-proxy`'s `docker_sd_configs`
endpoint, addressed by container name, not container IP (see `docs/deployment-handoff.md`,
"Phase 1.5" runbook, for why).

| Service | Role |
|---|---|
| `otel-collector` | Receives OTLP traces/logs from the backend and container log files, exports both to ClickHouse |
| `clickhouse` | Stores `otel.otel_logs` and `otel.otel_traces` (14 and 7 day TTL) |
| `prometheus` | Scrapes the backend's management port, RabbitMQ, Gorse, every exporter above, and the origin TLS probe below; 30 day retention |
| `grafana` | Ten provisioned dashboards across five folders, Discord-backed alerting, the only public component |
| `docker-socket-proxy` | Read-only, `CONTAINERS`/`EVENTS`/`PING`/`VERSION`/`NETWORKS` only; the collector's and Prometheus's only path to the Docker API |
| `blackbox-exporter` | Probes the Coolify proxy's origin TLS certificate per hostname (new in Phase 1.5) |
| `postgres-exporter`, `redis-exporter`, `elasticsearch-exporter`, `node-exporter`, `cadvisor` | Infrastructure metrics for the dashboards above |

Total budget: 7520 MiB (~7.34 GB) memory, 2.02 CPU across all 11 containers in all five resources.
No existing exporter's `mem_limit`/`cpus` changed; only the new `blackbox-exporter` (32m/0.02) adds
to the prior 7.3 GB / 2.0 CPU total.

## Dashboard folders

Ten dashboards, grouped by category into five folders, each an explicit Grafana provisioning
provider with its own `folderUid` (`grafana/provisioning/dashboards/dashboards.yaml`):

| Folder | Dashboards |
|---|---|
| Infrastructure | Host & Containers |
| Backing Services | PostgreSQL, Redis, Elasticsearch, Gorse |
| Messaging | RabbitMQ, Outbox & Inbox |
| Application | JVM & HTTP |
| Explore | Logs Explorer, Trace Explorer |

A sixth folder, **Business**, is reserved for Phase 2 (platform statistics, admin actions, user
events) and is deliberately not created yet - there is nothing to put in it until that phase ships.

Alert rules live in their own folder, **Alerting**, separate from every dashboard folder (see
`grafana/provisioning/alerting/rules.yaml`).

**ClickHouse is pinned to `26.3.33.24` (the 26.3 LTS line) and must not move past 26.5.**
From ClickHouse 26.6 the official build's default target is x86-64-v3 (AVX2); the production host's
CPU has no AVX2, and `26.8.10.6` was reproduced crashing with `SIGILL` there while `26.3.33.24` (built
for x86-64-v2, SSE4.2 only) ran. This applies to both `compose.local.yaml` and `compose.prod.yaml`,
and again to Phase 2 analytics work on the same host, until the host's CPU model changes.

## Running locally

Off by default: every service in `compose.local.yaml` carries `profiles: ["observability"]`, so a
plain `docker compose -f observability/compose.local.yaml up -d` starts nothing.

1. Copy `.env.example` to `.env` and fill in the passwords.
2. Start the backend's own infrastructure first: `cd backend && docker compose up -d`.
   The compose file pins its project name to `backend`, so this works from any invocation
   directory without `-p backend`, and matches the container names this stack expects.
   A `postgres-monitoring-role` one-shot service runs on every `up`, including against a
   Postgres volume that already existed before this service was added, so the `postgresql`
   dashboard's `pg_up` and its other panels populate without a manual grant.
3. Start this stack: `cd .. && docker compose -f observability/compose.local.yaml --profile observability up -d`.
4. Start the backend with tracing on: set `OTLP_EXPORT_ENABLED=true` in `backend/.env`, then run the
   backend as usual (`start-app.bat`, or `cd backend && ./mvnw spring-boot:run`).
5. Grafana: `http://localhost:3000`. Prometheus: `http://localhost:9090`. ClickHouse HTTP:
   `http://localhost:8123`.
6. Stop: `docker compose -f observability/compose.local.yaml --profile observability down`, and set
   `OTLP_EXPORT_ENABLED=false` again.

The local compose file joins the backend's `luvax-local` network as external, so exporters reach the
backend's Postgres, Redis and Elasticsearch over `host.docker.internal`, and the collector's container
log discovery reads the backend compose project's own container names
(`backend-postgres-1`, `backend-redis-1`, `backend-rabbitmq-1`, `backend-elasticsearch-1`,
`backend-gorse-1`).

## Where things live

- Traces: `otel.otel_traces` in ClickHouse, 7 day TTL. Explore them in the `trace-explorer` dashboard.
- Application and container logs: `otel.otel_logs` in ClickHouse, 14 day TTL. Explore them in the
  `logs-explorer` dashboard, filtered by service, level, free text or trace id.
- Metrics: Prometheus, 30 day / 10 GB retention. Eight dashboards cover the JVM and HTTP layer, the
  outbox/inbox, RabbitMQ, PostgreSQL, Redis, Elasticsearch, Gorse, and the host and containers.
- Alerts: eleven rules (the six baseline rules - DLQ not empty, outbox DEAD rows, an open circuit
  breaker, a container restart loop, disk above 85 percent, a scrape target down - plus five added
  in Phase 1.5: origin TLS certificate expiring, a stalled RabbitMQ queue, a stalled outbox
  publisher, an unhealthy Elasticsearch cluster, and a high backend 5xx rate), delivered to a
  Discord channel. Critical-severity alerts repeat hourly; warning-severity alerts keep the
  original 4-hour repeat interval. **Every Phase 1.5 threshold is provisional**, to be revisited
  after two weeks of production data: the RabbitMQ stall rule's 5-minute pending window, the
  outbox-stall 300-second threshold, and the backend 5xx rule's 5 percent ratio and 20-error count
  guard.

Traces and logs are best effort: a missed export is not replayed, and both stores are disposable and
rebuildable from nothing but live traffic. Neither is a source of truth.

## Production runbook

The runbook (R0-R10) lives at [`docs/deployment-handoff.md`](docs/deployment-handoff.md), which is the single authoritative copy, proven end to end by a local production-topology rehearsal.
That document is also the entry point for the agent helping deploy this phase: it additionally covers the operating model, the current production topology, the R0 decision table, post-deployment verification, and known failure modes.

## Resolved decisions from the plan's risk list

- Production Postgres major version: pin `docker/postgres` to whatever R0 finds; `18` where R0 has
  not run yet.
- Postgres test images: stay on `postgres:16-alpine` for this phase; moving them is a separate
  follow-up chore.
- ClickHouse stays on the 26.3 LTS line until the host's CPU model changes; no source rebuild.
- Inbox retention: 14 days accepted, backed by the DLQ and target-down alerts making a multi-day
  consumer outage visible within minutes.
- The public `/actuator/health` endpoint on the application port is accepted as removed, unless R0
  finds an external monitor using it, in which case add
  `management.endpoint.health.group.liveness.additional-path=server:/livez` and permit it on the
  application chain.
- The Redis exporter uses the application's Redis password; accepted, it is internal-only.
- Docker socket exposure: accepted for cAdvisor (private, pinned image); the collector never touches
  the socket directly, only the socket proxy.
