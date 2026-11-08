# n8n source alignment (2026-11-08)

## Source revisions

- HA add-on: [`WOOWTECH/Woow_ha_n8n`](https://github.com/WOOWTECH/Woow_ha_n8n), `main` at `9fa4944302fa006f848af0c2011f3f531a0bf488` (2026-11-05). Add-on and upstream n8n version: `2.43.6`.
- Podman starting point: [`WOOWTECH/Woow_podman_n8n`](https://github.com/WOOWTECH/Woow_podman_n8n), `main` at `4b6c0c49a55e55bc559f41f377fc911dce7cbfa0`. Upstream n8n and runners: `2.38.7`.
- PaaS Gitea: `woow-paas/woow-paas-charts`, `main`, `charts/n8n`. **Source comparison pending:** `git-prod.woowtech.io` redirects unauthenticated Git requests to Cloudflare Access. The older public `WOOWTECH/Woow_k3s_n8n` chart (`9b0182f44b528d0cdceaeecd2817d7f9e95fe227`, 2026-09-13) is a separate deployment and is not evidence of current PaaS main.

The remaining Gitea review must inspect `Chart.yaml`, `values.yaml`, image build sources and all n8n templates for image/version pins, database and queue mode, Redis, workers/webhooks, task runners, additional nodes, MCP, URL/ingress settings, secrets, backup and lifecycle hooks. Record its main SHA before changing this table.

## HA to Podman mapping

| Capability | HA add-on | Podman package |
| --- | --- | --- |
| Editor, REST API, webhooks, instance-level MCP | n8n 2.43.6 | Same upstream version 2.43.6 |
| Code nodes | Matching 2.43.6 JavaScript and Python runners in the add-on container | Matching 2.43.6 runners in a separate container; native Python enabled |
| Module imports | `NODE_FUNCTION_ALLOW_BUILTIN=*`, `NODE_FUNCTION_ALLOW_EXTERNAL=*`, `N8N_RUNNERS_STDLIB_ALLOW=*`, `N8N_RUNNERS_EXTERNAL_ALLOW=*` | Same runner configuration, with only the workdir changed to `/home/runner` |
| Encryption and storage | SQLite and `/config` in an HA backup | PostgreSQL 16 and `n8n_n8n_data` volume; backup includes DB dump, encryption key, secrets and units |
| Broker token | Per-installation random file; broker binds to loopback | Per-installation Podman secret mounted as a file in n8n; separate runner receives it as a launcher secret; broker binds to the private Podman network, with no published port |
| Workflow environment access | `$env` enabled; Supervisor tokens removed before n8n starts | Example enables `$env`; DB password and broker token are mounted as files rather than n8n environment values |
| Storage migration and config permissions | `N8N_MIGRATE_FS_STORAGE_PATH=true`; enforce settings file permissions | Same settings in the n8n Quadlet |
| Public URL and cookies | Direct HTTP, HA Ingress and Cloudflare Tunnel; secure cookies disabled for HTTP | Loopback or LAN publish, Cloudflare Tunnel or reverse proxy; `--public-url` sets editor/webhook URLs and proxy hops; cookies follow the selected HTTP/HTTPS setup |
| Health and stop | Supervisor watchdog and 60-second stop timeout | n8n/runner health checks, 900-second migration grace, n8n stops before runners, 60-second container stop timeout |

The HA ingress nginx, Supervisor API and sidebar integration are HA-only. The HA image also includes Redis for workflows using `localhost:6379` and shell utilities such as Python 3.14, Bash, curl and jq for Execute Command nodes. This Podman package currently uses the upstream n8n image and does **not** supply those extra binaries or an embedded Redis instance. The PaaS chart must be checked before deciding whether to add equivalent optional components.

## Runtime evidence

On 2026-11-08, isolated rootless Podman containers used PostgreSQL 16.15, n8n 2.43.6, and runners 2.43.6. The HA add-on's upgrade-state test created an owner, encrypted credential, active webhook with JavaScript and native Python Code nodes, five executions and a public API key. After a restart, sign-in, credential decryption, encryption key, workflow, executions and API key all passed. A separate workflow imported JavaScript `node:path` and Python `hashlib`; neither Code node received the database password or broker token through its environment.

A second isolated run started on n8n/runners 2.38.7, seeded the same data, then reused the PostgreSQL and n8n data volumes with n8n/runners 2.43.6. All state checks and the active webhook passed after the migration. Test containers and volumes were removed after success. `tests/dryrun.sh` passed five Quadlet render variants, and `tests/config-snapshot.sh` verified that rollback snapshots preserve the runner config path.

This host's production n8n services stopped at 2026-10-31 23:05 CST. The user journal records a `podman system reset -f` process (`_CMDLINE` on PID 743720) at 23:05:42, followed by explicit removal of `n8n_postgres_data` and `n8n_n8n_data` at 23:05:43, alongside many other Podman volumes. The n8n volumes and Podman secrets are absent from the current rootless Podman store. This identifies the volume removal operation, but the journal does not identify who initiated it. The newest n8n backup found on this host is from 2026-09-14 and records n8n **2.31.6**; its database dump, data archive and secret files still exist. A restore into an isolated PostgreSQL container showed one user, zero workflows, zero credentials and zero executions. It cannot establish what changed while 2.38.7 ran through October. No production data was restored or restarted as part of these isolated tests.
