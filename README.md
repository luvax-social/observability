# Observability stack (Phase 1)

Traces and logs over OpenTelemetry, metrics over Prometheus, dashboards and alerting in Grafana.
Phase 1 scope is monitoring only.

## Components

| Service | Role |
|---|---|
| `otel-collector` | Receives OTLP traces/logs from the backend and container log files, exports both to ClickHouse |
| `clickhouse` | Stores `otel.otel_logs` and `otel.otel_traces` (14 and 7 day TTL) |
| `prometheus` | Scrapes the backend's management port, RabbitMQ, Gorse, and every exporter below; 30 day retention |
| `grafana` | Ten provisioned dashboards, Discord-backed alerting, the only public component |
| `docker-socket-proxy` | Read-only, `CONTAINERS`/`EVENTS`/`PING`/`VERSION` only; the collector's only path to the Docker API |
| `postgres-exporter`, `redis-exporter`, `elasticsearch-exporter`, `node-exporter`, `cadvisor` | Infrastructure metrics for the dashboards above |

Total budget: 7.3 GB memory, 2.0 CPU across every service in this stack.

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
- Alerts: six baseline rules (DLQ not empty, outbox DEAD rows, an open circuit breaker, a container
  restart loop, disk above 85 percent, a scrape target down), delivered to a Discord channel.

Traces and logs are best effort: a missed export is not replayed, and both stores are disposable and
rebuildable from nothing but live traffic. Neither is a source of truth.

## Production runbook

Every step below has a read-only verification command. None of R1-R9 touches the production host,
Coolify or Cloudflare from this repository or its tooling; a human operator runs every command and
every UI step. `$PG`, `$ES`, `$RMQ`, `$REDIS`, `$GORSE` are the running containers' names; `$OBS` is
the `luvax-observability` resource's Coolify uuid, recorded in R5. Secrets are generated with
`openssl rand -base64 36 | tr -d '/+=' | cut -c1-40` and entered only into Coolify environment
variables, never committed.

### R0 - Read-only preflight (blocks everything else)

```bash
lscpu | grep -E 'Model name|Flags' | grep -o -E 'sse4_2|avx2?|fma' | sort -u
free -h && df -h /
docker info --format '{{.LoggingDriver}} {{json .LogConfig}} {{.ServerVersion}}'
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
docker inspect $PG --format '{{.Config.Image}}' && docker exec $PG postgres --version
docker exec $PG psql -U postgres -tAc "SELECT rolsuper FROM pg_roles WHERE rolname = current_user"
docker exec $PG psql -U postgres -tAc "SELECT name, setting, unit FROM pg_settings WHERE source = 'configuration file' ORDER BY name"
docker exec $PG psql -U postgres -tAc "SELECT datname FROM pg_database WHERE NOT datistemplate"
docker exec $RMQ rabbitmqctl version && docker exec $RMQ cat /etc/rabbitmq/enabled_plugins
docker exec $ES curl -s -o /dev/null -w '%{http_code} %{scheme}\n' -k https://localhost:9200 ; docker exec $ES curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9200
docker inspect $(docker ps -q --filter label=coolify.resourceName=luvax-prod) --format '{{json .Config.Labels}}' | jq 'with_entries(select(.key|startswith("coolify")))'
docker inspect $PG --format '{{json .Config.Labels}}' | jq 'with_entries(select(.key|startswith("coolify")))'
docker ps --filter name=cloudflared --format '{{.Names}} {{.Image}}'
systemctl status cloudflared --no-pager
systemctl cat cloudflared | grep -E '^ExecStart'
sudo awk '/^ingress:/{f=1} f' /etc/cloudflared/config.yml
```

Record the CPU flags (expect `sse4_2` only), the logging driver (must be `json-file`; anything else
blocks the container-log design), the Postgres image and major version (update the D9 pin if not 18),
whether the Postgres user is a superuser, the configuration-file settings, the application database
name, the RabbitMQ version and plugins, the Elasticsearch scheme, the backend's `coolify.resourceName`
(must be `luvax-prod`, or set `BACKEND_COOLIFY_RESOURCE_NAME` to whatever it is instead), and how
cloudflared runs.
The last three commands decide R8's management mode.
`systemctl status` confirms the unit is `luvax-tunnel` and active.
The `ExecStart` line shows whether the process runs with `--config /etc/cloudflared/config.yml` (locally managed) or with `tunnel run --token ...` and no `--config` flag (remotely managed, dashboard-configured).
The `ingress:` block, if `config.yml` has one, is the locally managed case; a `config.yml` with no `ingress:` key, or a missing file, means the tunnel's routing lives in the Zero Trust dashboard instead.
Redact the `credentials-file` path's contents and any inline `tunnel` secret or token before saving; the path and the ingress rules themselves are not secrets.
Save all of this to `.workspace/reports/p1/r0-facts.md`.

