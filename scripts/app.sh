# shellcheck shell=bash
# shellcheck disable=SC2034 # these settings are read by the scripts that source this file
# scripts/app.sh: n8n settings and helpers shared by scripts/*.sh and tests/smoke.sh.
# Sourced after scripts/lib/quadlet-lib.sh (the vendored lib, never edited here).
# The caller sets REPO to the repository root before sourcing this file.

# ---- names -----------------------------------------------------------------------------
APP=n8n
export QL_APP=$APP
ENV_FILE=$HOME/.config/$APP/$APP.env
ENV_EXAMPLE=$REPO/config/$APP.env.example
PODMAN_MIN=4.9.3
TARGET=n8n.target
# Hand-written units of the podman-compose era; they must not run next to the Quadlet units.
LEGACY_UNITS=(podman-n8n.service)
BACKUP_ROOT=$HOME/backups/$APP
APP_STATE_DIR=${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}/$APP
QDIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
DB_CONTAINER=n8n-postgres
DB_USER=n8n
DB_NAME=n8n
DATA_VOLUME=n8n_n8n_data
DB_VOLUME=n8n_postgres_data
SECRET_DB=n8n-db-password
SECRET_RUNNERS=n8n-runners-auth-token
# Units whose container reads ~/.config/n8n/n8n.env (restarted when the file changes).
ENV_READERS=(n8n.service)

