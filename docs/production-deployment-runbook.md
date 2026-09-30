# Luvax observability production deployment runbook

This runbook describes the production monitoring and analytics topology, deployment steps,
verification gates, rollback, and known failure modes. Read the relevant stage in full before
changing production. Commands run on the production host over Tailscale SSH unless a step says
to use the Coolify or Cloudflare UI. Check repository files such as `compose.prod.yaml` against
the deployed revision before applying them.

## 1. Purpose and scope

Phase 1 (deployed) added monitoring only: traces and logs over OpenTelemetry, metrics over Prometheus, dashboards and alerting in Grafana.
Phase 1.5 (the runbook of section 6) splits the single `luvax-observability` Coolify resource into five resources, moves scrape discovery from static targets to Prometheus `docker_sd_configs`, regroups the ten dashboards into five category folders, and adds five alert rules.
Neither phase touches the frontend or Phase 3.
Phase 2 (this document's active runbook, section 11) puts analytics on the same ClickHouse instance, adds the Business dashboards and three alert rules, and adds an operator-triggered Gorse rebuild.
It ships with a backend release that changes PostgreSQL (Flyway V127 to V133), so it is deployed with the release and reseeded afterwards; the frontend gains one line under the audit log's date range in its own release.
The backend changes from Phase 1 (OTLP export, the private management port, outbox/inbox metrics, `pg_stat_statements`) are already merged and deployed; Phase 1.5 makes no backend code change.
Phase 2 is the first phase since Phase 1 to change backend code.

## 2. Operating model

- **The operator performs every action.** That includes every Coolify and Cloudflare UI change and every shell command on the host. Check each step's expected output and gate before proceeding.
- **One step at a time.** Complete and verify one runbook step (or sub-step) before starting the next write step.
- **Read-only versus write.** Commands marked **[WRITE]** change production. Review what each changes and its rollback before running it. Unmarked commands are read-only diagnostics.
- **Secrets stay on the host.** Generate and enter passwords, API keys, tokens, and webhook URLs directly on the host or in Coolify. Commands that need a secret use a local shell variable, for example `read -rs POSTGRES_MONITOR_PASSWORD; export POSTGRES_MONITOR_PASSWORD`, so the value does not appear in command text or shell history. Redact secrets from shared output and rotate any that were exposed.
- **Do not guess.** If output does not match the expected result, stop, diagnose with read-only commands, and consult section 9 before changing anything. If a fact this file assumes (a container name, a version, a setting) differs from the host, the host wins.
- **Record keeping.** Record findings, deviations, and verification results in the deployment record.

## 3. Current production topology

### Host constraints

- CPU: SSE4.2 only, no AVX2, no FMA. This is why ClickHouse is pinned (see section 9).
- 8 cores, 32 GB RAM.
- No public ports. The only path in is Cloudflare Tunnel `luvax-tunnel`; the only path for administration is Tailscale.
- Every resource in this document runs on this one host, under Coolify 4.3.23.

### Coolify conventions this deployment depends on

- Every resource Coolify manages carries `coolify.type`, `coolify.resourceName` and (for a compose service) `coolify.serviceName` labels.
  `docker inspect <container> --format '{{json .Config.Labels}}' | jq 'with_entries(select(.key|startswith("coolify")))'` reads them.
- A Coolify Docker Compose resource's bind mounts must point at files that already exist on the host.
  A bind mount whose source path is missing does not fail the deploy - Docker silently creates an empty **directory** at that path instead, and everything downstream that expected a file there breaks in a way that looks unrelated to the missing file (see section 9).
- Two Coolify resources can resolve each other by container name only if both are attached to the same Docker network.
  Every resource in this deployment is attached to the shared external network named `coolify` (enabled per-resource with the "Connect To Predefined Network" toggle); a resource left off that network cannot be reached by name from any other resource.
- A Coolify **Application** resource (the backend) gets a stable **network alias** (`luvax-backend`) rather than a stable container name; the container name itself changes on every deploy.
  A Coolify **Docker Compose** resource's container name changes on every recreate too, to `<service>-<resource-uuid>`; the uuid is stable for the life of the resource, but a redeploy that recreates the container keeps the same name (Coolify does not rotate the resource's own uuid on redeploy) - only a genuinely new resource gets a new uuid.
  This is why Phase 1.5's exporter discovery (section 6) addresses containers by name via `docker_sd_configs`, not by a hardcoded static target.

### Resource hostnames (container names) this deployment refers to by name

| Resource | Container name | Role |
|---|---|---|
| Postgres | `rgtu7vdi4q9pfhtsbnldv89a` | Application database, source of truth |
| Redis | `ijrhuhxwedr7y0pmjhputc5f` | Cache, sessions, rate limiting |
| RabbitMQ | `rabbitmq-tcft7fbk5stgxgzc7bmtw1zt` | Event bus |
| Elasticsearch | `elasticsearch-pzocsus3ji5bb3dqdjh8zqor` | Search index |
| Gorse | `gorse-hf20neyfdkmee6ec1rzkknt2` | Recommendation engine |
| Backend | `coolify.resourceName=luvax-prod`, network alias `luvax-backend` | Application |
| Observability (core) | uuid recorded as `$OBS`; every service container is named `<service>-$OBS` | Monitoring stack: ClickHouse, Prometheus, Grafana, OTel Collector, socket proxy, blackbox exporter |
| Observability (host) | uuid recorded as `$OBSHOST`; `node-exporter-$OBSHOST`, `cadvisor-$OBSHOST` | Host and container metrics (Phase 1.5) |
| Observability (postgres exporter) | uuid recorded as `$OBSPG`; `postgres-exporter-$OBSPG` | Postgres metrics (Phase 1.5) |
| Observability (redis exporter) | uuid recorded as `$OBSREDIS`; `redis-exporter-$OBSREDIS` | Redis metrics (Phase 1.5) |
| Observability (elasticsearch exporter) | uuid recorded as `$OBSES`; `elasticsearch-exporter-$OBSES` | Elasticsearch metrics (Phase 1.5) |
| Coolify proxy | not yet recorded - discover with Phase 1.5 step P0 below | Terminates the Cloudflare Tunnel's TLS connection to every hostname; the origin the new TLS-expiry probe targets |

Confirm every name above against the real host before relying on it (`docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'`).
The table is what past sessions found, not a guarantee.

### The `api.luvax.online` tunnel origin settings, and why routing to port 80 loops

Every public hostname on `luvax-tunnel` routes through the Coolify proxy on the same host.
The `api.luvax.online` rule works only because it points at `https://localhost:443` with the HTTP Host Header and TLS Origin Server Name both set to `api.luvax.online`, and HTTP/2 to origin turned off.
Any new hostname rule must mirror this shape exactly, with its own hostname in place of `api.luvax.online`, and it must sit before the tunnel's catch-all rule.

Routing to `http://localhost:80` instead loops: the tunnel terminates TLS and forwards a plain HTTP request to Coolify's proxy, and Coolify's proxy responds to plain HTTP with its own redirect to HTTPS on the *same public hostname* - which the browser follows back through the tunnel, which terminates TLS and forwards plain HTTP again.

### Cloudflare Access and Tunnel gotchas found during the real Phase 1 deployment

These are production facts, not assumptions; they were discovered deploying `grafana.luvax.online` and apply to any future hostname on this tunnel.

- **ACME bypass application.** `grafana.luvax.online` needs a second Cloudflare Access application scoped to `/.well-known/acme-challenge/*` with a Bypass policy (Include: Everyone).
  The Access UI in use cannot scope a single policy to a path inside one application, so the ACME challenge path needs its own application, separate from the main login-gated one.
  Without this, Let's Encrypt's HTTP-01 challenge is intercepted by Access and certificate renewal fails silently until the certificate expires.
- **UI route precedence.** The tunnel is locally managed (`config.yml` with an `ingress:` block), but `grafana.luvax.online` has a dashboard-managed route ("Published application routes" in Zero Trust) that takes precedence over `config.yml` for that hostname.
  Origin changes for `grafana.luvax.online` are made in the Zero Trust dashboard only; editing `config.yml` for that hostname has no effect until the dashboard-managed route is removed.
- **No TLS Verify is On for `grafana.luvax.online`**, because Traefik (the Coolify proxy) presents its own internal default certificate (`*.traefik.default`) for that hostname, not a real origin certificate matching `grafana.luvax.online`.
  Leaving No TLS Verify Off produces a 502 with a certificate-name mismatch, because `cloudflared` refuses to validate a certificate that does not match the hostname it requested.
