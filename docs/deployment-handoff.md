# Luvax observability: production deployment handoff

This is the single entry point for the assistant helping the user deploy and evolve production observability.
Read this file in full before proposing any step.
You are a chat assistant (Claude on claude.ai).
You have no shell, no Docker access, no SSH, no `gh`, and no access to the repositories.
The user runs every command on the production host (over Tailscale SSH) and pastes the output back to you.
You have never seen the planning conversation, the implementation reports, or the local rehearsals that produced this document.
Everything you need is in this file.
Where this file names a repository file (for example `compose.prod.yaml`), you cannot open it; ask the user to paste or upload it only if a step genuinely needs its content.

## 1. Purpose and scope

Phase 1 (deployed) added monitoring only: traces and logs over OpenTelemetry, metrics over Prometheus, dashboards and alerting in Grafana.
Phase 1.5 (this document's active runbook) splits the single `luvax-observability` Coolify resource into five resources, moves scrape discovery from static targets to Prometheus `docker_sd_configs`, regroups the ten dashboards into five category folders, and adds five alert rules.
Neither phase touches the frontend, Phase 2 (analytics on the same ClickHouse instance), or Phase 3.
The backend changes from Phase 1 (OTLP export, the private management port, outbox/inbox metrics, `pg_stat_statements`) are already merged and deployed; Phase 1.5 makes no backend code change.

## 2. Operating model

- **The user performs every action.** That includes every Coolify and Cloudflare UI change and every shell command on the host. You tell the user exactly what to click or run, why, and what output to expect, then you read the output they paste and decide whether the step's gate passed.
- **One step at a time.** Give the commands for exactly one runbook step (or one sub-step), wait for the pasted output, verify it against the step's expected result and gate, and only then give the next step. Never batch several write steps into one message.
- **Read-only versus write.** Commands marked **[WRITE]** change production. Before giving one, state what it changes and its rollback, and ask the user to confirm they are ready. Unmarked commands are read-only diagnostics the user can run at any time.
- **Secrets never enter the chat.** Passwords, API keys, tokens and webhook URLs are generated and entered by the user directly on the host or in Coolify. Write commands that need a secret use a shell variable the user sets locally first, for example `read -rs POSTGRES_MONITOR_PASSWORD; export POSTGRES_MONITOR_PASSWORD`, so the value never appears in the command text, the shell history, or the chat. If pasted output contains a secret, tell the user to redact it and treat that secret as exposed (rotate it). Never invent a secret value.
- **Do not guess.** If pasted output does not match the expected result, stop, diagnose with read-only commands, and consult section 9 before proposing any change. If a fact this file assumes (a container name, a version, a setting) differs from what the host shows, the host wins.
- **Record keeping.** This chat is the record of the deployment. At the end of a runbook, summarize every finding, every deviation from this document, and every verification result in one message the user can save.

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
- **Other hostnames** (`api.luvax.online`, `www.luvax.online`, `coolify.luvax.online`, and the apex `luvax.online`) remain file-managed (`config.yml`), with No TLS Verify Off, because Traefik presents a real origin certificate for each of them.
  This is exactly why the Phase 1.5 TLS-expiry probe (section 6) excludes `grafana.luvax.online` and only targets these four.

## 4. Phase 1, deployed: history

Phase 1 (traces, logs, metrics, dashboards, alerting) was deployed to production and is live.
Full runbook detail (R0-R10, the original per-step commands) lived in earlier revisions of this document and in `.workspace/reports/p1/`; it is condensed here because the deployment is complete and stable, not pending.

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
  A sixth folder, **Business**, is reserved for Phase 2 (platform statistics, admin actions, user events) and is deliberately not created yet.
- Five new alert rules join the six existing ones (unchanged): origin TLS certificate expiring, a stalled RabbitMQ queue, a stalled outbox publisher, an unhealthy Elasticsearch cluster, and a high backend 5xx rate.
  A nested `severity=critical` routing policy gives critical alerts a 1-hour repeat interval; warning-severity alerts keep the existing 4-hour default.
- The alert-rule provisioning group moves from folder "Luvax" to its own new "Alerting" folder.
  This is necessary, not cosmetic: alert rule groups share the same folder namespace as dashboards, and the old "Luvax" folder is deleted once empty (step P8 below) - leaving the rule group parented there would have orphaned it.

### Migration model: single cutover, not per-category

Earlier planning considered migrating one exporter category at a time, with preview jobs and several redeploys of the core resource.
That costs more operator steps than the bounded metrics gap it avoids, and production data is seeded, so a short gap is acceptable.
The sequence below is one cutover: create the four new resources first (harmless coexistence with the still-running old exporters), then one single redeploy of the core resource with every change at once.

### P0 - Discover the Coolify proxy container (read-only, before the cutover)

Who: the user runs; you read the output.

The blackbox-exporter's origin-TLS probe (see below) needs the Coolify proxy's real container name and network.
This document does not have that fact recorded yet.

```bash
docker ps --format '{{.Names}}\t{{.Image}}' | grep -i -E 'proxy|traefik|coolify-proxy'
docker inspect <candidate-name> --format '{{json .NetworkSettings.Networks}}' | jq 'keys'
```

Expected: a container whose image is Coolify's proxy (commonly Traefik-based, often named `coolify-proxy`), attached to the `coolify` network.
Record its name as `$PROXY` for the steps below.
If more than one container matches, ask the user to confirm which one actually terminates TLS for `api.luvax.online` (the one already proven working) before proceeding.

Gate before P1: `$PROXY` is a real, running container name, attached to `coolify`.

### P0.5 - Record the origin certificate per hostname (read-only, before the cutover)

Who: the user runs; you read the output.

```bash
for h in api.luvax.online luvax.online www.luvax.online coolify.luvax.online; do
  echo "== $h =="
  openssl s_client -connect localhost:443 -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -issuer -enddate
done
```

Expected: a real issuer (Let's Encrypt or similar) and a future expiry date for all four.
**If any hostname shows Traefik's own default certificate** (a self-signed or internal issuer, not Let's Encrypt) instead of a real origin certificate, remove that hostname from the blackbox-exporter's module list (see step P3) and note it here - it means that hostname has the same "No TLS Verify" shape as `grafana.luvax.online` and an origin probe would be permanently meaningless for it, exactly as documented for `grafana.luvax.online` in section 3.

Gate before P1: all four hostnames' issuer and expiry are recorded (or excluded, with a note).

### P1 - Record the rollback point (read-only)

```bash
cat /data/luvax/observability/.git-commit 2>/dev/null || echo "not recorded - ask the user which observability commit is currently deployed"
```

If the host has no record of the deployed commit, ask the user to check the `luvax-observability` resource's configured branch/commit in the Coolify UI, or the last commit merged to `observability`'s `main` before this session.
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
If P0.5 excluded any hostname, also remove that hostname's two lines (the `static_configs` target block and, in `blackbox-exporter/config.yml`, its module) from the synced files.

Rollback: `sudo rm -rf /data/luvax/observability` (the old resource is still running and unaffected).

Gate before P3: both verification commands pass and the placeholder substitution is done.

### P3 - Create and deploy the four new resources [WRITE]

Who: the user (UI), one resource at a time. For each, Project `luvax-prod`, New Resource, Docker Compose Empty, paste the matching compose file **unmodified** (`compose.host.prod.yaml`, `compose.postgres-exporter.prod.yaml`, `compose.redis-exporter.prod.yaml`, `compose.elasticsearch-exporter.prod.yaml`), enable "Connect To Predefined Network", copy the matching environment variables from the current `luvax-observability` resource's own environment (the same values, since these exporters previously ran inside it), deploy.

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

Who: the user (UI). Open the `luvax-observability` resource, replace its compose content with the new (shrunk) `compose.prod.yaml`, replace `prometheus/prometheus.prod.yml`, `grafana/provisioning/dashboards/dashboards.yaml`, `grafana/provisioning/alerting/rules.yaml`, and `grafana/provisioning/alerting/policies.yaml` with their new versions (already synced to the host in P2), and Redeploy.

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

Proven in a disposable local topology outside any tracked repository (method: `.workspace/reports/p1/p4-report.md`), not on the production host:

- The single-cutover sequence (P1-P8 above) executed literally: old single-resource state deployed first, the four new resources created and coexisting harmlessly with the still-running old exporters, one redeploy of the core resource, the leftover-old-exporter finding reproduced exactly as documented and cleared with the given command, the legacy folder confirmed empty of both dashboards and alert rules before deletion, and a full rollback executed and verified to restore the old state.
- The container-name addressing proof: each split exporter, attached to both its own resource network and `coolify` at creation (replicating Coolify's real attachment order), yielded exactly one Prometheus target with `up=1`; recreating one exporter under a new container name (simulating a redeploy) converged to exactly the new target within one `docker_sd_configs` refresh cycle, with no lingering old target.
- The origin-TLS probe design, proven against a local TLS-terminating stand-in presenting two different certificates (one expiring inside 14 days, one outside it) selected by SNI: the probe correctly read each certificate's real expiry through the stand-in.
- **A real defect found and fixed by this rehearsal**: the Elasticsearch cluster-health rule's original query used a metric name (`elasticsearch_cluster_health_up`) that does not exist on the pinned exporter version, and combined a filtering comparison with `or` in a way that would have made the rule fire continuously in a healthy cluster. Corrected in `grafana/provisioning/alerting/rules.yaml` before this document was written; see that file's inline comment for the corrected query.
- The five new alert rules' fire-and-resolve behavior, each verified against its real condition logic (with pending windows temporarily shortened for the rehearsal only, not in the shipped rules.yaml).
- The ten-dashboard, two-resolution screenshot sweep in their new folders, under `.workspace/reports/p15/rehearsal/`.

Known differences from production, all forced by the local machine, none shipped: see `.workspace/reports/p15/p15b-report.md` section on the rehearsal for the full list (synthetic backing services in place of the real datastores, a synthetic backend metrics endpoint in place of the real Spring application, self-signed rehearsal certificates, Windows/Docker Desktop artifacts already documented in the Phase 1 rehearsal evidence below).

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

- Phase 2 (analytics on ClickHouse) and Phase 3 are not touched by either phase in this document and have no prerequisites here beyond the CPU-model constraint on ClickHouse outliving both.
- The `rabbitmq` and `gorse` Prometheus jobs keep their current static `file_sd_configs` targets (hardcoded production container names); Phase 1.5 does not modernize them to `docker_sd_configs`, since doing so would require redeploying the live broker and recommendation engine. A real, separate fragility (a redeploy of either would silently break its target) is flagged here as a candidate for a later, separate pass.
- If a future hostname is added to the tunnel, check whether it needs the same Cloudflare Access ACME-bypass application as `grafana.luvax.online`, or whether (like `api.luvax.online`) it can stay file-managed with No TLS Verify off - this depends on how its Access application and DNS are configured, not on anything this document can predict in advance.