# ---- pins (the repo is the source of truth for every version) ---------------------------
# app_pin <file under quadlet/>: the Image= of that unit
app_pin() { sed -n 's/^Image=//p' "$REPO/quadlet/$1" | tail -n1; }
# app_tag <image>: its tag (text after the last ':' of the last path element)
app_tag() {
  local last=${1##*/}
  last=${last%%@*}
  [[ $last == *:* ]] && printf '%s' "${last##*:}"
  return 0
}
# app_installed_image <unit file>: the Image= systemd runs (falls back to the repo pin when
# the unit is not installed). Smoke tests compare against this, so a rolled-back stack passes.
app_installed_image() {
  local f=$QDIR/${1##*/} i=''
  [[ -f $f ]] && i=$(sed -n 's/^Image=//p' "$f" | tail -n1)
  if [[ -n $i ]]; then printf '%s' "$i"; else app_pin "$1"; fi
}
N8N_IMAGE=$(app_pin n8n.container)
RUNNERS_IMAGE=$(app_pin optional/n8n-runners.container)
PG_IMAGE=$(app_pin n8n-postgres.container)
N8N_VERSION=$(app_tag "$N8N_IMAGE")

# ---- per-host settings --------------------------------------------------------------------
app_runners_enabled() { [[ $(ql_env_get N8N_RUNNERS_MODE external) == external ]]; }

# app_units: every unit this host runs, the target first
app_units() {
  printf '%s\n' "$TARGET" n8n-postgres.service n8n.service
  if app_runners_enabled; then printf '%s\n' n8n-runners.service; fi
}

# app_containers: name:unit of every container this host runs
app_containers() {
  printf '%s\n' n8n-postgres:n8n-postgres.service n8n:n8n.service
  if app_runners_enabled; then printf '%s\n' n8n-runners:n8n-runners.service; fi
}

# app_validate_env: dies on a value the units or n8n cannot work with (QL_ENV is loaded)
app_validate_env() {
  local port p k
  ql_assert_match HOST_BIND "$(ql_env_get HOST_BIND)" '[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:.]+\]'
  port=$(ql_env_get HOST_PORT)
  ql_assert_match HOST_PORT "$port" '[0-9]{1,5}'
  ((10#$port >= 1 && 10#$port <= 65535)) || ql_die "HOST_PORT=$port is not a TCP port"
  ql_assert_match N8N_RUNNERS_MODE "$(ql_env_get N8N_RUNNERS_MODE external)" 'external|internal'
  p=$(ql_env_get N8N_PORT 5678)
  [[ $p == 5678 ]] || ql_die "N8N_PORT=$p in $ENV_FILE is n8n's port INSIDE the container and must stay 5678; the host port is HOST_PORT"
  for k in DB_TYPE DB_POSTGRESDB_HOST DB_POSTGRESDB_PORT DB_POSTGRESDB_DATABASE DB_POSTGRESDB_USER \
    DB_POSTGRESDB_PASSWORD N8N_RUNNERS_AUTH_TOKEN N8N_RUNNERS_BROKER_LISTEN_ADDRESS POSTGRES_PASSWORD; do
    [[ -z ${QL_ENV[$k]+x} ]] || ql_warn "$k in $ENV_FILE is ignored: n8n.container sets it (passwords are podman secrets)"
  done
  [[ -z ${QL_ENV[WEBHOOK_URL]+x} ]] || ql_warn "WEBHOOK_URL is deprecated since n8n 2.35; use N8N_WEBHOOK_URL (install.sh --public-url sets it)"
  return 0
}

# app_set_public_url <url> [envfile]: the five public-URL keys, for a tunnel or NPM in front
app_set_public_url() {
  local url=$1 f=${2:-$ENV_FILE} scheme host
  [[ $url =~ ^(https?)://([A-Za-z0-9.-]+)(:[0-9]+)?(/.*)?$ ]] || ql_die "--public-url: '$url' is not an http(s) URL"
  scheme=${BASH_REMATCH[1]} host=${BASH_REMATCH[2]}
  [[ $url == */ ]] || url=$url/
  ql_env_set "$f" N8N_HOST "$host"
  ql_env_set "$f" N8N_PROTOCOL "$scheme"
  ql_env_set "$f" N8N_EDITOR_BASE_URL "$url"
  ql_env_set "$f" N8N_WEBHOOK_URL "$url"
  ql_env_set "$f" N8N_PROXY_HOPS 1
  ql_info "public URL set to $url (N8N_HOST, N8N_PROTOCOL, N8N_EDITOR_BASE_URL, N8N_WEBHOOK_URL, N8N_PROXY_HOPS=1)"
}

# app_base_url: where this host reaches the published port
app_base_url() {
  local b
  b=$(ql_env_get HOST_BIND)
  case $b in 0.0.0.0) b=127.0.0.1 ;; '[::]') b='[::1]' ;; esac
  printf 'http://%s:%s' "$b" "$(ql_env_get HOST_PORT)"
}

# ---- render ---------------------------------------------------------------------------------
# app_render <workdir> <envfile>: stage the units this host installs, render them into
# <workdir>/out and run the generator dry-run. Dies on any problem; nothing is installed.
app_render() {
  local w=$1 env=$2
  mkdir -p "$w/src" "$w/out"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$REPO"/systemd/* "$w/src/"
  if app_runners_enabled; then cp -p "$REPO/quadlet/optional/n8n-runners.container" "$w/src/"; fi
  ql_render "$w/src" "$env" "$REPO/quadlet/render-vars" "$w/out"
  ql_dryrun "$w/out" --verify --ref-dir "$QDIR" || ql_die "the rendered units failed the dry-run; nothing was installed"
}

# ---- install state (quadlet-lib keeps a sha256sum-format manifest per app) -----------------
app_manifest() { printf '%s/manifest' "$APP_STATE_DIR"; }
app_is_installed() { [[ -s $(app_manifest) ]]; }
app_require_installed() { app_is_installed || ql_die "$APP is not installed on this host (run scripts/install.sh first)"; }
# app_installed_file <basename>: the unit file is in the manifest
app_installed_file() { app_is_installed && awk -v b="$1" '{ n = split($2, p, "/"); if (p[n] == b) f = 1 } END { exit !f }' "$(app_manifest)"; }

# app_snapshot_units <dir>: copy every installed unit file into <dir> (flat), so a later
# `ql_install_files <dir> $APP --prune` puts exactly this set back (upgrade rollback).
app_snapshot_units() {
  local dest=$1 sha path
  mkdir -p "$dest"
  while read -r sha path; do
    [[ -n $sha && -f $path ]] || continue
    cp -p -- "$path" "$dest/"
  done <"$(app_manifest)"
}

# The container reads the env file at start, so a changed file must restart it. The file is
# not rendered, so track its hash here and mark the readers pending when it changed.
app_env_hash() { sha256sum <"$ENV_FILE" | cut -d' ' -f1; }
app_env_mark_if_changed() {
  local f=$APP_STATE_DIR/env.sha256
  if [[ ! -f $f || $(<"$f") != "$(app_env_hash)" ]]; then ql_mark_changed "$APP" "${ENV_READERS[@]}"; fi
}
app_env_record() {
  [[ ${QL_DRY_RUN:-0} == 1 ]] && return 0
  mkdir -p "$APP_STATE_DIR" && app_env_hash >"$APP_STATE_DIR/env.sha256"
}

# ---- secrets, database ----------------------------------------------------------------------
# app_save_secret <name> <file>: the secret value into a 0600 file, without a trailing newline
app_save_secret() {
  local v
  v=$(podman secret inspect --showsecret --format '{{.SecretData}}' "$1") || ql_die "cannot read secret $1"
  (umask 077 && printf '%s' "$v" >"$2") || ql_die "cannot write $2"
}

# app_dump_db <file>: pg_dump -Fc of the n8n database (the DB container must run)
app_dump_db() {
  (umask 077 && podman exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc >"$1.partial") \
    || { rm -f -- "$1.partial"; ql_die "pg_dump of $DB_NAME failed"; }
  mv -f -- "$1.partial" "$1"
  ql_info "dumped database $DB_NAME -> $1 ($(du -h -- "$1" | cut -f1))"
}

# app_dump_roles <file>: the roles with their password hashes (pg_dump does not include them)
app_dump_roles() {
  (umask 077 && podman exec "$DB_CONTAINER" pg_dumpall -U "$DB_USER" --roles-only >"$1.partial") \
    || { rm -f -- "$1.partial"; ql_die "pg_dumpall --roles-only failed"; }
  mv -f -- "$1.partial" "$1"
}

# app_restore_db <dump>: drop and recreate the n8n database from a pg_dump -Fc file.
# Nothing may be connected to it (stop n8n.service first).
app_restore_db() {
  podman exec -i "$DB_CONTAINER" pg_restore -U "$DB_USER" -d postgres --clean --if-exists --create <"$1" \
    || ql_die "pg_restore of $1 failed"
  ql_info "restored database $DB_NAME from $1"
}

# app_restore_roles <roles.sql>: role attributes and password hashes from a backup.
# "role already exists" errors are expected and ignored.
app_restore_roles() {
  podman exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -q >/dev/null 2>&1 <"$1" || true
}

# app_volume_replace <volume> <tar>: empty the volume in place, then import the tar. In place
# (not rm + create) because a stopped *-legacy-* container may still reference the volume.
app_volume_replace() {
  local vol=$1 tar=$2 mp users
  users=$(podman ps --filter "volume=$vol" --format '{{.Names}}' 2>/dev/null || true)
  [[ -z $users ]] || ql_die "volume $vol is in use by running container(s): ${users//$'\n'/ }"
  podman volume exists "$vol" || podman volume create --label "io.woowtech.app=$APP" "$vol" >/dev/null \
    || ql_die "cannot create volume $vol"
  mp=$(podman volume inspect --format '{{.Mountpoint}}' "$vol") || ql_die "cannot inspect volume $vol"
  [[ $mp == /*/* ]] || ql_die "unexpected mountpoint '$mp' for volume $vol"
  podman unshare find "$mp" -mindepth 1 -delete || ql_die "cannot empty volume $vol"
  podman volume import "$vol" "$tar" || ql_die "podman volume import $vol failed"
  ql_info "volume $vol replaced from ${tar##*/}"
}

# app_write_checksums <dir>: SHA256SUMS over every file below <dir> (restore.sh verifies it)
app_write_checksums() {
  local list
  list=$(cd -- "$1" && find . -type f ! -name 'SHA256SUMS*' ! -name '*.sha256' -printf '%P\n' | LC_ALL=C sort) \
    || ql_die "cannot list $1"
  (cd -- "$1" && umask 077 && while IFS= read -r f; do if [[ -n $f ]]; then sha256sum -- "$f"; fi; done <<<"$list" >SHA256SUMS.tmp \
    && mv -f SHA256SUMS.tmp SHA256SUMS) || ql_die "cannot write $1/SHA256SUMS"
}

# app_new_backup_dir [dir]: a fresh private directory (default ~/backups/n8n/<timestamp>)
app_new_backup_dir() {
  local d=${1:-$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)}
  [[ ! -e $d ]] || ql_die "$d already exists"
  (umask 077 && mkdir -p -- "$d") || ql_die "cannot create $d"
  printf '%s' "$d"
}

# app_running <container>: the container exists and runs
app_running() { [[ $(podman inspect --format '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }

# app_running_version: the n8n version inside the running container ("" when it does not run)
app_running_version() {
  if app_running n8n; then podman exec n8n n8n --version 2>/dev/null | tr -d '\r' | tail -n1; fi
  return 0
}

# app_confirm <what>: interactive "type the app name" confirmation unless --yes was given
app_confirm() {
  [[ ${ASSUME_YES:-0} == 1 || ${QL_DRY_RUN:-0} == 1 ]] && return 0
  [[ -t 0 ]] || ql_die "$1; add --yes to confirm non-interactively"
  local answer
  read -r -p "$1. Type '$APP' to continue: " answer
  [[ $answer == "$APP" ]] || ql_die "aborted; nothing was changed"
}
