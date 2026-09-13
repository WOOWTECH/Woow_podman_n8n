#!/usr/bin/env bash
# scripts/migrate-legacy.sh: move a podman-compose n8n deployment (containers n8n and
# n8n-postgres, volumes n8n_n8n_data and n8n_postgres_data, network n8n-network and a
# hand-written podman-n8n.service) to the Quadlet units of this repo, adopting the data in
# place. Nothing is deleted: the legacy containers and unit stay for --rollback.
#
#   scripts/migrate-legacy.sh --legacy-dir DIR [--public-url URL] [--bind ADDR]
#                             [--suffix YYYYMMDD] [--prepare-only | --dry-run]
#                             [--no-auto-rollback] [--yes]
#   scripts/migrate-legacy.sh --rollback [--yes]
#   scripts/migrate-legacy.sh --status
#
#   --legacy-dir DIR    the old compose checkout; its .env holds POSTGRES_PASSWORD and N8N_PORT
#   --public-url URL    the tunnel/NPM URL (sets N8N_EDITOR_BASE_URL, N8N_WEBHOOK_URL, ...).
#                       Without it the legacy WEBHOOK_URL is carried over as N8N_WEBHOOK_URL.
#   --bind ADDR         HOST_BIND of the new publish (default 127.0.0.1; compose used 0.0.0.0)
#   --suffix S          the legacy containers become <name>-legacy-S (default: today). Only
#                       used on the rename path; see "Rollback shape" below.
#   --prepare-only      steps 1-2 only, no downtime: checks, env file, secrets, images, hot backup
#   --dry-run           step 1 and a render of the units; changes nothing
#   --no-auto-rollback  leave a failed cutover in place for inspection
#   --rollback          undo the cutover: remove the Quadlet units, bring the legacy containers
#                       back, re-enable the legacy unit. Volumes are shared, so no data is lost.
#
# Rollback shape (STANDARD 7a): the legacy containers are kept for --rollback either by
# renaming them and leaving them stopped, or - where the user unit podman-restart.service is
# enabled and a legacy container's restart policy is exactly `always`, because a renamed copy
# would revive at the next boot and fight the new Quadlet container - by capturing them into
# the backup directory and removing them. ql_rollback_strategy decides from this host's real
# state, never from its name, and --dry-run reports which path a cutover would take. The
# capture is taken in step 2, before any downtime.
#
# Steps:  1 pre-flight checks        2 backup (hot pg_dump now, cold volume export after the stop)
#         3 disable the legacy unit (kept on disk) and retire the legacy containers
#         4 scripts/install.sh adopts n8n_n8n_data, n8n_postgres_data and n8n-network
#         5 tests/smoke.sh           6 --rollback when needed
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

LEGACY_CONTAINERS=(n8n-postgres n8n)
LEGACY_UNIT=${LEGACY_UNITS[0]}
STATE=$APP_STATE_DIR/migration.state

mode=migrate legacy_dir='' public_url='' bind=127.0.0.1 suffix=$(date +%Y%m%d) auto_rollback=1 ASSUME_YES=0
while (($#)); do
  case $1 in
    --legacy-dir) legacy_dir=${2:?--legacy-dir needs a directory}; shift ;;
    --public-url) public_url=${2:?--public-url needs a URL}; shift ;;
    --bind) bind=${2:?--bind needs an address}; shift ;;
    --suffix) suffix=${2:?--suffix needs a value}; shift ;;
    --prepare-only) mode=prepare ;;
    --dry-run) mode=dry-run ;;
    --no-auto-rollback) auto_rollback=0 ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,36p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_assert_match --suffix "$suffix" '[A-Za-z0-9._-]+'

