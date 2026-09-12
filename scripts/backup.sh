#!/usr/bin/env bash
# scripts/backup.sh: back up the n8n stack into a private (0700) directory.
#
#   scripts/backup.sh [--dest DIR] [--cold]
#
#   (default)   hot backup while n8n runs:
#                 n8n-pg.dump        pg_dump -Fc of the n8n database
#                 roles.sql          the Postgres roles with their password hashes
#                 n8n_n8n_data-*.tar podman volume export (encryption key, custom nodes)
#                 secrets/           n8n-db-password, n8n-runners-auth-token (0600)
#                 n8n.env, units/, images.txt, SHA256SUMS
#   --cold      also stop n8n.target and export n8n_postgres_data (a byte copy of PGDATA),
#               then start the stack again
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
[[ ${WOOW_QL_LOCK_HELD:-} == "$APP" ]] || ql_lock "$APP"
app_running "$DB_CONTAINER" || ql_die "$DB_CONTAINER is not running (start it: systemctl --user start $TARGET)"

dest=$(app_new_backup_dir "$dest")
ql_info "backing up $APP to $dest"

# ---- hot part ----------------------------------------------------------------------------
app_dump_db "$dest/n8n-pg.dump"
app_dump_roles "$dest/roles.sql"
mkdir -p "$dest/secrets"
for s in "$SECRET_DB" "$SECRET_RUNNERS"; do
  if podman secret exists "$s"; then app_save_secret "$s" "$dest/secrets/$s"; fi
done
[[ ! -f $ENV_FILE ]] || cp -p -- "$ENV_FILE" "$dest/"
if app_is_installed; then app_snapshot_units "$dest/units"; fi
{
  printf 'n8n version: %s\n' "$(app_running_version)"
  podman ps -a --filter label=io.woowtech.app=n8n --format '{{.Names}} {{.Image}} {{.ImageID}}' 2>/dev/null || true
  for i in "$N8N_IMAGE" "$RUNNERS_IMAGE" "$PG_IMAGE"; do
    printf '%s %s\n' "$i" "$(podman image inspect --format '{{index .RepoDigests 0}}' "$i" 2>/dev/null || echo '?')"
  done
} >"$dest/images.txt"

# ---- cold part: PGDATA as bytes, with the whole stack stopped ------------------------------
restart=0
if ((cold)); then
  mapfile -t units < <(app_units)
  trap 'if ((restart)); then systemctl --user start "$TARGET" || ql_warn "could not restart $TARGET"; fi' EXIT
  ql_info "stopping $TARGET for the cold export"
  restart=1
  systemctl --user stop "${units[@]}"
fi
ql_backup_volume "$DATA_VOLUME" "$dest" >/dev/null
((!cold)) || ql_backup_volume "$DB_VOLUME" "$dest" >/dev/null
if ((restart)); then
  systemctl --user start "$TARGET"
  restart=0
fi

app_write_checksums "$dest"
ql_info "backup complete: $dest ($(du -sh -- "$dest" | cut -f1))"
printf '%s\n' "$dest"
