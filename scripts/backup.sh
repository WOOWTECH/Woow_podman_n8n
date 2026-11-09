#!/usr/bin/env bash
# scripts/backup.sh: back up the n8n stack into a private (0700) directory.
#
#   scripts/backup.sh [--dest DIR] [--cold]
#
#   (default)   hot backup in regular mode; automatically cold in queue mode:
#                 n8n-pg.dump        pg_dump -Fc of the n8n database
#                 roles.sql          the Postgres roles with their password hashes
#                 n8n_n8n_data-*.tar podman volume export (encryption key, custom nodes)
#                 secrets/           database, runner and optional Valkey secrets (0600)
#                 n8n.env, units/, images.txt, SHA256SUMS
#   --cold      stop n8n processes before the database dump; stop PostgreSQL before
#               exporting n8n_postgres_data, and queue-mode n8n_valkey_data; restart
#   --dest DIR  default ~/backups/n8n/<YYYYmmdd-HHMMSS>
#
# restore.sh <DIR> puts a backup back. Keep backups off this disk too: they contain the
# credentials encryption key and the DB password.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

dest='' cold=0
while (($#)); do
  case $1 in
    --dest) dest=${2:?--dest needs a directory}; shift ;;
    --cold) cold=1 ;;
    -h | --help) sed -n '2,18p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
app_running "$DB_CONTAINER" || ql_die "$DB_CONTAINER is not running (start it: systemctl --user start $TARGET)"
if app_installed_queue_enabled && ((!cold)); then
  ql_info 'queue mode requires a consistent database and Valkey snapshot; using --cold'
  cold=1
fi
mapfile -t installed_units < <(app_installed_units)
running_version=$(app_running_version)

dest=$(app_new_backup_dir "$dest")
ql_info "backing up $APP to $dest"

# Stop queue producers and consumers before the dump, then PostgreSQL before byte exports.
restart=0
restart_stack() {
  ((restart)) || return 0
  systemctl --user start "${installed_units[@]}" || ql_warn 'could not restart all n8n units'
}
if ((cold)); then
  ql_cleanup restart restart_stack
  restart=1
  ql_info 'stopping n8n application processes for a consistent cold backup'
  app_stop_runtime
fi

# ---- database, secrets and metadata -------------------------------------------------------
app_dump_db "$dest/n8n-pg.dump"
app_dump_roles "$dest/roles.sql"
mkdir -p "$dest/secrets"
for s in "$SECRET_DB" "$SECRET_RUNNERS" "$SECRET_VALKEY"; do
  if podman secret exists "$s"; then app_save_secret "$s" "$dest/secrets/$s"; fi
done
[[ ! -f $ENV_FILE ]] || cp -p -- "$ENV_FILE" "$dest/"
if app_is_installed; then app_snapshot_units "$dest/units"; fi
{
  printf 'n8n version: %s\n' "$running_version"
  podman ps -a --filter label=io.woowtech.app=n8n --format '{{.Names}} {{.Image}} {{.ImageID}}' 2>/dev/null || true
  for i in "$N8N_IMAGE" "$RUNNERS_IMAGE" "$PG_IMAGE" "$VALKEY_IMAGE"; do
    printf '%s %s\n' "$i" "$(podman image inspect --format '{{index .RepoDigests 0}}' "$i" 2>/dev/null || echo '?')"
  done
} >"$dest/images.txt"

if ((cold)); then
  systemctl --user stop n8n-postgres.service || ql_die 'cannot stop n8n-postgres.service'
fi
ql_backup_volume "$DATA_VOLUME" "$dest" >/dev/null
if ((cold)); then
  ql_backup_volume "$DB_VOLUME" "$dest" >/dev/null
  if app_installed_queue_enabled; then ql_backup_volume "$VALKEY_VOLUME" "$dest" >/dev/null; fi
fi
if ((restart)); then
  systemctl --user start "${installed_units[@]}"
  restart=0
fi

app_write_checksums "$dest"
ql_info "backup complete: $dest ($(du -sh -- "$dest" | cut -f1))"
printf '%s\n' "$dest"