- **`api.luvax.online` and the apex `luvax.online`** remain file-managed (`config.yml`), with No TLS Verify Off, and a real P0.5 discovery run confirmed both present a real Let's Encrypt certificate (issuer `Let's Encrypt`, expiring Dec 20 2026 at the time of that run). This is exactly why the Phase 1.5 TLS-expiry probe (section 6) targets these two.
- **`www.luvax.online` and `coolify.luvax.online` also present `CN = TRAEFIK DEFAULT CERT`**, the same shape as `grafana.luvax.online`, found by the same P0.5 run - not an assumption carried over from the original runbook, which incorrectly assumed all four non-`grafana` hostnames had real certificates. Both are excluded from the TLS-expiry probe for the same reason `grafana.luvax.online` is.
  **This is flagged, not silently resolved**: if either hostname is a real traffic path with No TLS Verify Off (as section 3's Coolify conventions describe for "other hostnames" generally), a client-validated connection to it should be failing with a certificate-name mismatch right now, the same failure mode described above for `grafana.luvax.online` before its No TLS Verify was turned on. Check with `curl -sIL https://www.luvax.online` and `curl -sIL https://coolify.luvax.online` whether either is broken or neither carries real traffic. If either is broken, diagnose and fix its Cloudflare Tunnel configuration as a separate change.

## 4. Phase 1, deployed: history

Phase 1 (traces, logs, metrics, dashboards, alerting) was deployed to production and is live.
Full runbook detail (R0-R10, the original per-step commands) lived in earlier revisions of this document. It is condensed here because the deployment is complete and stable.