# ---- small state file: what the cutover did, so --rollback needs no arguments ---------------
state_get() { if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -n1; fi; }
state_set() {
  mkdir -p "$APP_STATE_DIR"
  local tmp
  tmp=$(mktemp "$APP_STATE_DIR/.migration.XXXXXX")
  { if [[ -f $STATE ]]; then grep -v "^$1=" "$STATE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$STATE"
}

if [[ $mode == status ]]; then
  if [[ -f $STATE ]]; then cat "$STATE"; else echo "no migration recorded in $STATE"; fi
  exit 0
fi

ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
export WOOW_QL_LOCK_HELD=$APP

unit_exists() { [[ -n $(systemctl --user show -p FragmentPath --value "$1" 2>/dev/null) ]]; }

# =============================================================================================
# 6. rollback
# =============================================================================================
rollback() {
  local status sfx c port unit_state bk
  status=$(state_get STATUS) sfx=$(state_get SUFFIX) bk=$(state_get BACKUP)
  [[ $status == cutover || $status == "done" ]] || ql_die "nothing to roll back (migration status: ${status:-none})"
  app_confirm "--rollback removes the n8n Quadlet units and brings the legacy containers back"
  ql_info "stopping and removing the Quadlet units (volumes, network and secrets are kept)"
  ql_uninstall_units "$APP"
  rm -f -- "$APP_STATE_DIR/env.sha256"
  for c in "${LEGACY_CONTAINERS[@]}"; do
    if podman container exists "$c"; then
      [[ $(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c") == "$c.service" ]] \
        || ql_die "container $c exists and is not a Quadlet leftover; resolve it by hand"
      podman rm -f "$c" >/dev/null
    fi
  done
  # renamed back, or recreated from the capture the cutover took - whichever the host needed
  app_legacy_restore "$sfx" "$bk" "${LEGACY_CONTAINERS[@]}"
  unit_state=$(state_get LEGACY_UNIT_STATE)
  if unit_exists "$LEGACY_UNIT"; then
    if [[ $unit_state == enabled ]]; then systemctl --user enable "$LEGACY_UNIT" >/dev/null 2>&1; fi
    systemctl --user start "$LEGACY_UNIT"
  else
    podman start "${LEGACY_CONTAINERS[@]}" >/dev/null
  fi
  port=$(state_get LEGACY_PORT)
  ql_wait_http "http://127.0.0.1:${port:-15678}/healthz" 200 180 || ql_die "the legacy n8n did not answer after the rollback"
  state_set STATUS rolled-back
  ql_info "rolled back: the legacy stack runs again. Backup of the attempt: $(state_get BACKUP)"
  ql_info "if the data itself were damaged, restore the cold exports in that directory with"
  ql_info "  podman volume import (see README, 'Rollback'); this was not needed for a plain rollback"
}

if [[ $mode == rollback ]]; then
  rollback
  exit 0
fi

# =============================================================================================
# 1. pre-flight checks (read-only)
# =============================================================================================
[[ -n $legacy_dir ]] || ql_die "--legacy-dir is required (the old compose checkout with its .env)"
legacy_dir=$(cd -- "$legacy_dir" && pwd -P) || ql_die "no such directory: $legacy_dir"
LEGACY_ENV=$legacy_dir/.env
[[ -r $LEGACY_ENV ]] || ql_die "$LEGACY_ENV not found"
legacy_get() {
  local v
  v=$(sed -n "s/^$1=//p" "$LEGACY_ENV" | tail -n1 | tr -d '\r')
  v=${v#\"} v=${v%\"}
  printf '%s' "$v"
}
[[ -n $public_url ]] && { [[ $public_url =~ ^https?:// ]] || ql_die "--public-url must start with http:// or https://"; }

ql_info "step 1/5: pre-flight checks"
case $(state_get STATUS) in
  cutover | "done") ql_die "a cutover is already recorded in $STATE (use --status, or --rollback)" ;;
esac
if [[ $mode == dry-run ]]; then QL_DRY_RUN=1 ql_enable_linger; else ql_enable_linger; fi
for c in "${LEGACY_CONTAINERS[@]}"; do
  podman container exists "$c" || ql_die "legacy container $c not found"
  label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c")
  [[ $label != "$c.service" ]] || ql_die "$c is already managed by Quadlet ($label)"
  app_running "$c" || ql_die "legacy container $c is not running; start the legacy stack for the hot backup"
done
# How the legacy containers are kept for --rollback: renamed and left stopped, or captured
# and removed. Asked of this host, never of its name (STANDARD 7a, quadlet-lib >= 1.4.0).
STRATEGY=$(ql_rollback_strategy "${LEGACY_CONTAINERS[@]}")
if [[ $STRATEGY == rename ]]; then
  for c in "${LEGACY_CONTAINERS[@]}"; do
    if podman container exists "$c-legacy-$suffix"; then ql_die "$c-legacy-$suffix already exists; pick another --suffix"; fi
  done
fi
mounts_of() { podman inspect --format '{{range .Mounts}}{{.Name}}|{{.Destination}}{{println}}{{end}}' "$1"; }
grep -qx "$DATA_VOLUME|/home/node/.n8n" < <(mounts_of n8n) \
  || ql_die "n8n does not use the volume $DATA_VOLUME at /home/node/.n8n; this repo only adopts that name"
grep -qx "$DB_VOLUME|/var/lib/postgresql/data" < <(mounts_of n8n-postgres) \
  || ql_die "n8n-postgres does not use the volume $DB_VOLUME; this repo only adopts that name"
[[ $(legacy_get POSTGRES_USER) == "$DB_USER" && $(legacy_get POSTGRES_DB) == "$DB_NAME" ]] \
  || ql_die "the legacy .env must use POSTGRES_USER=$DB_USER and POSTGRES_DB=$DB_NAME (the units fix them)"
[[ -n $(legacy_get POSTGRES_PASSWORD) ]] || ql_die "POSTGRES_PASSWORD is empty in $LEGACY_ENV"
cur=$(app_running_version)
[[ $cur == "$N8N_VERSION" ]] \
  || ql_die "the legacy n8n runs '${cur:-?}' but this checkout pins $N8N_VERSION; migrate at the same version, then upgrade"
pg_cur=$(podman exec "$DB_CONTAINER" sh -c 'echo "$PG_MAJOR"')
pg_tgt=$(app_tag "$PG_IMAGE")
[[ $pg_cur == "${pg_tgt%%[.-]*}" ]] || ql_die "the legacy Postgres major is $pg_cur, the pin is $PG_IMAGE"
legacy_port=$(legacy_get N8N_PORT)
legacy_port=${legacy_port:-5678}
ql_assert_match "N8N_PORT in the legacy .env" "$legacy_port" '[0-9]{1,5}'
if app_is_installed && [[ $(state_get STATUS) != prepared ]]; then
  ql_die "the n8n Quadlet units are already installed; this host needs no migration"
fi
if unit_exists "$LEGACY_UNIT"; then
  ql_info "legacy unit $LEGACY_UNIT: $(systemctl --user is-enabled "$LEGACY_UNIT" 2>/dev/null || true)"
else
  ql_warn "no $LEGACY_UNIT on this host; the legacy containers will be stopped with podman stop"
fi
counts() {
  podman exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select 'workflows=' || (select count(*) from workflow_entity) || ' credentials=' || (select count(*) from credentials_entity) || ' users=' || (select count(*) from \"user\")" 2>/dev/null || echo '?'
}
pre_counts=$(counts)
ql_info "legacy n8n $cur, Postgres $pg_cur, port $legacy_port: $pre_counts"
[[ $pre_counts != *users=0* ]] || ql_warn "n8n has no owner yet: whoever opens the public URL first becomes the owner. Create it now"

# the env file this host will use (a scratch copy for --dry-run)
derive_env() {
  local f=$1 tz proto wh
  ql_env_set "$f" HOST_BIND "$bind"
  ql_env_set "$f" HOST_PORT "$legacy_port"
  tz=$(legacy_get GENERIC_TIMEZONE)
  if [[ -n $tz ]]; then ql_env_set "$f" GENERIC_TIMEZONE "$tz"; ql_env_set "$f" TZ "$tz"; fi
  if [[ -n $public_url ]]; then
    app_set_public_url "$public_url" "$f"
  else
    proto=$(legacy_get N8N_PROTOCOL) wh=$(legacy_get WEBHOOK_URL)
    [[ -z $proto ]] || ql_env_set "$f" N8N_PROTOCOL "$proto"
    [[ -z $wh ]] || ql_env_set "$f" N8N_WEBHOOK_URL "$wh"
  fi
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-migrate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if [[ $mode == dry-run ]]; then
  if [[ -f $ENV_FILE ]]; then cp -p -- "$ENV_FILE" "$WORK/n8n.env"; else install -m 600 -- "$ENV_EXAMPLE" "$WORK/n8n.env"; fi
  derive_env "$WORK/n8n.env"
  ql_env_load "$WORK/n8n.env"
  app_validate_env
  app_render "$WORK/render" "$WORK/n8n.env"
  if [[ $STRATEGY == capture ]]; then
    ql_info "dry-run: checks passed and the units render. The cutover would stop $LEGACY_UNIT, capture ${LEGACY_CONTAINERS[*]} into the backup directory and remove them (podman-restart.service would revive a renamed copy here), and install:"
  else
    ql_info "dry-run: checks passed and the units render. The cutover would stop $LEGACY_UNIT, rename ${LEGACY_CONTAINERS[*]} to *-legacy-$suffix and install:"
  fi
  sed 's/^/    /' < <(grep -vE '^[[:space:]]*(#|$)' "$WORK/n8n.env") >&2
  exit 0
fi

# =============================================================================================
# 2. prepare (no downtime): env file, secrets, images, hot backup
# =============================================================================================
ql_info "step 2/5: env file, secrets, images and a hot backup (no downtime)"
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
[[ $QL_ENV_CREATED != 1 ]] || ql_info "filling $ENV_FILE in from $LEGACY_ENV (review it after the cutover)"
derive_env "$ENV_FILE"
ql_env_load "$ENV_FILE"
app_validate_env
# shellcheck disable=SC2034 # read by ql_secret_ensure through env:LEGACY_DB_PASSWORD
LEGACY_DB_PASSWORD=$(legacy_get POSTGRES_PASSWORD)
ql_secret_ensure "$SECRET_DB" env:LEGACY_DB_PASSWORD --update
unset LEGACY_DB_PASSWORD
ql_secret_ensure "$SECRET_RUNNERS" random:64
app_render "$WORK/render" "$ENV_FILE"
ql_pull_images "$WORK/render/out"

bk=$(state_get BACKUP)
if [[ $(state_get STATUS) != prepared || ! -d $bk ]]; then
  bk=$(app_new_backup_dir "$BACKUP_ROOT/migrate-$(date +%Y%m%d-%H%M%S)")
fi
(umask 077 && cp -p -- "$LEGACY_ENV" "$bk/legacy.env")
if unit_exists "$LEGACY_UNIT"; then systemctl --user cat "$LEGACY_UNIT" >"$bk/$LEGACY_UNIT" 2>/dev/null || true; fi
podman inspect "${LEGACY_CONTAINERS[@]}" >"$bk/inspect.json"
app_dump_db "$bk/n8n-pg.dump"
app_dump_roles "$bk/roles.sql"
mkdir -p "$bk/secrets"
for s in "$SECRET_DB" "$SECRET_RUNNERS"; do app_save_secret "$s" "$bk/secrets/$s"; done
printf 'legacy n8n %s\n%s\n' "$cur" "$pre_counts" >"$bk/precheck.txt"
podman exec n8n test -s /home/node/.n8n/config && echo "encryption key present" >>"$bk/precheck.txt"
# On the capture path the rollback copy is written now, while the legacy stack still runs:
# a container whose create command cannot be replayed is then refused before any downtime.
if [[ $STRATEGY == capture ]]; then app_legacy_capture "$bk" "${LEGACY_CONTAINERS[@]}"; fi
app_write_checksums "$bk"
state_set STRATEGY "$STRATEGY"
state_set STATUS prepared
state_set BACKUP "$bk"
state_set SUFFIX "$suffix"
state_set LEGACY_PORT "$legacy_port"
ql_info "hot backup: $bk"
if [[ $mode == prepare ]]; then
  ql_info "prepared. Run the cutover (downtime 2-3 min) with the same options minus --prepare-only"
  exit 0
fi

# =============================================================================================
# 3. stop + cold backup + rename (downtime starts)
# =============================================================================================
app_confirm "the cutover stops n8n (about 2-3 minutes of downtime)"
ql_info "step 3/5: stopping the legacy stack, cold export, retiring the legacy containers ($STRATEGY)"
unit_state=$(systemctl --user is-enabled "$LEGACY_UNIT" 2>/dev/null || true)
state_set LEGACY_UNIT_STATE "${unit_state:-absent}"
state_set STATUS cutover
if unit_exists "$LEGACY_UNIT"; then
  systemctl --user disable "$LEGACY_UNIT" >/dev/null 2>&1 || true
  systemctl --user stop "$LEGACY_UNIT" || true
  ! systemctl --user is-active --quiet "$LEGACY_UNIT" || ql_die "$LEGACY_UNIT is still active"
  ql_info "disabled and stopped $LEGACY_UNIT (the unit file stays for --rollback)"
fi
for c in n8n "$DB_CONTAINER"; do
  if app_running "$c"; then podman stop -t 60 "$c" >/dev/null; fi
  ! app_running "$c" || ql_die "$c is still running"
done
ql_backup_volume "$DATA_VOLUME" "$bk" >/dev/null
ql_backup_volume "$DB_VOLUME" "$bk" >/dev/null
app_legacy_retire "$STRATEGY" "$suffix" "$bk" "${LEGACY_CONTAINERS[@]}"
app_write_checksums "$bk"

# =============================================================================================
# 4. install (adopts the volumes and the network by name)  5. smoke
# =============================================================================================
ql_info "step 4/5: scripts/install.sh"
failed=0
"$REPO/scripts/install.sh" --no-smoke || failed=1
if ((!failed)); then
  ql_info "step 5/5: tests/smoke.sh"
  "$REPO/tests/smoke.sh" --timeout 600 || failed=1
fi
if ((failed)); then
  if ((auto_rollback)); then
    ql_warn "the cutover failed; rolling back automatically (--no-auto-rollback keeps it for inspection)"
    ASSUME_YES=1 rollback
    ql_die "migration failed and was rolled back; the legacy stack runs again. Logs: journalctl --user -u n8n.service"
  fi
  ql_die "the cutover failed; the new units are left in place. Inspect, then run: $0 --rollback"
fi
if [[ -n $public_url ]]; then
  "$REPO/tests/smoke.sh" --timeout 120 --public-url "$public_url" \
    || ql_warn "the local checks pass but ${public_url%/}/healthz does not; check the tunnel route (not rolled back)"
fi
post_counts=$(counts)
ql_info "before: $pre_counts"
ql_info "after:  $post_counts"
[[ $post_counts == "$pre_counts" ]] || ql_warn "the counts differ; compare with $bk/precheck.txt"
state_set STATUS "done"
if [[ $STRATEGY == capture ]]; then
  ql_info "migration complete. The legacy containers were captured into $bk/legacy-container and removed (podman-restart.service is enabled here, so a renamed copy would have revived at boot); $LEGACY_UNIT is disabled. Roll back with:"
else
  ql_info "migration complete. Legacy containers *-legacy-$suffix and $LEGACY_UNIT (disabled) are kept for rollback:"
fi
ql_info "  $0 --rollback"
ql_info "after the soak period, clean up as described in README ('After the soak')"
