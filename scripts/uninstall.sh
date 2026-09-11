#!/usr/bin/env bash
# scripts/uninstall.sh: remove the n8n Quadlet units. Keeps every piece of data by default.
#
#   scripts/uninstall.sh                   stop and remove the units; keep volumes, network,
#                                          secrets, images and ~/.config/n8n/n8n.env
#   scripts/uninstall.sh --purge [--yes]   also delete the volumes n8n_n8n_data and
#                                          n8n_postgres_data, the network and the secrets,
#                                          after a final cold export to ~/backups/n8n/
#   scripts/uninstall.sh --dry-run         report what would be removed
#
# --purge is the only way this repo deletes data. n8n_n8n_data holds the credentials
# encryption key: without it (or the final export) the stored credentials are lost.
# Never touched: ~/.config/n8n/n8n.env, images, podman.socket, *-legacy-* containers.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

purge=0 ASSUME_YES=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"

if ((!purge)); then
  ql_uninstall_units "$APP"
  [[ ${QL_DRY_RUN:-0} == 1 ]] || rm -f -- "$APP_STATE_DIR/env.sha256"
  ql_info "kept: volumes $DATA_VOLUME and $DB_VOLUME, secrets, $ENV_FILE"
  exit 0
fi

app_confirm "--purge deletes the n8n volumes (workflows, credentials, encryption key), network and secrets"
if [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  # Stop first, so the final export of PGDATA is consistent.
  systemctl --user stop "$TARGET" n8n-runners.service n8n.service n8n-postgres.service 2>/dev/null || true
  dest=$(app_new_backup_dir "$BACKUP_ROOT/purge-$(date +%Y%m%d-%H%M%S)")
  for v in "$DATA_VOLUME" "$DB_VOLUME"; do
    if podman volume exists "$v"; then ql_backup_volume "$v" "$dest" >/dev/null; fi
  done
  for s in "$SECRET_DB" "$SECRET_RUNNERS"; do
    if podman secret exists "$s"; then mkdir -p "$dest/secrets" && app_save_secret "$s" "$dest/secrets/$s"; fi
  done
  [[ ! -f $ENV_FILE ]] || cp -p -- "$ENV_FILE" "$dest/"
  app_write_checksums "$dest"
  ql_info "final backup: $dest"
fi
ql_uninstall_units "$APP" --purge
ql_info "the env file $ENV_FILE is kept; delete ~/.config/n8n yourself if you no longer need it"