Rollback: none, this step is read-only.

### R1 - Host files, by script only

```bash
REPO_URL=https://github.com/zentech-graduation/Luvax.git BRANCH=main TARGET_DIR=/data/luvax/observability \
  bash observability/scripts/sync-to-host.sh
```

This is the only sanctioned way to place files on the host. It clones the branch, `rsync`s
`observability/` into `/data/luvax/observability`, and fixes the permissions
`compose.prod.yaml`'s bind mounts and the ClickHouse init script need. There is no separate
`cp targets/prod/*.yml targets/` step: `compose.prod.yaml` binds `/data/luvax/observability/prometheus/targets/prod`
directly, so nothing needs copying into a shared `targets/` directory.

Verification: `find /data/luvax/observability -type f | sort` lists every file under this
directory's tree, and `find /data/luvax/observability -type d -empty` prints nothing.

Rollback: `sudo rm -rf /data/luvax/observability`.

### R2 - Postgres custom configuration and restart

UI: Coolify, Postgres resource `rgtu7vdi4q9pfhtsbnldv89a`, Configuration, "Custom PostgreSQL
Configuration": paste every `name = value` line R0 captured from `source = 'configuration file'`,
then append:

```ini
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 10000
pg_stat_statements.track = top
track_io_timing = on
listen_addresses = '*'
```

Save, then Restart during a quiet period; expect a few seconds of 5xx while the backend's Hikari
pool reconnects.

Verification:

```bash
docker exec $PG psql -U postgres -tAc "SHOW shared_preload_libraries"
docker exec $PG psql -U postgres -tAc "SHOW max_connections"
docker inspect $PG --format '{{json .Config.Cmd}}'
```

Rollback: clear the field and Restart; Coolify deletes `custom-postgres.conf` and drops the
`-c config_file` argument.

### R3 - Extension and monitoring role

```bash
docker exec -i $PG psql -U postgres -d <app_db> -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE ROLE luvax_monitor WITH LOGIN PASSWORD '<POSTGRES_MONITOR_PASSWORD>' CONNECTION LIMIT 5;
GRANT pg_monitor TO luvax_monitor;
GRANT CONNECT ON DATABASE <app_db> TO luvax_monitor;
SQL
```

Verification: `docker exec $PG psql -U luvax_monitor -d <app_db> -h 127.0.0.1 -tAc "SELECT count(*) > 0 FROM pg_stat_statements"`
prints `t`; the same role reading `posts` fails with `permission denied`.

Rollback: `DROP ROLE luvax_monitor;` and, only if V126 has not run yet, `DROP EXTENSION pg_stat_statements;`.

### R4 - Elasticsearch exporter credentials

```bash
docker exec $ES curl -s -u "elastic:$ELASTIC_PASSWORD" -X PUT "<scheme>://localhost:9200/_security/role/luvax_monitoring" \
  -H 'Content-Type: application/json' \
  -d '{"cluster":["monitor"],"indices":[{"names":["*"],"privileges":["monitor"]}]}'
docker exec $ES curl -s -u "elastic:$ELASTIC_PASSWORD" -X PUT "<scheme>://localhost:9200/_security/user/luvax_monitor" \
  -H 'Content-Type: application/json' \
  -d '{"password":"<ES_MONITOR_PASSWORD>","roles":["luvax_monitoring"]}'
```

`$ELASTIC_PASSWORD` comes from the Elasticsearch service's Coolify environment.

Verification: `docker exec $ES curl -s -u luvax_monitor:<pw> <scheme>://localhost:9200/_cluster/health`
returns JSON with `status`; the same user searching `posts` gets a 403 `security_exception`.

Rollback: `DELETE /_security/user/luvax_monitor` then `DELETE /_security/role/luvax_monitoring`.

