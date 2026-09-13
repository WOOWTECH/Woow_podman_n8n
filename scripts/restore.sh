#!/usr/bin/env bash
# scripts/restore.sh: put a scripts/backup.sh backup back into the installed n8n stack.
#
#   scripts/restore.sh <backup-dir> [--yes]
#
# 1. verifies SHA256SUMS
# 2. stops n8n and the runners (Postgres keeps running)
# 3. restores the secrets and the Postgres roles from the backup (the role password hash
#    and the n8n-db-password secret travel together, so they always match)
# 4. drops and recreates the n8n database from n8n-pg.dump (pg_restore --clean --create)
# 5. re-imports the n8n_n8n_data volume (the credentials encryption key)
# 6. starts n8n.target and runs tests/smoke.sh
# The stack must be installed first (scripts/install.sh). Current data is replaced.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

src='' ASSUME_YES=0
while (($#)); do
  case $1 in
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $src ]] || ql_die "one backup directory only"; src=$1 ;;
  esac
  shift
done
[[ -n $src ]] || ql_die "usage: scripts/restore.sh <backup-dir> [--yes]"
src=$(cd -- "$src" && pwd -P) || ql_die "no such directory: $src"
ql_require_rootless
[[ ${WOOW_QL_LOCK_HELD:-} == "$APP" ]] || ql_lock "$APP"
app_require_installed
ql_env_load "$ENV_FILE"

[[ -f $src/SHA256SUMS ]] || ql_die "$src/SHA256SUMS is missing: not a scripts/backup.sh backup"
(cd -- "$src" && sha256sum -c --quiet SHA256SUMS) || ql_die "checksum mismatch in $src"
dump=$src/n8n-pg.dump
shopt -s nullglob
tars=("$src/$DATA_VOLUME"-*.tar)
shopt -u nullglob
[[ -f $dump ]] || ql_die "$dump is missing"
((${#tars[@]} == 1)) || ql_die "expected exactly one $DATA_VOLUME-*.tar in $src, found ${#tars[@]}"
app_confirm "restore replaces the n8n database and the $DATA_VOLUME volume with $src"

ql_info "stopping n8n (Postgres keeps running)"
systemctl --user stop n8n-runners.service n8n.service
systemctl --user start n8n-postgres.service
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$DB_CONTAINER" 180 || ql_die "$DB_CONTAINER is not healthy"

for f in "$src"/secrets/*; do
  [[ -f $f ]] || continue
  ql_secret_ensure "${f##*/}" "file:$f" --update
done
[[ ! -f $src/roles.sql ]] || app_restore_roles "$src/roles.sql"
app_restore_db "$dump"

app_volume_replace "$DATA_VOLUME" "${tars[0]}"

mapfile -t units < <(app_units)
systemctl --user start "${units[@]}"
"$REPO/tests/smoke.sh" --timeout 600 || ql_die "restored, but the smoke test failed; see: journalctl --user -u n8n.service -n 100"
ql_info "restore of $src complete"
