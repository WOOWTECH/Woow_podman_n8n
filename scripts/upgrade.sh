#!/usr/bin/env bash
# scripts/upgrade.sh: move the installed n8n stack to the versions pinned in this checkout.
# The repo is the source of truth: an upgrade is `git pull` (a commit that bumps Image=),
# then this script.
#
#   scripts/upgrade.sh [--allow-major] [--yes]
#
# backup -> pull -> restart -> smoke -> automatic rollback:
#  1. gates (before anything stops): the n8nio/n8n and n8nio/runners pins are equal; no
#     downgrade; a major bump (2.x -> 3.x) needs --allow-major; the Postgres major version
#     must not change (16 -> 17 is a dump/restore job, see README).
#  2. pulls every pinned image; a failed pull changes nothing
#  3. scripts/backup.sh into ~/backups/n8n/upgrade-<timestamp>/ (DB dump + installed units)
#  4. scripts/install.sh installs the new units and restarts what changed; tests/smoke.sh
#     waits up to 900 s because n8n migrates its database on the first start
#  5. on failure: stop n8n, put the previous units back, restore the database from the
#     pre-upgrade dump (n8n migrations are forward-only), start, smoke, exit 1
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

allow_major=0 ASSUME_YES=0
while (($#)); do
  case $1 in
    --allow-major) allow_major=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
app_require_installed
ql_env_load "$ENV_FILE"
app_validate_env

# ---- 1. gates -------------------------------------------------------------------------------
[[ $(app_tag "$RUNNERS_IMAGE") == "$N8N_VERSION" ]] \
  || ql_die "the pins disagree: $N8N_IMAGE vs $RUNNERS_IMAGE (n8n and runners must carry the same version)"
tgt=$N8N_VERSION
cur=$(app_running_version)
if [[ -z $cur ]]; then
  cur=$(app_tag "$(sed -n 's/^Image=//p' "$QDIR/n8n.container" 2>/dev/null)")
  ql_warn "n8n is not running; comparing with the installed unit (${cur:-unknown})"
fi
[[ $cur =~ ^[0-9]+(\.[0-9]+)*$ ]] || ql_die "cannot determine the current n8n version ('$cur')"
version_change=0
if [[ $cur != "$tgt" ]]; then
  [[ $(printf '%s\n%s\n' "$cur" "$tgt" | sort -V | head -n1) == "$cur" ]] \
    || ql_die "downgrade $cur -> $tgt is not supported (n8n migrations are forward-only); restore a backup instead"
  if ((10#${tgt%%.*} > 10#${cur%%.*} && !allow_major)); then
    ql_die "major upgrade $cur -> $tgt: read https://docs.n8n.io/release-notes/ first, then re-run with --allow-major"
  fi
  version_change=1
fi
pg_cur=$(podman exec "$DB_CONTAINER" sh -c 'echo "$PG_MAJOR"' 2>/dev/null || true)
pg_tgt=$(app_tag "$PG_IMAGE")
pg_tgt=${pg_tgt%%[.-]*}
if [[ -n $pg_cur && $pg_cur != "$pg_tgt" ]]; then
  ql_die "the Postgres pin moves from major $pg_cur to $pg_tgt; that needs a dump/restore into a new volume (README: Postgres major upgrade)"
fi
if ((version_change)); then
  app_confirm "upgrade n8n $cur -> $tgt (a backup is taken first; failure rolls back automatically)"
else
  ql_info "n8n is already at $tgt; applying unit changes only"
fi

# ---- 2. pull before anything stops --------------------------------------------------------------
for i in "$N8N_IMAGE" "$RUNNERS_IMAGE" "$PG_IMAGE"; do
  podman image exists "$i" || { ql_info "pulling $i"; podman pull "$i" >/dev/null; } || ql_die "podman pull $i failed; nothing was changed"
done

# ---- 3. backup ------------------------------------------------------------------------------------
bk=$("$REPO/scripts/backup.sh" --dest "$BACKUP_ROOT/upgrade-$(date +%Y%m%d-%H%M%S)" | tail -n1)
[[ -f $bk/n8n-pg.dump && -d $bk/units ]] || ql_die "the pre-upgrade backup is incomplete ($bk); nothing was changed"

# ---- 4. install + restart + smoke ------------------------------------------------------------------
if ! "$REPO/scripts/install.sh" --no-start --no-smoke; then
  ql_warn "install.sh failed before anything restarted; putting the previous units back"
  ql_install_files "$bk/units" "$APP" --prune >/dev/null
  systemctl --user daemon-reload
  ql_die "upgrade aborted; the stack still runs $cur (backup: $bk)"
fi
if "$REPO/scripts/install.sh" --smoke-timeout 900; then
  ql_info "upgrade to $tgt complete (pre-upgrade backup: $bk)"
  exit 0
fi

# ---- 5. automatic rollback ---------------------------------------------------------------------
# rollback_incomplete: say so if this script ends before the rollback below finishes.
# A hook, not `trap ... EXIT`: a bare trap would replace the handler ql_lock armed and
# leave the lock directory behind, so every later run would report a takeover.
# shellcheck disable=SC2317,SC2329 # invoked indirectly, as the ql_cleanup hook registered below
rollback_incomplete() {
  local rc=$?
  ((rc == 0)) || ql_warn "ROLLBACK INCOMPLETE (rc=$rc). Backup: $bk. Restore by hand: scripts/restore.sh $bk"
}
ql_cleanup rollback rollback_incomplete
ql_warn "upgrade to $tgt failed; rolling back to $cur"
systemctl --user stop n8n-runners.service n8n.service || true
ql_install_files "$bk/units" "$APP" --prune >/dev/null
ql_apply_units "$APP" n8n-postgres.service
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$DB_CONTAINER" 180 || ql_die "$DB_CONTAINER did not come back"
if ((version_change)); then
  ql_info "restoring the pre-upgrade database (the new version may have migrated it)"
  app_restore_db "$bk/n8n-pg.dump"
fi
mapfile -t units < <(app_units)
ql_apply_units "$APP" "${units[@]}"
app_env_record
"$REPO/tests/smoke.sh" --timeout 600 || ql_die "the rolled-back stack failed its smoke test"
ql_cleanup_clear rollback
ql_warn "rolled back to $cur; the upgrade to $tgt did not pass (backup: $bk)"
exit 1