### R5 - Observability Coolify resource

1. Project of `luvax-prod`, New Resource, Docker Compose Empty, paste `observability/compose.prod.yaml`.
2. Enable "Connect To Predefined Network".
3. Environment variables: `CLICKHOUSE_OTEL_PASSWORD`, `CLICKHOUSE_GRAFANA_PASSWORD`,
   `GF_SECURITY_ADMIN_PASSWORD`, `GF_DISCORD_WEBHOOK_URL` (R9), `POSTGRES_MONITOR_PASSWORD`,
   `PG_STATS_HOST=rgtu7vdi4q9pfhtsbnldv89a`, `PG_STATS_DATABASE=<app_db>`, `ES_MONITOR_PASSWORD`,
   `ES_URI_SCHEME` (R0), `REDIS_PASSWORD` (from the Redis resource), `BACKEND_COOLIFY_RESOURCE_NAME`
   (R0), `LOG_CONTAINER_POSTGRES=rgtu7vdi4q9pfhtsbnldv89a`, `LOG_CONTAINER_REDIS=ijrhuhxwedr7y0pmjhputc5f`,
   `LOG_CONTAINER_RABBITMQ=rabbitmq-tcft7fbk5stgxgzc7bmtw1zt`,
   `LOG_CONTAINER_ELASTICSEARCH=elasticsearch-pzocsus3ji5bb3dqdjh8zqor`,
   `LOG_CONTAINER_GORSE=gorse-hf20neyfdkmee6ec1rzkknt2`.
4. Deploy, then record the resource uuid Coolify shows as `$OBS`.

Verification:

```bash
docker ps --filter "name=-$OBS" --format '{{.Names}}\t{{.Status}}'
docker exec prometheus-$OBS wget -qO- localhost:9090/-/ready
docker exec clickhouse-$OBS clickhouse-client --user otel_writer --password "$CLICKHOUSE_OTEL_PASSWORD" -q "SHOW TABLES FROM otel"
docker inspect clickhouse-$OBS --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}'
```

Rollback: Stop the resource, then Delete it with volumes; the host files from R1 remain for a retry.

### R6 - Backend deployment

Preconditions: the backend PR is merged, and R2 and R3 are done.

On the `luvax-prod` application:

1. Network Aliases: `luvax-backend`.
2. Environment: `OTLP_EXPORT_ENABLED=true`, `OTLP_ENDPOINT=http://otel-collector-$OBS:4318`,
   `MANAGEMENT_SERVER_PORT=8081`; delete `APP_SECURITY_PUBLIC_METRICS_ENDPOINT` if present.
3. Health check: if Coolify's health check is enabled, point it at port 8081, path `/actuator/health`.
4. Ports Exposes stays `8080`.
5. Redeploy.

Verification:

```bash
docker exec prometheus-$OBS wget -qO- 'localhost:9090/api/v1/query?query=up{job="luvax-backend"}'
docker exec $(docker ps -q --filter label=coolify.resourceName=luvax-prod) curl -s localhost:8081/actuator/health
curl -s -o /dev/null -w '%{http_code}' https://api.luvax.online/actuator/prometheus
docker exec clickhouse-$OBS clickhouse-client --user otel_writer --password "$CLICKHOUSE_OTEL_PASSWORD" -q "SELECT count() FROM otel.otel_traces WHERE ServiceName = 'luvax-backend' AND Timestamp > now() - INTERVAL 5 MINUTE"
```

Rollback: redeploy the previous image and remove the three env vars; V124-V126 are additive and need
no down migration.

### R7 - Cloudflare Access application and policy

Renumbered ahead of the tunnel hostname step (R8): the Access application must exist before the
public hostname is exposed, so the hostname is never reachable without Access even for one request.

