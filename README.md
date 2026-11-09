# n8n on rootless Podman (Quadlet + systemd)

[n8n](https://n8n.io/) with PostgreSQL and external task runners, deployed as **rootless
Podman Quadlet units** driven by the user's systemd. The units are the deployment: systemd
starts the stack at boot (with linger), restarts a crashed container and keeps every version
pinned in this repository.

[繁體中文版](README.zh-TW.md)

## Architecture

```
              systemctl --user start|stop|restart n8n.target
                                  │
   ┌──────────────────────────────┼───────────────────────────────┐
   │                              │                               │
n8n-postgres.service         n8n.service  ──Wants──▶    n8n-runners.service
postgres:16.15-alpine        n8nio/n8n:2.43.6        n8nio/runners:2.43.6
   │  volume                    │  volume                │
   │  n8n_postgres_data         │  n8n_n8n_data          └── JS + Python Code nodes
   └──────────────────── network n8n-network ──────────────────────┘
                                  │
                     PublishPort HOST_BIND:HOST_PORT -> 5678
                     (127.0.0.1:15678 by default; a Cloudflare
                      tunnel or NPM provides public access)
```

| File | Unit | What it is |
|---|---|---|
| `quadlet/n8n.network` | `n8n-network.service` | bridge network `n8n-network` |
| `quadlet/n8n-data.volume` | `n8n-data-volume.service` | volume `n8n_n8n_data`: **the credentials encryption key** |
| `quadlet/n8n-postgres-data.volume` | `n8n-postgres-data-volume.service` | volume `n8n_postgres_data`: PGDATA |
| `quadlet/n8n-postgres.container` | `n8n-postgres.service` | PostgreSQL 16 |
| `quadlet/n8n.container` | `n8n.service` | n8n (editor, REST API, webhooks, task broker) |
| `quadlet/optional/n8n-runners.container` | `n8n-runners.service` | external task runners (default; `--no-runners` skips them) |
| `quadlet/queue/n8n-valkey.container` and `n8n-valkey-data.volume` | `n8n-valkey.service` | optional password-protected queue broker and persistent AOF volume |
| `quadlet/queue/n8n-worker.container` and `n8n-worker-runners.container` | worker services | optional queue worker and its matching Code-node runner |
| `quadlet/queue/n8n-webhook.container` | `n8n-webhook.service` | optional dedicated production webhook processor |
| `config/n8n-task-runners.json` | mounted in the runner | same JavaScript and Python import permissions as the HA add-on |
| `systemd/n8n.target` | `n8n.target` | one handle for the whole stack |

Installed to `~/.config/containers/systemd/` (Quadlet), `~/.config/systemd/user/` (target) and
`~/.config/n8n/n8n.env` (settings, mode 0600). Passwords are podman secrets, never env files.

## Requirements

- Ubuntu 24.04 or similar, **podman >= 4.9.3** rootless, systemd 255 user units
- linger for the service user (`sudo loginctl enable-linger $USER`), so the stack survives logout
- about 1.5 GB of disk for the images (n8n, runners, postgres)

```bash
podman --version && systemctl --user show-environment >/dev/null && echo "user manager ok"
```

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_n8n ~/woow-quadlet/Woow_podman_n8n
cd ~/woow-quadlet/Woow_podman_n8n
tests/dryrun.sh                 # optional: validates the units against the local generator
scripts/install.sh              # first run: creates ~/.config/n8n/n8n.env and stops
$EDITOR ~/.config/n8n/n8n.env   # set HOST_BIND/HOST_PORT, the timezone, the public URL
scripts/install.sh              # installs, starts and runs the smoke test
```

Behind a Cloudflare tunnel or Nginx Proxy Manager, name the public URL — n8n puts it into
webhook URLs and OAuth callbacks:

```bash
scripts/install.sh --public-url https://n8n.example.com/
```

The first person to open the editor becomes the owner. **Put the instance behind
authentication (Cloudflare Access, NPM) or create the owner immediately.**

Options: `--no-runners` (internal task runners), `--db-password-file F` (first install only),
`--no-start`, `--no-smoke`, `--smoke-timeout S`, `--dry-run` (render and validate only).

## Configuration

`~/.config/n8n/n8n.env`, mode 0600, `KEY=value` lines only — no quotes, no inline comments.
`HOST_*` keys are rendered into the unit files at install time (decision D2); every other key
is passed to the n8n container, so any [n8n environment variable](https://docs.n8n.io/hosting/configuration/environment-variables/)
works. Re-run `scripts/install.sh` after an edit: it restarts only what changed.

| Key | Default | Meaning |
|---|---|---|
| `HOST_BIND` | `127.0.0.1` | publish address. `0.0.0.0` exposes n8n on every interface |
| `HOST_PORT` | `15678` | published port (n8n listens on 5678 inside the container) |
| `WEBHOOK_PORT` | `15679` | separate published port when the webhook processor is enabled |
| `N8N_HOST`, `N8N_PROTOCOL` | `localhost`, `http` | hostname and scheme n8n believes it is reached at |
| `N8N_EDITOR_BASE_URL`, `N8N_WEBHOOK_URL` | unset | public URLs (set by `--public-url`) |
| `N8N_PROXY_HOPS` | unset | number of proxies in front (1 for a tunnel or NPM) |
| `GENERIC_TIMEZONE`, `TZ` | `Asia/Taipei` | schedule and log timezone |
| `N8N_RUNNERS_MODE` | `external` | `external` installs the sidecar, `internal` runs code inside n8n |
| `EXECUTIONS_MODE` | `regular` | `queue` installs Valkey, one worker and its own task runner; requires external runners |
| `WORKER_CONCURRENCY` | `5` | concurrent queued executions in the worker (1–100) |
| `N8N_QUEUE_WEBHOOK_PROCESSOR` | `false` | in queue mode, also run a dedicated webhook process |
| `N8N_QUEUE_DISABLE_MAIN_WEBHOOKS` | `false` | stop production webhooks on the main process after the proxy route is working |

Do not set `N8N_PORT` (n8n's port inside the container) or the `DB_POSTGRESDB_*` keys; the
units own them. `install.sh` warns about keys it ignores.

**Secrets** (podman secrets, created on the first install, never printed):

| Secret | Used by |
|---|---|
| `n8n-db-password` | `POSTGRES_PASSWORD` for PostgreSQL; mounted as a file for n8n |
| `n8n-runners-auth-token` | mounted as a file for n8n; passed to the separate runner launcher; required even in internal mode |
| `n8n-valkey-password` | mounted as a file in n8n and Valkey; created when queue mode is selected |

**Task runners.** External runners run Code-node JavaScript and Python in their own container,
which is upstream's recommendation: in internal mode a workflow author can read the encryption
key and every stored credential. `n8nio/n8n` and `n8nio/runners` must carry the same version;
`tests/dryrun.sh` and `scripts/upgrade.sh` enforce that. The launcher starts before n8n so n8n
can finish executions before the launcher stops. The runner config permits the same JavaScript
and Python module imports as the HA add-on. Only the runner receives the broker token as an
environment variable; the tested JavaScript and Python Code nodes cannot read either secret
through their environment.

`N8N_BLOCK_ENV_ACCESS_IN_NODE=false` matches the HA add-on so existing workflow expressions
can read non-secret settings. A workflow editor can read any additional environment variables
placed in `n8n.env`; store provider credentials in n8n Credentials instead.

## Optional queue mode

Set `EXECUTIONS_MODE=queue` in `~/.config/n8n/n8n.env`, then run
`scripts/install.sh --dry-run` and `scripts/install.sh`. On an existing installation, the
installer takes a **cold backup before switching topology**, stops the application processes,
and starts the new stack. Queue mode keeps PostgreSQL as the database, uses a private Valkey
with persistent AOF, and gives each n8n process a distinct event-log file on the shared
`n8n_n8n_data` volume. The one worker runs with configurable concurrency (5 by default) and has its own matching
JavaScript/Python runner. Queue mode uses database binary storage, as required by
[n8n queue mode](https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/enable-queue-mode/).

To add the optional processor, set `N8N_QUEUE_WEBHOOK_PROCESSOR=true` and choose a free
`WEBHOOK_PORT`. Route `/webhook/*` and `/webhook-waiting/*` to `HOST_BIND:WEBHOOK_PORT`;
route `/webhook-test/*`, the editor and API to `HOST_BIND:HOST_PORT`. Check a production
webhook through the public URL before setting `N8N_QUEUE_DISABLE_MAIN_WEBHOOKS=true` and
running `scripts/install.sh` again. Only the main process receives the corresponding n8n
setting. `--public-url` still identifies the public URL; it does not configure the reverse
proxy. See the [n8n webhook processor routing guide](https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/enable-queue-mode/).

Run `tests/smoke.sh` after changing topology. `tests/queue-integration.py` exercises an
independent queue stack with PostgreSQL, Valkey, both runners and a real Code-node webhook;
it needs the four pinned images locally and removes its test resources. To return to regular
mode, set `N8N_QUEUE_DISABLE_MAIN_WEBHOOKS=false`,
`N8N_QUEUE_WEBHOOK_PROCESSOR=false`, `EXECUTIONS_MODE=regular`, then run
`scripts/install.sh`. The old Valkey data volume and secret remain available for a later
queue restore until an explicit purge.

## Operations

```bash
systemctl --user status n8n.service              # one unit
systemctl --user restart n8n.target              # the whole stack
journalctl --user -u n8n.service -f              # logs (LogDriver=journald)
systemctl --user list-timers                     # nothing here; n8n has no timers
podman exec n8n n8n --version
tests/smoke.sh                                   # health checks, changes nothing
tests/smoke.sh --public-url https://n8n.example.com/
```

If Podman storage was reset while systemd stayed running, its one-shot network and volume
units can still report `active` even though their resources are gone. Re-run `scripts/install.sh`;
it checks for missing n8n resources and recreates them before starting the containers. This
creates empty volumes, so recover data from a backup first when the old data matters.

## Upgrade

The repository is the source of truth: bump `Image=` in `quadlet/n8n.container` **and**
`quadlet/optional/n8n-runners.container`, `quadlet/queue/n8n-worker.container`,
`quadlet/queue/n8n-webhook.container`, and `quadlet/queue/n8n-worker-runners.container`
(same n8n or runner version), commit, then:

```bash
git pull
scripts/upgrade.sh              # --allow-major for 2.x -> 3.x
```

It refuses a downgrade, a version skew between n8n and the runners, and a Postgres major
change; pulls every image before anything stops; backs up; restarts; runs the smoke test with a
900 s timeout; and on failure puts the previous units back and restores the pre-upgrade
database automatically (n8n migrations are forward-only). Queue-mode upgrades use a cold
backup and restore both the database and Valkey state on failure. An existing host's `n8n.env` does
not receive new defaults automatically; compare it with `config/n8n.env.example` before upgrading.
For n8n 2.43.6, re-create older API keys if public API calls return 403 due to missing scopes.

**Postgres major upgrade** (16 -> 17) is a separate job: `scripts/backup.sh --cold`, bump the
image, delete the volume `n8n_postgres_data`, `scripts/install.sh`, then `scripts/restore.sh`.

## Backup and restore

```bash
scripts/backup.sh                     # regular: hot; queue: automatically cold
scripts/backup.sh --cold              # consistent DB dump and exports all active volumes
scripts/restore.sh ~/backups/n8n/<timestamp> [--yes]
```

A backup directory is mode 0700 and carries `SHA256SUMS`, which `restore.sh` verifies. It
contains the **credentials encryption key** (`n8n_n8n_data`) and the database password: store
copies off this host, and treat them like the credentials themselves. Without the encryption
key the credentials in a restored database cannot be decrypted.
Queue backups also contain `n8n_valkey_data` and its secret; restore a queue backup into a
queue-mode installation, so the database and pending jobs match.

A nightly backup, as the service user:

```bash
systemd-run --user --on-calendar='*-*-* 03:30:00' --unit=n8n-backup \
  ~/woow-quadlet/Woow_podman_n8n/scripts/backup.sh
```

## Uninstall

```bash
scripts/uninstall.sh                  # stops and removes the units; keeps all data
scripts/uninstall.sh --purge --yes    # also deletes the volumes, network and secrets
```

`--purge` is the only way this repo deletes data, and it exports the active volumes and secrets
to `~/backups/n8n/purge-<timestamp>/` first. `~/.config/n8n/n8n.env` is always kept.

## Migrating an existing compose or podman-compose deployment

`scripts/migrate-legacy.sh` adopts the existing volumes (`n8n_n8n_data`, `n8n_postgres_data`)
and the network `n8n-network` in place — no data is copied — and keeps the old containers and
unit for rollback. Downtime is 2-3 minutes.

```bash
# 1. check and prepare while the old stack keeps running (no downtime)
scripts/migrate-legacy.sh --legacy-dir ~/podman/Woow_podman_n8n --dry-run
scripts/migrate-legacy.sh --legacy-dir ~/podman/Woow_podman_n8n \
    --public-url https://n8n.example.com/ --prepare-only

# 2. cutover (downtime starts): stop, cold export, retire the legacy containers, install, smoke
scripts/migrate-legacy.sh --legacy-dir ~/podman/Woow_podman_n8n \
    --public-url https://n8n.example.com/ --yes

# 3. if anything is wrong (about 1 minute, no data loss)
scripts/migrate-legacy.sh --rollback --yes
```

What it does: checks that the legacy containers run the version this repo pins and that the
volumes carry the expected names; writes `~/.config/n8n/n8n.env` from the legacy `.env`;
creates `n8n-db-password` from the legacy `POSTGRES_PASSWORD`; takes a hot dump and, after the
stop, a cold export of both volumes; disables `podman-n8n.service` (the file stays on disk);
retires the legacy containers (see below); installs; and compares the workflow, credential and
user counts. A failed cutover rolls back automatically (`--no-auto-rollback` keeps it for
inspection).

### How the legacy containers are kept for rollback

Renaming a legacy container and leaving it stopped is a rollback path only while nothing
starts it again. The user unit `podman-restart.service` runs
`podman start --all --filter restart-policy=always` at boot, so on a host where that unit is
**enabled** a renamed, stopped container whose restart policy is exactly `always` revives at
the next boot and fights the new Quadlet container for its name, ports and volumes. podman
4.9.3 cannot repair that afterwards: `podman update` only rewrites cgroup limits, and a
restart policy is fixed at create time.

The script therefore asks `ql_rollback_strategy` — which reads this host's real state, never
its name — and takes one of two paths. `--dry-run` prints which one applies here.

| Answer | When | What the cutover does | What `--rollback` does |
|---|---|---|---|
| `rename` | the unit is disabled, or no legacy container has policy `always` | `podman rename <name> <name>-legacy-YYYYMMDD`, left stopped | renames it back |
| `capture` | the unit is enabled **and** a legacy container has policy `always` | writes `<backup>/legacy-container/<name>/` (inspect, create command, image, policy, mounts, networks) and then a plain `podman rm` — never `podman rm -v`, which would delete the anonymous volumes | `ql_recreate_container` recreates it stopped, with its original restart policy |

n8n's two containers are `unless-stopped` on both WOOWTECH hosts, so in practice both take the
`rename` path; the earlier blanket refusal to run at all while `podman-restart.service` was
enabled blocked a migration that is in fact safe.

The capture cannot bring back a container's **writable layer** — anything written inside the
container that did not land in a volume or a bind mount. n8n keeps its data in
`n8n_n8n_data` (`/home/node/.n8n`), and its writable layer on the live hosts holds nothing but
a symlink, so nothing is lost. (`ql_capture_container --commit` exists for a stack that
mutates its own container; n8n does not need it.) The container id and the IP/MAC lease are
not preserved either. `tests/rollback-model.sh` pins both paths.

Changes the migration makes on purpose: the publish moves from `0.0.0.0` to `127.0.0.1`
(`--bind` overrides), secure cookies stay on, `WEBHOOK_URL` becomes `N8N_WEBHOOK_URL`, and the
task runners move out of the n8n process.

**After the soak period** (a week, including one reboot):

```bash
podman rm n8n-legacy-YYYYMMDD n8n-postgres-legacy-YYYYMMDD   # rename path only
rm ~/.config/systemd/user/podman-n8n.service && systemctl --user daemon-reload
podman untag docker.io/n8nio/n8n:latest docker.io/library/postgres:16-alpine
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Unit n8n.service not found` | the generator rejected a file. Run `tests/dryrun.sh`, then `systemctl --user daemon-reload` |
| install refuses: *legacy container* | a non-Quadlet container owns the name. Quadlet's `--replace` would delete it: rename it (the message prints the command) or use `migrate-legacy.sh` |
| login loop, "secure cookie" warning | you reach n8n over plain http from another machine. Use the public https URL, or set `N8N_SECURE_COOKIE=false` (not recommended) |
| webhooks point at the wrong host | set the public URL: `scripts/install.sh --public-url https://…/` |
| `Python 3 is missing` in the log | internal runner mode; set `N8N_RUNNERS_MODE=external` and re-run `install.sh` |
| the stack does not come back after a reboot | linger is off: `sudo loginctl enable-linger $USER` |

## Docker Compose

This repository is Quadlet-only. The last revision with `docker-compose.yml` is tagged
[`compose-final`](https://github.com/WOOWTECH/Woow_podman_n8n/tree/compose-final):

```bash
git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_n8n
```

New Docker deployments should follow n8n's own
[Docker Compose guide](https://docs.n8n.io/hosting/installation/server-setups/docker-compose/).

## Other deployment platforms

- **K3s / Kubernetes (Helm chart)** → [Woow_k3s_n8n](https://github.com/WOOWTECH/Woow_k3s_n8n)
- **Home Assistant add-on** → [Woow_ha_n8n](https://github.com/WOOWTECH/Woow_ha_n8n)