- **R0-R1**: preflight confirmed host facts (Postgres 18, `json-file` logging, Elasticsearch on plain HTTP, `luvax-prod` as the backend's `coolify.resourceName`), then `scripts/sync-to-host.sh` populated `/data/luvax/observability` on the host.
- **R2-R4**: Postgres gained `pg_stat_statements` and a read-only `luvax_monitor` role (plus the `gorse` database, which nothing else provisions); Elasticsearch gained a read-only `luvax_monitor` user.
- **R5**: the single `luvax-observability` Coolify resource (ClickHouse, Prometheus, Grafana, OTel Collector, socket proxy, and five exporters - ten containers) deployed from `compose.prod.yaml`, attached to the shared `coolify` network.
- **R6**: the backend redeployed with OTLP export on, a private management port (8081), and the public port's actuator endpoints removed.
- **R7-R9**: a Cloudflare Access application gated `grafana.luvax.online`; the tunnel's public hostname was added (see the gotchas above, discovered during this step); the Discord webhook was wired into Grafana's alerting contact point.
- **R10**: full verification (P1-P7) passed: every Prometheus target up, public endpoints answering correctly, one continuous trace end to end, container logs present in ClickHouse, the DLQ alert firing and resolving, all ten dashboards rendering cleanly at two resolutions, and every container under its resource budget.

This deployed state - one `luvax-observability` resource, ten containers, one flat "Luvax" Grafana folder, six alert rules - is what the Phase 1.5 runbook below starts from and replaces.

## 5. Redis key patterns, media flow, and other cross-cutting facts

Unchanged by both phases; see the root workspace's `GLOBAL_RULES.md` and `STRUCT.md` for the parts of the system this observability stack watches but does not own.

## 6. Phase 1.5 runbook: five-resource split, docker_sd discovery, dashboard folders, new alerts

### What changes and why

- The single `luvax-observability` resource splits into five: the shrunk core resource plus `luvax-observability-host` (node-exporter, cadvisor), `luvax-postgres-exporter`, `luvax-redis-exporter`, and `luvax-elasticsearch-exporter`.
  Splitting lets each datastore exporter's credential be rotated, and each resource redeployed, independently of the others and of Prometheus/Grafana.
- Prometheus discovers the four split exporters via `docker_sd_configs` against the existing socket proxy (which gains `NETWORKS: 1`), addressed by **container name**, not container IP, and with no network "keep" relabel rule.
  A Coolify compose container attaches to its own resource's network as well as `coolify`; Prometheus's docker discovery emits exactly one target, addressed on whichever network the container was created with first, which is not guaranteed to be `coolify`.
  Addressing by name sidesteps this: Docker DNS resolves a container's name for every container sharing a network with it, regardless of which network was "first". This was proven in local rehearsal (section 8) both at initial deploy and after a recreate that changed the container's name.
- A new `blackbox-exporter` probes the Coolify proxy's **origin** TLS certificate per hostname - not the public `https://<host>` edge, which only ever measures Cloudflare's own certificate and would never have caught the ACME-bypass gotcha above.
- Ten dashboards regroup from one flat folder into five: Infrastructure, Backing Services, Messaging, Application, Explore.
  A sixth folder, **Business**, is reserved for Phase 2 (platform statistics, admin actions, user events); it is created by the Phase 2 runbook (section 11), not by this one.
- Five new alert rules join the six existing ones (unchanged): origin TLS certificate expiring, a stalled RabbitMQ queue, a stalled outbox publisher, an unhealthy Elasticsearch cluster, and a high backend 5xx rate.
  A nested `severity=critical` routing policy gives critical alerts a 1-hour repeat interval; warning-severity alerts keep the existing 4-hour default.
- The alert-rule provisioning group moves from folder "Luvax" to its own new "Alerting" folder.
  This is necessary, not cosmetic: alert rule groups share the same folder namespace as dashboards, and the old "Luvax" folder is deleted once empty (step P8 below) - leaving the rule group parented there would have orphaned it.

### Migration model: single cutover, not per-category

Earlier planning considered migrating one exporter category at a time, with preview jobs and several redeploys of the core resource.
That costs more operator steps than the bounded metrics gap it avoids, and production data is seeded, so a short gap is acceptable.
The sequence below is one cutover: create the four new resources first (harmless coexistence with the still-running old exporters), then one single redeploy of the core resource with every change at once.

### P0 - Discover the Coolify proxy container (read-only, before the cutover)

Operator: run the commands and check the output.

The blackbox-exporter's origin-TLS probe (see below) needs the Coolify proxy's real container name and network.
This document does not have that fact recorded yet.

```bash
docker ps --format '{{.Names}}\t{{.Image}}' | grep -i -E 'proxy|traefik|coolify-proxy'
docker inspect <candidate-name> --format '{{json .NetworkSettings.Networks}}' | jq 'keys'
```

Expected: a container whose image is Coolify's proxy (commonly Traefik-based, often named `coolify-proxy`), attached to the `coolify` network.
Record its name as `$PROXY` for the steps below.
If more than one container matches, confirm which one actually terminates TLS for `api.luvax.online` (the one already proven working) before proceeding.

Gate before P1: `$PROXY` is a real, running container name, attached to `coolify`.

### P0.5 - Record the origin certificate per hostname (read-only, before the cutover)

Operator: run the commands and check the output.

**Already run once**, against production, with the results below. `blackbox-exporter/config.yml` and the `blackbox-origin-tls` job in `prometheus/prometheus.prod.yml` already reflect this outcome (two modules/targets, not four). Re-run before the real cutover only to catch drift since that run - a certificate can be renewed or a hostname's routing can change between this document being written and the day of the cutover.

```bash
for h in api.luvax.online luvax.online www.luvax.online coolify.luvax.online; do
  echo "== $h =="
  openssl s_client -connect localhost:443 -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -issuer -enddate
done
```

Result of the run this document was written from:

| Hostname | Issuer | Expiry | In the probe? |
|---|---|---|---|
| `api.luvax.online` | Let's Encrypt | Dec 20 2026 | Yes |
| `luvax.online` (apex) | Let's Encrypt | Dec 20 2026 | Yes |
| `www.luvax.online` | `CN = TRAEFIK DEFAULT CERT` | Sep 26 2027 | No - see section 3's flagged open question |
| `coolify.luvax.online` | `CN = TRAEFIK DEFAULT CERT` | Sep 26 2027 | No - see section 3's flagged open question |

**If a re-run before the real cutover shows different results** (for example, `www.luvax.online` now presents a real Let's Encrypt certificate), update `blackbox-exporter/config.yml` and the `blackbox-origin-tls` job to match - add or remove a module/target pair, do not silently leave this document's table stale.

Gate before P1: all four hostnames' issuer and expiry are recorded (or excluded, with a note) for the run closest to the actual cutover.

### P1 - Record the rollback point (read-only)

```bash
cat /data/luvax/observability/.git-commit 2>/dev/null || echo "not recorded - check which observability commit is currently deployed"
```

If the host has no record of the deployed commit, check the `luvax-observability` resource's configured branch/commit in the Coolify UI, or the last commit merged to `observability`'s `main` before deployment.
Record it as `$ROLLBACK_SHA`.

Gate before P2: `$ROLLBACK_SHA` is recorded.

### P2 - Sync the new repository content to the host [WRITE]

```bash
REPO_URL=https://github.com/luvax-social/observability.git BRANCH=main TARGET_DIR=/data/luvax/observability \
  bash scripts/sync-to-host.sh
```

Verification: `find /data/luvax/observability -type d -empty` prints nothing (see section 3's bind-mount warning).
Confirm the five compose files exist: `ls /data/luvax/observability/compose*.yaml` shows `compose.prod.yaml`, `compose.host.prod.yaml`, `compose.postgres-exporter.prod.yaml`, `compose.redis-exporter.prod.yaml`, `compose.elasticsearch-exporter.prod.yaml`.

Before continuing, edit `/data/luvax/observability/prometheus/prometheus.prod.yml` on the host: replace every `<COOLIFY_PROXY_CONTAINER>` placeholder with `$PROXY` from P0.
`www.luvax.online` and `coolify.luvax.online` are already excluded from the synced files, per P0.5's run; only touch the target/module lists again if a re-run of P0.5 closer to the cutover shows different results than its recorded table.

Rollback: `sudo rm -rf /data/luvax/observability` (the old resource is still running and unaffected).

Gate before P3: both verification commands pass and the placeholder substitution is done.

### P3 - Create and deploy the four new resources [WRITE]

Operator (UI), one resource at a time. For each, Project `luvax-prod`, New Resource, Docker Compose Empty, paste the matching compose file **unmodified** (`compose.host.prod.yaml`, `compose.postgres-exporter.prod.yaml`, `compose.redis-exporter.prod.yaml`, `compose.elasticsearch-exporter.prod.yaml`), enable "Connect To Predefined Network", copy the matching environment variables from the current `luvax-observability` resource's own environment (the same values, since these exporters previously ran inside it), deploy.

This is safe to do while the old core resource keeps running its own copies of these same exporters: nothing scrapes the new ones yet, and two read-only exporters against one datastore do not conflict.

Verification, per resource:

```bash
docker ps --filter "name=<service>-" --format '{{.Names}}\t{{.Status}}'
```

Expected: one container per new resource, `Up`.
Record each resource's uuid as `$OBSHOST`, `$OBSPG`, `$OBSREDIS`, `$OBSES`.

Rollback: Stop and Delete each new resource; the old core resource's own exporters are untouched.

Gate before P4: all four new resources show their container `Up`.

### P4 - Single redeploy of the core resource [WRITE]

Operator (UI). Open the `luvax-observability` resource, replace its compose content with the new (shrunk) `compose.prod.yaml`, replace `prometheus/prometheus.prod.yml`, `grafana/provisioning/dashboards/dashboards.yaml`, `grafana/provisioning/alerting/rules.yaml`, and `grafana/provisioning/alerting/policies.yaml` with their new versions (already synced to the host in P2), and Redeploy.

This single redeploy carries every change: exporter services removed from this resource's compose file, `NETWORKS: 1` added to the socket proxy, `blackbox-exporter` added, the new Prometheus scrape config, the new dashboard folders, and the new/moved alert rules.

Verification:

```bash
docker exec prometheus-$OBS wget -qO- localhost:9090/api/v1/targets
```

Expected: one target per job, `up=1`, including the new `luvax-exporters` docker_sd job (four targets, one per split exporter, addressed by the new resources' container names) and the new `blackbox-origin-tls` job.

Rollback: see P8 below (this step's rollback is the same as the whole runbook's).

Gate before P5: every target in the response is `up=1` (except any job already known down for an unrelated, out-of-scope reason - see section 9).

### P5 - Remove leftover old exporter containers [WRITE]

Coolify does not remove containers for services deleted from a compose file; the redeploy in P4 only affects services still declared in the new file.

```bash
docker ps --filter "name=-$OBS" --format '{{.Names}}\t{{.Status}}'
```

**Expected finding**: the old `postgres-exporter-$OBS`, `redis-exporter-$OBS`, `elasticsearch-exporter-$OBS`, `node-exporter-$OBS`, and `cadvisor-$OBS` containers are still `Up`, orphaned from the resource's own compose file.
This was proven in local rehearsal (section 8): a redeploy that removes services from a compose file does not stop or remove their old containers.

Remove them:

```bash
docker rm -f postgres-exporter-$OBS redis-exporter-$OBS elasticsearch-exporter-$OBS node-exporter-$OBS cadvisor-$OBS
```

Verification: re-run the `docker ps` filter above; it prints only the six current core-resource containers (clickhouse, prometheus, grafana, otel-collector, docker-socket-proxy, blackbox-exporter).

Rollback: these containers are not recreated by a rollback of P4-P5; a full rollback (P8) redeploys the core resource from `$ROLLBACK_SHA`, which recreates them as part of that old compose file.

Gate before P6: the `docker ps` filter shows exactly the six current core containers, no leftover exporter.

### P6 - Verify Grafana folders and dashboards

```bash
curl -s -u admin:$GF_ADMIN_PASSWORD http://localhost:3000/api/folders
curl -s -u admin:$GF_ADMIN_PASSWORD "http://localhost:3000/api/search?type=dash-db"
```

Expected: six folders (`Infrastructure`, `Backing Services`, `Messaging`, `Application`, `Explore`, `Alerting`), plus the old `Luvax` folder still present but about to be deleted.
Exactly ten dashboards, each now inside one of the five category folders, same `uid`s as before (no duplicate, no orphan).

Gate before P7: dashboard count is exactly ten, and every one has moved to a new folder.

### P7 - Delete the empty legacy "Luvax" folder [WRITE]

```bash
LUVAX_UID=$(curl -s -u admin:$GF_ADMIN_PASSWORD http://localhost:3000/api/folders | jq -r '.[] | select(.title=="Luvax") | .uid')
curl -s -u admin:$GF_ADMIN_PASSWORD "http://localhost:3000/api/search?folderUIDs=$LUVAX_UID"
```

Expected: the search returns `[]` - empty.
**Also confirm no alert rule is still parented there** (the folder-namespace trap described above):

```bash
curl -s -u admin:$GF_ADMIN_PASSWORD "http://localhost:3000/api/v1/provisioning/alert-rules" | jq "[.[] | select(.folderUID==\"$LUVAX_UID\")]"
```

Expected: `[]`.
Only once both checks return empty:

```bash
curl -s -u admin:$GF_ADMIN_PASSWORD -X DELETE "http://localhost:3000/api/folders/$LUVAX_UID"
```

Expected: `{"message":"Folder deleted"}`.

Rollback: cannot be un-deleted directly, but it was empty; a full rollback (P8) recreates it via the old `dashboards.yaml` provisioning on the next redeploy from `$ROLLBACK_SHA`.

Gate before P8/verification: folder deleted, six folders remain (the five dashboard category folders plus Alerting), and `Luvax` no longer appears in the folder list.

### P8 - Rollback (if needed)

1. Redeploy the `luvax-observability` core resource from `$ROLLBACK_SHA` (the commit recorded in P1).
   This restores the old compose file (ten services in one resource), the old Prometheus static targets, the old flat dashboard provisioning, and the old alert-rule folder.
2. Delete the four new resources created in P3 (Stop, then Delete with volumes).
3. Also remove `blackbox-exporter-$OBS` if it is still running: it is not part of the old compose file either, and step 1's redeploy leaves it orphaned by the same mechanism documented in P5.
4. The five folders created by the new dashboard and alert-rule provisioning (`Infrastructure`, `Backing Services`, `Messaging`, `Application`, `Alerting` - and `Explore`, six in total) are **not** removed by step 1's redeploy; they become empty orphans, the same way the old `Luvax` folder did going forward. If a full rollback to the pre-migration state is wanted, delete each with the same three-step sequence as P7 (confirm empty, then `DELETE /api/folders/<uid>`), once dashboards have re-homed back into `Luvax`.

Verification: `docker exec prometheus-$OBS wget -qO- localhost:9090/api/v1/targets` shows the old static job names again, all `up=1`; the Grafana folder list shows the single "Luvax" folder again with all ten dashboards inside it (proven in local rehearsal, section 8).

## 7. Phase 1.5 post-deployment verification

Run after P0-P7.

| # | Check | Command / action | Expected |
|---|---|---|---|
| V1 | Every target up, one per exporter | `docker exec prometheus-$OBS wget -qO- localhost:9090/api/v1/targets` | Every job `up=1`; exactly one target per split exporter, addressed by its container name |
| V2 | Five folders, no legacy folder | `GET /api/folders` | `Infrastructure`, `Backing Services`, `Messaging`, `Application`, `Explore`, `Alerting`; no `Luvax` |
| V3 | Dashboard links working | Open `trace-explorer`, click "Logs for trace" and "Open trace" on a real trace row | Both navigate to the correct dashboard, no 404 |
| V4 | Critical routing provisioned | `GET /api/v1/provisioning/policies` | The nested route matching `severity=critical` with `repeat_interval: 1h` is present |
| V5 | One safe synthetic alert per new rule | See table below | Fires, then resolves |

Synthetic alert triggers, safety-classified for production:

| Rule | Safe to trigger in production? | Trigger |
|---|---|---|
| Origin TLS certificate expiring | Rehearsal-verified only | Real certificates cannot be safely aged in production; verified locally against a stand-in with a genuinely short-lived certificate (section 8) |
| RabbitMQ queue stalled | Safe | Publish one message to a low-traffic real queue, pause its consumer briefly (do not use a queue any user-facing flow depends on), confirm fire, resume |
| Outbox publish stalled | Rehearsal-verified only | Requires blocking the backend's real RabbitMQ connectivity, which would affect real traffic; verified locally instead |
| Elasticsearch cluster unhealthy | Rehearsal-verified only | Requires degrading the real search cluster; verified locally instead |
| Backend 5xx rate high | Rehearsal-verified only | Requires a real downstream failure affecting real users; verified locally instead |

## 8. Local rehearsal evidence (Phase 1.5)

Proven in a disposable local topology outside any tracked repository, not on the production host:

- The single-cutover sequence (P1-P8 above) executed literally: old single-resource state deployed first, the four new resources created and coexisting harmlessly with the still-running old exporters, one redeploy of the core resource, the leftover-old-exporter finding reproduced exactly as documented and cleared with the given command, the legacy folder confirmed empty of both dashboards and alert rules before deletion, and a full rollback executed and verified to restore the old state.
- The container-name addressing proof: each split exporter, attached to both its own resource network and `coolify` at creation (replicating Coolify's real attachment order), yielded exactly one Prometheus target with `up=1`; recreating one exporter under a new container name (simulating a redeploy) converged to exactly the new target within one `docker_sd_configs` refresh cycle, with no lingering old target.
- The origin-TLS probe design, proven against a local TLS-terminating stand-in presenting two different certificates (one expiring inside 14 days, one outside it) selected by SNI: the probe correctly read each certificate's real expiry through the stand-in.
- **A real defect found and fixed by this rehearsal**: the Elasticsearch cluster-health rule's original query used a metric name (`elasticsearch_cluster_health_up`) that does not exist on the pinned exporter version, and combined a filtering comparison with `or` in a way that would have made the rule fire continuously in a healthy cluster. Corrected in `grafana/provisioning/alerting/rules.yaml` before this document was written; see that file's inline comment for the corrected query.
- The five new alert rules' fire-and-resolve behavior, each verified against its real condition logic (with pending windows temporarily shortened for the rehearsal only, not in the shipped rules.yaml).
- All ten dashboards rendered at two viewport sizes in their new folders.

Known differences from production, all forced by the local machine and none shipped: synthetic backing services stood in for the real datastores, a synthetic backend metrics endpoint stood in for the Spring application, rehearsal certificates were self-signed, and Windows/Docker Desktop introduced local artifacts.

## 9. Known failure modes and diagnosis

- **ClickHouse `SIGILL` above 26.5 on this CPU.** From ClickHouse 26.6 the official build's default target is x86-64-v3 (AVX2); this host's CPU is SSE4.2 only. `26.8.10.6` was reproduced crashing with `SIGILL` here while `26.3.33.24` (x86-64-v2) ran. Never move any compose file's ClickHouse image past the 26.3 LTS line on this host. This constraint outlives Phase 1 - Phase 2 analytics on the same instance inherits it until the host's CPU model changes.
- **Gorse OpenBLAS `SIGILL`.** The same CPU constraint applies to Gorse's OpenBLAS-linked binary. If Gorse crashes with `SIGILL` rather than the database-missing error below, this is the cause - confirm the CPU flags again with `lscpu`.
- **Grafana crash on an empty Discord webhook.** Grafana's Discord contact point provisioning fails validation on a syntactically empty URL, and that failure is fatal to the whole server, not just to alerting. The core resource's compose file sets a syntactically valid placeholder default for exactly this reason. Do not remove that default while wiring the real variable; only replace the value.
- **ClickHouse reader `readonly` level.** The Grafana ClickHouse plugin always sets `max_execution_time` per query. A reader profile with `readonly=1` rejects any query that sets a setting, which breaks every ClickHouse-backed panel on every dashboard. The reader profile uses `readonly=2` for this reason - do not "harden" it back to `1`.
- **The `okio` conflict.** A transitive dependency conflict blocked OTLP export at the backend level; already fixed in a merged backend PR. Mentioned here only so it is recognized if it resurfaces after an unrelated dependency bump: symptom is traces/logs silently not arriving in ClickHouse with no exception in the backend's own logs.
- **Scrape targets down after a backend redeploy.** Expected and transient (see the rolling-deploy note in section 3); a target that stays down for more than one scrape interval after the deploy finishes is a real problem - check the new container actually joined the `coolify` network and carries the `luvax-backend` alias.
- **Collector log-file permissions.** The OTel Collector reads `/var/lib/docker/containers/**/*.log` directly and runs as `user: "0"` specifically because those files are root-owned on the host. Do not remove that `user: "0"` as a hardening pass; the failure mode is silent (no error, just no rows for the affected containers).
- **Postgres custom configuration replacing the whole file.** Pasting only new lines instead of the full `pg_settings` dump silently reverts every other setting to the image's default.
- **Tunnel redirect loop.** Covered in section 3. Diagnosis: `curl -sIL --max-redirs 5 https://<hostname>` either exhausts its redirect budget or alternates `301`/`302` between the same two URLs. Fix is matching the working hostname's exact origin settings (Host Header, Origin Server Name, HTTP/2 off), not a different `service` URL.
- **Coolify creating directories for missing bind-mount files.** If any observability service fails to start with an error about a config file being a directory, or being unreadable/empty when it should have real content, re-run the sync verification (`find /data/luvax/observability -type d -empty`) and fix whichever path is empty, then restart that one service - no need to redeploy the whole resource.
- **Gorse crash-looping on a missing database.** Symptom: `docker logs $GORSE` shows `pq: database "gorse" does not exist (3D000)` in a tight restart loop, while Postgres itself reports healthy. Fixed during Phase 1 by adding a `CREATE DATABASE gorse` statement to the Postgres provisioning step; if Gorse is ever stuck in this loop again, run that one statement and restart the Gorse container.
- **A dashboard panel with a metric-name typo looks identical to a real traffic gap.** Before concluding a panel's data source has no traffic, curl the exporter or collector's own `/metrics` endpoint directly and grep for the metric name the panel queries; a name that is not there at all means the query is wrong, not the traffic. (This exact class of defect is what the Elasticsearch alert-rule fix in section 8 also caught, in an alert condition rather than a dashboard panel.)
- **Prometheus docker_sd discovery returning HTTP 403.** The socket proxy's `docker_sd_configs` support (Phase 1.5) needs `NETWORKS: 1` in its environment, in addition to the original `CONTAINERS`/`EVENTS`/`PING`/`VERSION`. Without it, Prometheus's own log shows `error while computing network labels: ... 403 Forbidden`, and every exporter using this discovery mechanism silently has zero targets.
- **A Coolify redeploy that removes a compose service does not remove its container.** Covered in P5 above. If a resource's `docker ps` output shows more containers than its current compose file declares, this is why - the extra containers are orphaned from a prior compose version and need an explicit `docker rm -f`.

## 10. Out of scope and follow-ups

- Phase 3 is not touched by any phase in this document and has no prerequisites here beyond the CPU-model constraint on ClickHouse outliving it.
  Phase 2 is the runbook of section 11.
- The `rabbitmq` and `gorse` Prometheus jobs keep their current static `file_sd_configs` targets (hardcoded production container names); Phase 1.5 does not modernize them to `docker_sd_configs`, since doing so would require redeploying the live broker and recommendation engine. A real, separate fragility (a redeploy of either would silently break its target) is flagged here as a candidate for a later, separate pass.
- If a future hostname is added to the tunnel, check whether it needs the same Cloudflare Access ACME-bypass application as `grafana.luvax.online`, or whether (like `api.luvax.online`) it can stay file-managed with No TLS Verify off - this depends on how its Access application and DNS are configured, not on anything this document can predict in advance.

## 11. Phase 2 runbook: analytics on ClickHouse, Business dashboards, Gorse rebuild

### What changes and why

- ClickHouse gains a database, `luvax_analytics`, with three tables (`user_events`, `admin_actions`, `platform_stats`) and three users with capped settings profiles (`luvax_analytics_writer`, `luvax_analytics_reader`, `luvax_analytics_migrator`); `grafana_reader` gains read access to it.
  One idempotent script, `clickhouse/initdb/02-create-analytics.sh`, provisions all of it.
  `initdb` runs it on an empty volume, and this runbook runs it by hand on the existing production volume, because `initdb` never runs twice.
- The backend moves behavioural events (`user_events`) and platform statistics (`platform_stats`) out of PostgreSQL into ClickHouse and replicates `admin_actions` there for listing and dashboards.
  PostgreSQL stays the system of record for the audit rows and every lookup by id.
  Flyway V127 to V133 add the audit replication version and triggers, add a foreign key from notifications to audit rows, drop `platform_stats`, `user_events`, `post_interaction_scores` and `user_similarity`, and create the Gorse rebuild checkpoint table.
  The new tables hold only seeded data, so the release is followed by a reseed (H5) and, because Gorse's catalogue drifted once before, by an operator-triggered Gorse rebuild (H7).
- A ClickHouse outage never takes the application down: the analytics screens answer `503 ANALYTICS_UNAVAILABLE`, the audit log falls back to PostgreSQL, and analytics ingestion pauses with its messages waiting in RabbitMQ (H8 describes it).
- The Grafana folder `Business`, reserved in Phase 1.5, gets three dashboards, and three alert rules join the existing set: ClickHouse async inserts failing, analytics events dropped, and analytics ingestion falling behind.
- The frontend gains one line under the audit log's date range saying new actions can take a few seconds to appear.
  It ships with the frontend release, not with this runbook.

Order and why:
- H2 (the core resource redeploy) comes before H3 because it places the three passwords in the ClickHouse container, where the provisioning script reads them, so no password appears in a command line or shared log.
- The database and users must exist before the backend starts (H3 before H4), or the backend runs degraded and retries every 30 seconds, which is safe but not the goal.
- The backend must have migrated before the reseed (H4 before H5), and the reseed must have drained before the Gorse rebuild reads ClickHouse (H6 before H7).
- Every step is marked **[WRITE]** where it changes production; H0, H6 and H8 are read-only.

### Values a step substitutes (keep out of shared logs)

- `$OBS`: the uuid suffix of the core observability containers (`docker ps`).
- `$PG`: the PostgreSQL container name, `rgtu7vdi4q9pfhtsbnldv89a`.
- `$APPROLE`: the PostgreSQL role the backend connects as (the name only, from the Coolify variable `POSTGRES_USER` of `luvax-prod`; never its password).
- `$BACKEND`: the current backend container name, `docker ps --filter label=coolify.resourceName=luvax-prod --format '{{.Names}}'` (it changes on every deploy).
- The three analytics passwords are generated by the operator and entered only in Coolify (H2 and H4).

### Corrections the local rehearsal made to this outline

1. H0 must read the Flyway version numerically: `flyway_schema_history.version` is text, so `max(version)` returns `99`, not `126`.
   Use `max(version::int)`.
2. H2 does not recreate Grafana: a redeploy of the core resource recreates only the services whose configuration changed (ClickHouse, for its three new variables, and the collector that depends on it).
   The `Business` folder and the three new alert rules do not appear until Grafana is restarted, so H2 ends with `docker restart grafana-$OBS`.
3. H1 opens a window in which ClickHouse's passwordless `default` user is reachable over the network.
   `sync-to-host.sh` runs `rsync --delete`, which removes `clickhouse/users.d/default-user.xml` (written by the ClickHouse entrypoint at first boot to disable that user) from the host tree.
   Until H2 recreates the ClickHouse container and the entrypoint writes the file again, a request such as `curl http://clickhouse-$OBS:8123/?query=select%201` from any container on the `coolify` network answers `1`.
   Run H1 and H2 back to back, and confirm the file is back at the end of H2 (H2 gate).
4. H5 fails in its first phase if the application role lacks the `SET` privilege on the parameter `session_replication_role`, because `SeedResetService` truncates with `session_replication_role = 'replica'`.
   A new conditional step H0b grants it.
5. The Gorse purge inside the reseed reset only warns when the application role cannot truncate Gorse's tables (`could not purge Gorse's database: ... permission denied for table feedback`); the Gorse rebuild (H7) refuses to start at its first phase for the same reason.
   H0b grants that privilege too.
6. The reseed is not finished when `[seed] full seed run complete` is logged.
   The 70,371 outbox events it enqueues drain at about 65 events per second, and ClickHouse agrees with PostgreSQL only about 29 minutes after the seed run started (section A5 of the rehearsal report).
   H6 waits for that.
7. The alert `Analytics ingestion falling behind` is calibrated at 5000 messages with a 45 minute pending window (the shipped 15 minutes fires during a normal reseed); see `a5-calibration.md`.

### H0 - Read-only preflight

Operator: run each command and check the output.
Nothing here writes.

```bash
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
export OBS=<uuid suffix of clickhouse-...>
export PG=rgtu7vdi4q9pfhtsbnldv89a
export APPROLE=<the backend's POSTGRES_USER, name only>
```

ClickHouse (the container's own `CLICKHOUSE_USER` and `CLICKHOUSE_PASSWORD` are used, so no secret is typed):

```bash
CHQ() { docker exec clickhouse-$OBS sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery -q "$0"' "$1"; }
CHQ "SELECT version()"
CHQ "SHOW DATABASES"
CHQ "SELECT metric, formatReadableSize(value) FROM system.asynchronous_metrics WHERE metric IN ('MemoryResident','CGroupMemoryUsed','CGroupMemoryTotal') ORDER BY metric"
CHQ "SELECT formatReadableSize(value) AS memory_tracking FROM system.metrics WHERE metric = 'MemoryTracking'"
CHQ "SELECT formatReadableSize(max(memory_usage)) AS max_query_memory_7d FROM system.query_log WHERE event_date >= today() - 7"
CHQ "EXISTS TABLE system.asynchronous_insert_log"
CHQ "SELECT database, table, sum(rows) AS rows, formatReadableSize(sum(bytes_on_disk)) AS size FROM system.parts WHERE active GROUP BY database, table ORDER BY database, table"
```

Expected (rehearsal, telemetry only): `EXISTS TABLE system.asynchronous_insert_log` is `1` (if it is `0`, the dashboard panel "Async insert failures by table" shows an error until the first async insert flushes; `CHQ "SYSTEM FLUSH LOGS"` creates it at once); version `26.3.33.24`; databases `INFORMATION_SCHEMA default information_schema otel system` (no `luvax_analytics`); a few hundred MiB resident; `max_query_memory_7d` about 60 MiB.
Production's real numbers are the point of this step: record them next to the 4 GiB container limit.
The rehearsal peaked at 861 MiB tracked and 975 MiB resident during the reseed drain, with the largest single query at 60 MiB.

PostgreSQL (the container's superuser, over its own socket; `PSQ` takes any `psql` flags and reads standard input):

```bash
PSQ() { docker exec -i $PG sh -c 'exec psql -U "${POSTGRES_USER:-postgres}" -v ON_ERROR_STOP=1 "$@"' sh "$@"; }   # the container's own superuser
PSQ -d luvax -Atc "SELECT max(version::int), count(*) FROM flyway_schema_history WHERE success"
PSQ -d luvax -Atc "SELECT rolname, rolsuper FROM pg_roles WHERE rolname = '$APPROLE'"
PSQ -d luvax -Atc "SELECT has_parameter_privilege('$APPROLE', 'session_replication_role', 'SET')"
PSQ -d gorse -c "SELECT c.relname AS gorse_table, has_table_privilege('$APPROLE', format('%I.%I', n.nspname, c.relname), 'TRUNCATE') AS can_truncate FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname IN ('feedback','items','users','documents','values','time_series_points','message') ORDER BY 1"
PSQ -d luvax -Atc "SELECT count(*) FROM notifications n WHERE n.admin_action_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM admin_actions a WHERE a.id = n.admin_action_id)"
PSQ -d luvax -Atc "SELECT status, count(*) FROM outbox_events GROUP BY status ORDER BY status"
```

Expected (rehearsal): `126|126`; the role is not a superuser (`f`), `has_parameter_privilege` is `f`, and every one of the seven Gorse tables shows `can_truncate = f`; orphan count `0`; outbox rows all `PUBLISHED`.
If `rolsuper` is `t`, both privilege gaps cannot exist and H0b is skipped.
If the Gorse tables are missing from the list, Gorse has not created them yet; stop and ask.

RabbitMQ dead-letter queues and the deployed commits:

```bash
docker exec rabbitmq-tcft7fbk5stgxgzc7bmtw1zt rabbitmqctl list_queues name messages_ready consumers | grep '\.dlq'
docker inspect $BACKEND --format '{{.Config.Image}}'
cat /data/luvax/observability/.git-commit 2>/dev/null || echo "ask which observability commit is deployed"
```

Record the deployed backend image or commit as `$BACKEND_ROLLBACK` and the deployed observability commit as `$ROLLBACK_SHA`.
Any dead-letter queue holding messages is recorded, not cleared here (the reseed purges every queue).

Gate: ClickHouse is `26.3.33.24` and has no `luvax_analytics`; Flyway reports `126`; the outbox has no `PENDING` row; the rollback points are recorded; the two privilege facts are recorded.

### H0b - Grant the two privileges the application role lacks [WRITE, conditional]

Operator, as the PostgreSQL superuser, only if H0 showed `rolsuper = f` and a missing privilege.
Every statement here is idempotent; the grant, the check, the revoke and a second grant were rehearsed on PostgreSQL 18 in this order (stage R3), with the application role a non-superuser.

`PSQ` is the superuser psql on the PostgreSQL container.
`APPROLE` is the role the backend connects as (H0 records it as `current_user` of the backend's own connection).

```bash
# 1. The Gorse rebuild (and the seed reset's Gorse purge) need TRUNCATE on the seven Gorse tables.
#    Run connected to database gorse. The table list is exactly the one GorsePurger truncates.
PSQ -d gorse -v ON_ERROR_STOP=1 -v approle="$APPROLE" <<'SQL'
GRANT TRUNCATE ON TABLE public.feedback, public.items, public.users, public.documents, public."values", public.time_series_points, public.message TO :"approle";
SQL
# 2. The seed reset needs to set session_replication_role for its wipe (PostgreSQL 15 and later).
PSQ -d luvax -v ON_ERROR_STOP=1 -c "GRANT SET ON PARAMETER session_replication_role TO \"$APPROLE\""
```

Notes from the rehearsal:
- The grant names the seven tables instead of `ALL TABLES IN SCHEMA public` and sets no default privileges: the tables belong to Gorse's own role, so `ALTER DEFAULT PRIVILEGES` run by the superuser would not have covered them anyway, and `TRUNCATE` on a table the rebuild does not touch is not needed.
- `:"approle"` is psql's identifier quoting; it works only for statements read from standard input or a file, not for `-c`.
- The grant survives Gorse restarts, because the rebuild truncates the tables and never drops them.
  If a Gorse upgrade recreates a table, run the statement again.

Verification, as the superuser (all seven rows `true`, and the second query `t`):

```bash
PSQ -d gorse -At -v approle="$APPROLE" <<'SQL'
SELECT c.relname || ' ' || has_table_privilege(:'approle', format('%I.%I', n.nspname, c.relname), 'TRUNCATE')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
  AND c.relname IN ('feedback','items','users','documents','values','time_series_points','message')
ORDER BY 1;
SQL
PSQ -d luvax -Atc "SELECT has_parameter_privilege('$APPROLE', 'session_replication_role', 'SET')"
```

Rollback:

```bash
PSQ -d gorse -v ON_ERROR_STOP=1 -v approle="$APPROLE" <<'SQL'
REVOKE TRUNCATE ON TABLE public.feedback, public.items, public.users, public.documents, public."values", public.time_series_points, public.message FROM :"approle";
SQL
PSQ -d luvax -v ON_ERROR_STOP=1 -c "REVOKE SET ON PARAMETER session_replication_role FROM \"$APPROLE\""
```

Expected (rehearsal): after the revoke the check reports `0 of 7 granted`; a second `GRANT` or `REVOKE` prints the same command tag and changes nothing.

Gate: both verification queries print `true` for every row.
The privilege-missing behaviour was rehearsed and is safe to leave ungranted: the seed reset logs a warning and continues, and the Gorse rebuild ends `FAILED` in `PREFLIGHT` before changing anything (see H7).

### H1 - Sync the merged observability `main` to the host [WRITE]

Operator, on the host.

```bash
REPO_URL=https://github.com/luvax-social/observability.git BRANCH=main TARGET_DIR=/data/luvax/observability \
  bash scripts/sync-to-host.sh
```

Verification:

```bash
find /data/luvax/observability -type d -empty                       # prints nothing
ls -l /data/luvax/observability/clickhouse/initdb                   # 01-... and 02-create-analytics.sh, both -rwxr-xr-x
grep -c $'\r' /data/luvax/observability/clickhouse/initdb/02-create-analytics.sh   # 0
ls /data/luvax/observability/dashboards/business                    # moderation-activity.json platform-statistics.json user-activity.json
```

Then, without waiting, do H2 (correction 3 above).
Rollback: re-run the same script with the recorded commit (`BRANCH=<$ROLLBACK_SHA>` needs a branch or tag; otherwise check the commit out in a clone and rsync it), or `rm -rf` the tree and re-sync.
Gate: the four checks pass.

### H2 - Redeploy the core resource with the three analytics passwords [WRITE]

Operator, in the Coolify UI.

1. Generate three passwords locally with `openssl rand -base64 36 | tr -d '/+=' | cut -c1-40`, one for each role.
   Enter them only in Coolify, as `CLICKHOUSE_ANALYTICS_WRITER_PASSWORD`, `CLICKHOUSE_ANALYTICS_READER_PASSWORD` and `CLICKHOUSE_ANALYTICS_MIGRATOR_PASSWORD` on the `luvax-observability` resource.
   Keep them for H4, where the same three values go to the backend.
2. Replace the resource's compose content with the new `compose.prod.yaml` and redeploy.
   The only change is the three variables in ClickHouse's environment; the redeploy therefore recreates the `clickhouse` and `otel-collector` containers and leaves the others running.
3. Restart Grafana so it reads the new provisioning (the `Business` provider and the new rules): `docker restart grafana-$OBS`.

Verification:

```bash
docker ps --filter "name=-$OBS" --format '{{.Names}}\t{{.Status}}'     # six core containers Up
for v in WRITER READER MIGRATOR; do docker exec clickhouse-$OBS sh -c 'test -n "$CLICKHOUSE_ANALYTICS_'$v'_PASSWORD" && echo set'; done   # set, set, set
docker exec clickhouse-$OBS ls /etc/clickhouse-server/users.d          # default-user.xml and luvax.xml
curl -s -u admin:$GF_ADMIN_PASSWORD http://localhost:3000/api/folders   # includes "Business"
curl -s -u admin:$GF_ADMIN_PASSWORD "http://localhost:3000/api/search?folderUIDs=business"   # the three dashboards
curl -s -u admin:$GF_ADMIN_PASSWORD http://localhost:3000/api/v1/provisioning/alert-rules | jq -r '.[].uid' | grep -c 'luvax-analytics\|luvax-clickhouse-async'   # 3
```

Rollback: redeploy the recorded `$ROLLBACK_SHA` compose; delete the `Business` folder with the sequence of Phase 1.5 step P7 if wanted (it is empty of anything but the three dashboards).
Gate: all six containers `Up`; three `set` lines; `default-user.xml` present again; the `Business` folder with three dashboards; three new rule uids.

### H3 - Provision the analytics database on the existing volume [WRITE]

Operator, on the host.
`initdb` does not run on an existing data directory (the rehearsal counted zero `docker-entrypoint-initdb.d` lines in the container log), so the same script is run by hand, twice.

```bash
docker exec clickhouse-$OBS bash /docker-entrypoint-initdb.d/02-create-analytics.sh; echo "exit=$?"
docker exec clickhouse-$OBS bash /docker-entrypoint-initdb.d/02-create-analytics.sh; echo "exit=$?"
```

Expected: no output apart from the two `exit=0` lines.

Verification:

```bash
CHQ "SHOW GRANTS FOR luvax_analytics_writer, luvax_analytics_reader, luvax_analytics_migrator, grafana_reader"
CHQ "SELECT profile_name, count() FROM system.settings_profile_elements WHERE profile_name IN ('analytics_writer','analytics_reader','analytics_migrator') GROUP BY profile_name ORDER BY 1"
for v in writer reader migrator; do docker exec clickhouse-$OBS sh -c "clickhouse-client --user luvax_analytics_$v --password \"\$CLICKHOUSE_ANALYTICS_$(echo $v | tr a-z A-Z)_PASSWORD\" -q 'SELECT currentUser()'"; done
```

Expected grants (rehearsal): the writer `INSERT` on `luvax_analytics.*`; the reader `SELECT` on `luvax_analytics.*`; the migrator `SHOW TABLES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE TABLE, CREATE VIEW, DROP TABLE, DROP VIEW, TRUNCATE, OPTIMIZE` on `luvax_analytics.*`; `grafana_reader` `SELECT` on `luvax_analytics.*` and on `system.asynchronous_insert_log`.
Profiles `analytics_migrator` 4, `analytics_reader` 7, `analytics_writer` 11 settings; three logins print their names.
Negative check, expected code 497 for both: the writer's `CREATE TABLE luvax_analytics.x (a UInt8) ENGINE = Memory`, and the reader's `SELECT count() FROM otel.otel_logs`.

Rollback (in this order):

```bash
CHQ "DROP USER IF EXISTS luvax_analytics_writer, luvax_analytics_reader, luvax_analytics_migrator; DROP SETTINGS PROFILE IF EXISTS analytics_writer, analytics_reader, analytics_migrator; REVOKE SELECT ON luvax_analytics.* FROM grafana_reader; REVOKE SELECT ON system.asynchronous_insert_log FROM grafana_reader; DROP DATABASE IF EXISTS luvax_analytics"
```

Gate: two `exit=0`, grants and profiles as listed, three logins, both 497 refusals.

### H4 - Deploy the backend release [WRITE]

Operator, in the Coolify UI, then on the host.

1. In the `luvax-prod` environment add `ANALYTICS_CLICKHOUSE_URL=jdbc:clickhouse://clickhouse-$OBS:8123/luvax_analytics` (substitute the real uuid), and `ANALYTICS_CLICKHOUSE_WRITER_PASSWORD`, `ANALYTICS_CLICKHOUSE_READER_PASSWORD`, `ANALYTICS_CLICKHOUSE_MIGRATOR_PASSWORD` with the same three values as H2.
   `ANALYTICS_ENABLED` defaults to `true`.
2. Deploy the backend release.
   Flyway applies V127 to V133 as the application role, including the drops of `platform_stats`, `user_events`, `post_interaction_scores` and `user_similarity` with whatever rows they hold (the reseed of H5 regenerates the analytics data).

Verification (no secrets involved; the management port is reachable only inside the container):

```bash
BACKEND=$(docker ps --filter label=coolify.resourceName=luvax-prod --format '{{.Names}}' | head -1)
docker logs $BACKEND 2>&1 | grep -E 'Migrating schema .* to version "(127|128|129|130|131|132|133)|\[analytics\]'
docker exec $BACKEND curl -s localhost:8081/actuator/health
docker exec $BACKEND curl -s localhost:8081/actuator/prometheus | grep -E 'luvax_analytics_schema_ready|luvax_analytics_ingestion_running|circuitbreaker_state.*name="clickhouse".*state="closed"'
PSQ -d luvax -Atc "SELECT version, success FROM flyway_schema_history WHERE version::int >= 127 ORDER BY version::int"
PSQ -d luvax -Atc "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename IN ('platform_stats','user_events','post_interaction_scores','user_similarity')"
CHQ "SELECT version, script FROM luvax_analytics.schema_migrations ORDER BY version"
```

Expected: seven Flyway lines and seven `t` rows; `[analytics] applied clickhouse migration V1__..., V2__..., V3__...`, `[analytics] clickhouse schema ready`, and `started listener` for `adminActionReplication`, `platformStatsIngest`, `userEventImport` and `recommendationFeedback`; health `{"groups":["liveness","readiness"],"status":"UP"}`; `luvax_analytics_schema_ready 1.0`, four `luvax_analytics_ingestion_running{...} 1.0`, the breaker `closed` gauge `1.0`; no dropped table listed; `V1`, `V2`, `V3` in `schema_migrations`.
A Hikari line `Registered driver with driverClassName=com.clickhouse.jdbc.Driver was not found, trying direct instantiation` for each ClickHouse pool is expected and harmless.

Rollback: H9 (redeploy the recorded backend, then the PostgreSQL rollback script).
Gate: every expectation above.

### H5 - Reseed [WRITE]

Operator, in the Coolify UI.
This wipes every domain table in the production database and regenerates the seed dataset, as in the earlier production seeding.
It also truncates the three ClickHouse analytics tables (as the migrator) after purging every broker queue.

1. Set `SPRING_PROFILES_ACTIVE=prod,seed`, `SEED_DATA=true`, `SEED_REQUIRE_LOCAL_DATASOURCE=false` on `luvax-prod` and restart the backend.
2. Follow the log until `[seed] full seed run complete` (about one minute):

```bash
docker logs -f $BACKEND 2>&1 | grep '\[seed\]'
```

Expected lines (rehearsal): `phase=reset starting`, `reset: 30 broker queues purged`, `reset: 3 analytics tables truncated`, `platform_stats: 4320 half_hour bucket events enqueued`, `user_events: 10000 import events enqueued`, `phase=outbox-emission complete: total=70371, analytics: adminActions=277, platformStatsBuckets=4320, userEventImports=10000`, `enum coverage assertion passed for all 15 columns`, `full seed run complete in 59776 ms`.
Without the H0b Gorse grant the reset also logs `could not purge Gorse's database: ... permission denied for table feedback` as a warning and carries on; without the `session_replication_role` grant it fails with `permission denied to set parameter "session_replication_role"` and changes nothing in PostgreSQL.
3. Unset the three variables and restart the backend.
   Do not wait for the drain first: the outbox rows are already committed and the ordinary backend drains them.

Rollback: reseed again; a failed seed run leaves the queues purged and ClickHouse truncated but PostgreSQL untouched when it fails in `phase=reset`.
Gate: `full seed run complete` logged, no `[seed] seed run failed`, the three variables unset and the backend healthy.

### H6 - Drain and consistency

Operator.
Expect about 30 minutes (the rehearsal took 29 minutes from the seed run's end to the last analytics queue empty; 17 of them are the publisher at about 65 events per second, then the feedback queue needs a further 11 minutes).
While it drains, `Analytics ingestion falling behind` is expected to stay `Normal` with the calibrated 45 minute window (a 15 minute window fires); `recommendation.feedback.queue` peaks near 23,000 messages.

```bash
watch -n 30 "docker exec rabbitmq-tcft7fbk5stgxgzc7bmtw1zt rabbitmqctl list_queues name messages_ready | grep -E 'admin.action.replication|admin.platform-stats|recommendation.feedback.queue|recommendation.user-event.import'; docker exec -i $PG psql -U \"$APPROLE\" -d luvax -Atc \"SELECT status, count(*) FROM outbox_events GROUP BY status\""
```

Gate to continue: outbox `PENDING` is 0 and the four queues hold no ready message.

Consistency queries (ClickHouse reader, `FINAL`):

```bash
CHQ "SELECT 'admin_actions', count() FROM luvax_analytics.admin_actions FINAL"
PSQ -d luvax -Atc "SELECT 'admin_actions', count(*) FROM admin_actions"
CHQ "SELECT 'platform_stats buckets', uniqExact(bucket_start) FROM luvax_analytics.platform_stats"
CHQ "SELECT 'user_events', count(), countIf(feedback_type IS NOT NULL) FROM luvax_analytics.user_events FINAL"
CHQ "SELECT event_type, count() AS events, countIf(feedback_type IS NOT NULL) AS with_feedback FROM luvax_analytics.user_events FINAL GROUP BY event_type ORDER BY event_type"
CHQ "SELECT table, status, count() FROM system.asynchronous_insert_log WHERE database = 'luvax_analytics' AND event_time > now() - INTERVAL 3 HOUR GROUP BY table, status"
```

Expected (rehearsal): `admin_actions` 277 on both sides; `4320` distinct buckets (plus any live bucket collected since); `user_events` 64,860 with 54,859 carrying a feedback type (28,098 `post_view`, 20,000 `post_like`, 2,000 `post_save`, 4,749 `post_comment`, 12 `post_share` are the consumed engagement events; the other 10,000 rows are the imports, and every one of the 20 event types except `post_view` has at least 5 rows); no `async insert` status other than `Ok`.
One extra `session_start` row per login made since the reseed is normal.

Then open, as the seeded `admin` account (its password is in the seed README, never in shared logs), in the admin panel: the audit log (unfiltered, and one page forward), the activity log for one user with a window of at most 30 days, and the statistics screen; each renders (the frontend note under the audit log date range belongs to the frontend release and is checked in its own stage).
The equivalent API checks returned 200 with `degraded: false` for `GET /admin/actions?limit=3`, rows for `GET /admin/user-events?userId=&from=&to=`, and a snapshot with `totalUsers`, `usersByStatus`, `topHashtags` for `GET /admin/stats/current`.

Rollback: none needed.
Gate: counts agree as listed; the three screens render.

### H7 - Rebuild Gorse from PostgreSQL and ClickHouse [WRITE]

Operator, in the Coolify UI, then on the host.
Do this only after H6 passed, because the rebuild reads the feedback history from ClickHouse.

Before: record the For You sanity as three QA accounts (fixed accounts, so before and after compare).

```bash
# TOKEN is an access token of that account; record the ids and how many carry a rankingScore
curl -s -H "Authorization: Bearer $TOKEN" "https://<api host>/api/v1/recommendations/feed?limit=20" \
  | jq '[.data.content[] | {id, rankingScore}]'
PSQ -d gorse -Atc "select (select count(*) from items)||'/'||(select count(*) from users)||'/'||(select count(*) from feedback)"
PSQ -d luvax -Atc "select (select count(*) from posts)||'/'||(select count(*) from posts where status='published' and deleted_at is null)||'/'||(select count(*) from users where deleted_at is null)"
```

Expected before: every id is a published post, every item has a `rankingScore`.

1. In `luvax-prod` set `GORSE_REBUILD=true` and `GORSE_REBUILD_TOKEN=<date>-1` (any name no earlier rebuild used) and restart the backend.
   `GORSE_REBUILD_REQUESTS_PER_SECOND`, `GORSE_REBUILD_USER_BATCH_SIZE`, `GORSE_REBUILD_ITEM_BATCH_SIZE` and `GORSE_REBUILD_FEEDBACK_BATCH_SIZE` default to 5, 500, 500 and 1000 and are left alone.
2. Follow it:

```bash
docker logs -f $BACKEND 2>&1 | grep '\[gorse-rebuild\]'
docker exec $BACKEND curl -s localhost:8081/actuator/prometheus | grep -E '^luvax_gorse_rebuild'
docker exec -i $PG psql -U "$APPROLE" -d luvax -Atc "select token, status, phase, users_sent, items_sent, feedback_sent, feedback_skipped, left(last_error, 120) from gorse_rebuild_runs order by started_at"
```

Expected log, in order: `token=<t> starting phase=PREFLIGHT`, `phase=USERS sent=<n> checkpoint=<id>`, `phase=ITEMS sent=<n> ...`, `phase=FEEDBACK sent=<n> ...` and finally `phase=DONE users=140 items=746 feedback=<n> feedbackSkipped=<n>`.
The gauge `luvax_gorse_rebuild_phase` reads 1 for `PREFLIGHT`, 2 `PURGE`, 3 `USERS`, 4 `ITEMS`, 5 `FEEDBACK`, 6 `VERIFY`, 7 done and -1 failed.
Rehearsal at the seed dataset (140 users, 746 posts, 54,884 feedback rows): about 30 seconds from container start to `DONE` at the defaults, and `feedbackSkipped` counted the one planted feedback row whose post PostgreSQL does not hold.
While the run is in `PURGE` to `VERIFY`, the `recommendationFeedback` listener is stopped on purpose: `recommendation.feedback.queue` shows ready messages and zero consumers, and `luvax_analytics_ingestion_running{listener="recommendationFeedback"}` is 0.
The listener drains the queue as soon as the run finishes.
A run that lasts longer than five minutes therefore fires `RabbitMQ queue stalled` for that queue, which is expected and resolves by itself.

3. Unset both variables in `luvax-prod` and restart the backend.
   The log then holds no `[gorse-rebuild]` line, and the gauge reads 0.
   Leaving them set is harmless (a finished token logs `already finished with status DONE; nothing to do.` and changes nothing), but a stale toggle is a trap for the next deploy.
4. After one Gorse `fit_period` (5 minutes in `backend/gorse/config/config.toml`) repeat the For You sanity.

Expected after: the same three feeds return ranked items, every id resolves to a published post, none of the 19 unpublished or deleted posts appears, Gorse holds one item per post (`746/140/<n>` items, users, feedback rows against PostgreSQL's `746` posts) and its hidden flag count equals PostgreSQL's unpublished and deleted post count.
The feeds are not identical to the ones before: in the rehearsal 13 to 15 of the 20 ids carried over, because the rebuild recomputes Gorse's models from the same feedback and adds the feedback that arrived meanwhile.

Failure handling, all rehearsed:
- `phase=PREFLIGHT FAILED: Gorse's store cannot be purged: role <r> lacks the TRUNCATE privilege on gorse.public.<table>; ...` means H0b was skipped.
  Nothing was changed (Gorse, ClickHouse and PostgreSQL fingerprints identical, the listener never stopped, the run row is `FAILED`).
  Run H0b, then restart the backend with the same token: a `FAILED` run resumes.
- `phase=<p> FAILED: ...` at a later phase (Gorse unreachable, ClickHouse down) leaves the checkpoint in the run row; fix the cause and restart with the same token, and it resumes from the checkpoint.
  A restart in the middle of `FEEDBACK` behaves the same (`resuming phase=FEEDBACK checkpoint=<id>`), and re-sending a batch overwrites rather than adds, so nothing double counts: the rebuilt Gorse tables were byte-identical between a run that was interrupted and resumed and two later complete runs.
- `phase=VERIFY FAILED_VERIFICATION missing=<n> stray=<n> hiddenMismatch=<n> feedbackMismatch=<n> ...` lists up to 20 example ids per kind.
  The run is final: find the cause, then use a new token.
  Rehearsed with an item hidden by hand in Gorse while the run was in `FEEDBACK`: the log named that item as `hiddenMismatch`, the run row read `FAILED_VERIFICATION`, and a new token at the defaults restored a consistent state.

Rollback: none is needed, because Gorse holds nothing that PostgreSQL and ClickHouse do not; a new token re-runs the whole rebuild, and the live pipeline keeps Gorse current meanwhile.
Gate: the run row is `DONE`, `luvax_gorse_rebuild_verification_failures_total` is 0, the `Expected after` checks hold and both variables are unset.

### H8 - Final verification

Operator, 30 minutes after H7.
Nothing here writes.

- Every gate of H2 to H7 still holds: `docker ps` for the six core containers, the breaker gauge, the four `luvax_analytics_ingestion_running` gauges, the consistency queries of H6.
- The first live statistics bucket arrived.
  The bucket containing the backend start is skipped by design, so the first live one is written about half an hour after the next half-hour boundary that follows the start (rehearsal: backend up 22:59, bucket `[23:00, 23:30)` written 23:59:39).
  `CHQ "SELECT max(bucket_start), uniqExact(bucket_start) FROM luvax_analytics.platform_stats FINAL"` shows a bucket newer than the seed's last.
- No new alert is firing in Grafana other than the ones already known to be unrelated (list them from H0).
- Grafana, folder `Business`: the three dashboards render with data and no panel error.

What an outage looks like in production, as rehearsed (to recognise the behaviour, not a step to run):

| Condition | What the operator sees |
|---|---|
| ClickHouse stopped | the breaker opens within 10 seconds; the four analytics listeners stop; `Circuit breaker open` fires about 100 seconds later (its pending window is one minute); `RabbitMQ queue stalled` fires after about six minutes for the admin replication and feedback queues; no dead-letter queue receives anything |
| ClickHouse hung (`docker pause`) | the first audit-log request after the hang takes up to 25 seconds (the reader socket timeout) before it falls back to PostgreSQL, later ones answer in milliseconds; the breaker alternates 30 seconds open and about 30 seconds half-open; `Circuit breaker open` fires (it counts `half_open`), the stalled-queue rule may not |
| Recovery | half-open within 30 seconds, closed after three successful calls, backlog drains in seconds to a few minutes, every row present exactly once under `FINAL` |
| Quiet system after recovery | the breaker can stay half-open until three calls happen, and the alert stays firing meanwhile; ordinary traffic closes it within seconds |
| Activity log and statistics during the outage | HTTP 503 with code `ANALYTICS_UNAVAILABLE` and the message "Analytics are temporarily unavailable. Please try again in a minute."; the audit log, lookups by id, appeals, the notification feed and For You keep working |

An async insert of an unknown enum value as `luvax_analytics_writer` with `wait_for_async_insert=0` returns HTTP 200, is dropped, raises `FailedAsyncInsertQuery`, and fires `ClickHouse async inserts failing` within about 22 seconds.
A malformed `admin.platform-stats.collected.v1` goes straight to `admin.platform-stats.dlq`, leaves the breaker counters unchanged, and fires `DLQ not empty` after about 2 minutes.
Purge a test message with `DELETE /api/queues/%2F/<dlq>/contents` on the RabbitMQ management API.

Gate: as listed; record the result of the whole runbook in one message, as section 2 requires.

### H9 - Roll the backend release back [WRITE]

Operator.
Use it only to abandon the release that added V127 to V133; it restores the PostgreSQL schema the previous backend expects and does not restore data.

The order matters, and it differs from the outline: the previous image validates Flyway history at startup and refuses to start while V127 to V133 are recorded as applied (as the script header states; the rehearsal ran the script first and did not start the old image ahead of it), so the script runs before it.

1. Stop the new backend in Coolify (the script needs the tables quiet).
2. Run `backend/scripts/rollback/phase2_postgres_rollback.sql` of the release commit as the database owner (the application role; no superuser is needed, rehearsed with a non-superuser owner), in one transaction:

```bash
docker exec -i $PG psql -U "$APPROLE" -d luvax -v ON_ERROR_STOP=1 -1 -f - < phase2_postgres_rollback.sql
docker exec -i $PG psql -U "$APPROLE" -d luvax -Atc "select max(version::int) from flyway_schema_history"
```

Expected: about 20 command tags with no error, the last `DELETE 7`, and `126`.
Afterwards `platform_stats`, `user_events` (with `user_events_default` and the current and next two monthly partitions), `post_interaction_scores` and `user_similarity` exist again and are empty, `admin_actions` has no `row_version` column or replication trigger, the foreign key `fk_notifications_admin_action` and `gorse_rebuild_runs` are gone, and the V128 archive table is kept as `archived_notification_admin_action_orphans_before_rollback`.
A second run of the script is harmless (`DELETE 0`, `NOTICE ... does not exist, skipping`).

3. Redeploy the recorded previous backend commit in Coolify.
   Expected log lines: `Successfully validated 126 migrations` and `Schema "public" is up to date. No migration necessary.`; the container turns healthy in about 30 seconds.
4. Reseed as H5 does (the previous image needs the same two privileges of H0b): the previous image's `SeedResetService` purged 24 queues, truncated 44 tables and emitted 55,781 outbox events in 52 seconds.
5. Verify the previous release's admin screens: the audit log, the activity log for a seeded account (`GET /api/v1/admin/user-events`) and both statistics series answer `200` with data (rehearsal: 20 audit rows, 20 activity rows, 29 daily and 47 half-hour points).
   Before the reseed they answer `200` with empty pages, which is also correct.

The observability side can stay: an unused `luvax_analytics` database, its users and three empty dashboards harm nothing, and the H3 rollback removes them if wanted.

Rolling forward again was rehearsed: redeploying the new backend applied V127 to V133 cleanly on the rolled-back schema (`flyway max 133`, the four dropped tables gone again, the V128 archive of the earlier attempt untouched), and the analytics screens answered.
The ClickHouse tables still hold the analytics of the dataset that existed before the rollback, so a reseed (H5, which truncates them) is required before the roll-forward's screens make sense.

### Local rehearsal evidence (Phase 2)

The runbook above was executed end to end on a local production-shaped stack: the same container names, an application role that is not a superuser and owns its tables, a separate role owning Gorse's tables, and a ClickHouse volume created before Phase 2 so that `initdb` did not run.
It covered the H0 preflight, H0b, H1 to H6, the outage behaviours of H8, H7 in both privilege states and H9 with a roll-forward afterwards.
Its differences from production, none of which is runbook content:
- no `sudo`, `rsync` or `/data/luvax` on that machine, so `sync-to-host.sh` ran unmodified in a Debian container;
- ClickHouse limited to 1536 MiB and Prometheus to 768 MiB;
- no Cloudflare, Coolify proxy, Discord or exporter resources.

### Production facts to confirm at H0 (unverified until then)

- Whether the backend's PostgreSQL role is a superuser (the rehearsal assumed not; if it is, H0b is skipped).
- Whether that role can truncate Gorse's seven tables and set `session_replication_role` (H0 prints both; H0b grants them).
- ClickHouse's real memory footprint against its 4 GiB limit, and whether `system.asynchronous_insert_log` exists yet.
- That no dead-letter queue holds messages and the outbox has no `PENDING` row before the release.
- The deployed backend and observability commits, recorded as rollback points.