Zero Trust, Access, Applications, Add, Self-hosted: name `Grafana`, domain `grafana.luvax.online`,
session 24 h, policy `owner` with action Allow and include "Emails" equal to the owner's address,
identity provider One-time PIN (or the account's existing IdP).

Verification: this step alone has nothing at `grafana.luvax.online` to test yet; R8's verification
covers both steps together.

Rollback: delete the Access application.

### R8 - Cloudflare Tunnel public hostname

Every public hostname on this tunnel routes through the Coolify proxy on the same host.
`api.luvax.online` only works with service `https://localhost:443`, HTTP Host Header equal to the
public hostname, TLS Origin Server Name equal to the public hostname, and HTTP/2 origin off.
Routing to `http://localhost:80` makes Coolify's own HTTP-to-HTTPS redirect loop back into the
tunnel, because the tunnel terminates TLS and Coolify's redirect sends the browser straight back to
the plain-HTTP hostname the tunnel exposes.
Copying only the `service` field from `api.luvax.online`, as an earlier revision of this step did,
drops the Host Header and Origin Server Name and produces either that loop or a TLS name mismatch,
because the proxy's TLS listener uses SNI/Host Header to pick which resource's certificate to serve.
The rule for `grafana.luvax.online` must mirror `api.luvax.online`'s origin settings with its own
hostname in Host Header and Origin Server Name, and it must sit before the catch-all rule, the same
place every hostname rule on this tunnel sits.
R0's `ExecStart` and `config.yml` checks decide which of the two procedures below applies.

**Locally managed** (`config.yml` has an `ingress:` block and `ExecStart` passes `--config`):

1. Back up the file: `sudo cp /etc/cloudflared/config.yml /etc/cloudflared/config.yml.bak.$(date +%s)`.
2. Add this block to the `ingress` list, immediately above the existing catch-all (`service: http_status:404` or similar) entry, keeping `api.luvax.online`'s entry as the pattern:

   ```yaml
   - hostname: grafana.luvax.online
     service: https://localhost:443
     originRequest:
       httpHostHeader: grafana.luvax.online
       originServerName: grafana.luvax.online
       http2Origin: false
   ```

3. Validate before restarting: `cloudflared tunnel ingress validate`.
4. Confirm the new hostname resolves to this rule and not the catch-all: `cloudflared tunnel ingress rule https://grafana.luvax.online`.
5. If `dig grafana.luvax.online CNAME +short` prints nothing, add the DNS route before restarting: `cloudflared tunnel route dns luvax-tunnel grafana.luvax.online`.
6. Apply: `sudo systemctl restart cloudflared`.

Rollback: `sudo cp /etc/cloudflared/config.yml.bak.<timestamp> /etc/cloudflared/config.yml && sudo systemctl restart cloudflared`; delete the DNS route with `cloudflared tunnel route dns` reversed via the Zero Trust dashboard if step 5 created one.

**Remotely managed** (`ExecStart` passes `tunnel run --token ...` and `config.yml` has no `ingress:` block, or does not exist):

1. Zero Trust, Networks, Tunnels, `luvax-tunnel`, Public Hostname, Add: subdomain `grafana`, domain `luvax.online`, service `https://localhost:443`.
2. Under "Additional application settings", TLS: set Origin Server Name to `grafana.luvax.online`.
3. Under "Additional application settings", HTTP Settings: set HTTP Host Header to `grafana.luvax.online` and disable HTTP/2 connections to origin.
4. Save. The dashboard always evaluates added hostnames before the catch-all rule, so no manual reordering is needed.
5. If the hostname was never routed before, the dashboard creates its DNS record automatically on save; confirm with `dig grafana.luvax.online CNAME +short`.

Rollback: delete the public hostname entry from the dashboard, which also removes the DNS record it created.

Verification, both modes: an unauthenticated request must redirect to Access, never return Grafana's
own login page and never loop.
`curl -sIL --max-redirs 5 https://grafana.luvax.online` must terminate on a `*.cloudflareaccess.com`
response rather than exhausting its redirect budget, and every hop must be a clean `30x` with no TLS
handshake error.
A private browser window shows the Access login, and Grafana's own login appears only after the PIN.

### R9 - Discord webhook and alert test

Discord, target channel, Edit Channel, Integrations, Webhooks, New Webhook, name `Luvax Grafana`,
copy the URL into `GF_DISCORD_WEBHOOK_URL` on the observability resource, redeploy only the
`grafana` service.

Verification: Grafana, Alerting, Contact points, `discord`, Test sends a message to the channel;
then run production check P5 (section 8.2 of the observability plan).

Rollback: delete the webhook in Discord and clear the variable; rules keep evaluating with no
delivery.

### R10 - Final verification

Run section 8.2 (P1-P7) of the observability plan and store screenshots and outputs under
`.workspace/reports/p1/prod/`.

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
