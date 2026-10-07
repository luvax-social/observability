<p align="center">
  <a href="https://luvax.online/" target="_blank"><img src="docs/asset/luvax-logo-warm.svg" height="90" alt="Luvax" /></a>
</p>

<p align="center">
  <strong>Monitoring, telemetry and analytics infrastructure for Luvax.</strong>
</p>

[Luvax](https://github.com/luvax-social/social-media-platforms) ·
[Backend](https://github.com/luvax-social/backend) ·
[Frontend](https://github.com/luvax-social/frontend)

## About

This repository contains the configuration and deployment files for Luvax observability. It
collects application traces and logs with OpenTelemetry, gathers infrastructure and application
metrics with Prometheus, and presents dashboards and alerts in Grafana. ClickHouse stores
telemetry and the platform analytics data consumed by the backend and Grafana.

Observability data is operational data, not a source of truth. Trace and log export is best
effort; missed telemetry is not replayed. See the workspace's
[shared rules](https://github.com/luvax-social/social-media-platforms/blob/main/.agents/rules/GLOBAL_RULES.md)
for retention and data-tier details.

## Stack

| Service | Role |
|---------|------|
| OpenTelemetry Collector | Receives OTLP traces and metrics from the backend, and collects container logs. |
| ClickHouse | Stores traces, logs and Luvax analytics data. |
| Prometheus | Scrapes application, host, container and datastore metrics. |
| Grafana | Provides dashboards, alert rules and notification delivery. |
| Node Exporter and cAdvisor | Export host and container metrics. |
| PostgreSQL, Redis and Elasticsearch exporters | Export datastore health and performance metrics. |
| Blackbox Exporter | Probes production origin TLS certificates. |

Grafana dashboards are provisioned from [`dashboards/`](dashboards/) and grouped into
Infrastructure, Backing Services, Messaging, Application, Explore and Business folders.
Prometheus and Grafana configuration is in [`prometheus/`](prometheus/) and
[`grafana/`](grafana/).

## Local development

Requirements: Docker with the Compose plugin, and the Luvax backend repository. Start the
backend's local infrastructure first; the observability Compose file joins its `luvax-local`
network and reads metrics and logs from those containers.

1. Create `observability/.env` from the example and set local passwords:

   ```bash
   cp observability/.env.example observability/.env
   ```

   The example values are placeholders. Replace `change-me` before starting the services. Leave
   `GF_DISCORD_WEBHOOK_URL` empty to disable local alert delivery.

2. Start the backend infrastructure, then start observability from the workspace root:

   ```bash
   cd backend
   docker compose up -d
   cd ..
   docker compose --env-file observability/.env -f observability/compose.local.yaml --profile observability up -d
   ```

3. Open the local tools:

   | Tool | URL | Login |
   |------|-----|-------|
   | Grafana | <http://localhost:3000> | `admin` / `GF_SECURITY_ADMIN_PASSWORD` from `.env` |
   | Prometheus | <http://localhost:9090> | No login configured locally |
   | ClickHouse HTTP | <http://localhost:8123> | `otel_writer` / `CLICKHOUSE_OTEL_PASSWORD` from `.env` |

The backend must be configured to export OTLP to `http://localhost:4317` (gRPC) or
`http://localhost:4318` (HTTP) for its telemetry to appear. Local Prometheus scrapes the backend
and the supporting services on the Docker network. All published ports bind to loopback.

Stop the stack with:

```bash
docker compose --env-file observability/.env -f observability/compose.local.yaml --profile observability down
```

Named Docker volumes retain ClickHouse, Prometheus and Grafana data when the containers stop.
Use `docker compose down -v` only when you intend to delete that local data.

## Production deployment

Production is managed through Coolify. This repository contains Compose definitions for the core
stack and the split exporter resources described in the Phase 1.5 cutover runbook. The production
Compose files use host bind mounts under
`/data/luvax/observability`; `scripts/sync-to-host.sh` syncs the repository to that location.
Production deployment is an operator-run procedure with verification and rollback gates. Follow
the [production deployment runbook](docs/production-deployment-runbook.md) to confirm the current
deployment stage and procedure before changing the live stack. Do not use the local Compose file
for production.

Production credentials belong in Coolify environment variables. Never commit `.env` files or
secrets. [`.env.example`](.env.example) documents the variables used by the stack; its values
are placeholders, not credentials.

## Repository layout

| Path | Contents |
|------|----------|
| `compose.local.yaml` | Optional local stack, attached to the backend's Docker network. |
| `compose.prod.yaml` and `compose.*.prod.yaml` | Production Coolify resources for the core stack and split exporters. |
| `otel-collector/` | OpenTelemetry Collector pipelines and processors. |
| `clickhouse/` | ClickHouse configuration, telemetry schema setup and analytics initialization. |
| `prometheus/` | Scrape jobs, alert rules and local/production targets. |
| `grafana/` | Datasources, dashboard providers, alerting and Grafana settings. |
| `dashboards/` | Provisioned Grafana dashboard definitions. |
| `blackbox-exporter/` | Production origin TLS probe configuration. |
| `docs/production-deployment-runbook.md` | Production topology, rollout, verification and rollback procedures. |
| `scripts/` | Host synchronization helper. |
