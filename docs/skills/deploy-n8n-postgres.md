# Skill: Deploy n8n + PostgreSQL (rootless Podman Quadlet)

## Metadata

- **Name**: deploy-n8n-postgres
- **Description**: Deploy n8n with PostgreSQL and external task runners as rootless Podman
  Quadlet units managed by the user's systemd
- **Trigger**: the user asks to deploy n8n, set up n8n, or migrate an n8n compose stack
- **Repository**: https://github.com/WOOWTECH/Woow_podman_n8n

## Prerequisites

- Ubuntu 24.04 or similar, rootless podman >= 4.9.3, systemd 255 user units
- linger enabled for the service user: `sudo loginctl enable-linger $USER`
- Never run these scripts as root or through `sudo`: the containers belong to the user.

## Fresh install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_n8n ~/woow-quadlet/Woow_podman_n8n
cd ~/woow-quadlet/Woow_podman_n8n
tests/dryrun.sh                                   # validates the units, creates nothing
scripts/install.sh                                # creates ~/.config/n8n/n8n.env, then stops
# edit HOST_BIND, HOST_PORT, GENERIC_TIMEZONE/TZ in ~/.config/n8n/n8n.env
scripts/install.sh --public-url https://n8n.example.com/   # omit behind no proxy
```

`install.sh` is idempotent: run it again after any change to the repo or the env file. It
restarts only the units whose file or environment changed and finishes with `tests/smoke.sh`.

**Security gate:** the first visitor to the editor becomes the owner. Either create the owner
straight away, or keep the instance unpublished until an authentication layer (Cloudflare
Access, NPM access list) is in place.

## Verify

```bash
tests/smoke.sh                        # units, healthchecks, /healthz, versions, listeners
curl -fsS http://127.0.0.1:15678/healthz       # {"status":"ok"}
systemctl --user status n8n.target
```

## Migrate an existing compose / podman-compose deployment

```bash
scripts/migrate-legacy.sh --legacy-dir <old checkout with .env> --dry-run
scripts/migrate-legacy.sh --legacy-dir <old checkout> --public-url https://n8n.example.com/ --prepare-only
scripts/migrate-legacy.sh --legacy-dir <old checkout> --public-url https://n8n.example.com/ --yes
scripts/migrate-legacy.sh --rollback --yes      # if anything is wrong
```

The volumes `n8n_n8n_data` and `n8n_postgres_data` and the network `n8n-network` are adopted
by name, so no data is copied. The legacy containers are renamed `<name>-legacy-YYYYMMDD` and
`podman-n8n.service` is disabled but kept, which is what makes the rollback fast.

## Day-2 operations

| Task | Command |
|---|---|
| logs | `journalctl --user -u n8n.service -f` |
| restart the stack | `systemctl --user restart n8n.target` |
| upgrade | bump both `Image=` pins, `git pull`, `scripts/upgrade.sh` |
| backup | `scripts/backup.sh` (add `--cold` for a byte copy of PGDATA) |
| restore | `scripts/restore.sh ~/backups/n8n/<timestamp>` |
| uninstall | `scripts/uninstall.sh` (`--purge --yes` also deletes the data) |

## Architecture

```
n8n.target
├── n8n-postgres.service   docker.io/library/postgres:16.15-alpine   volume n8n_postgres_data
├── n8n.service            docker.io/n8nio/n8n:2.38.7                volume n8n_n8n_data
│                          PublishPort HOST_BIND:HOST_PORT -> 5678
└── n8n-runners.service    docker.io/n8nio/runners:2.38.7            (optional, same version)
network n8n-network · secrets n8n-db-password, n8n-runners-auth-token
```

## Rules for an agent working on this repo

1. The repo is the source of truth for versions. Never edit a unit file on the host; change
   `quadlet/*` here and run `scripts/install.sh`.
2. `n8nio/n8n` and `n8nio/runners` must always carry the same version.
3. Never put a password into `~/.config/n8n/n8n.env` or a unit: use podman secrets.
4. Never delete a volume to "clean up". `uninstall.sh --purge` exists and takes a backup first.
5. `scripts/lib/quadlet-lib.sh` is vendored and verified by CI; upstream changes to it belong
   in Woow_quadlet_migration_plan/lib, not here.
