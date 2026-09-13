#!/usr/bin/env bash
# scripts/install.sh: install or update n8n as rootless Quadlet units (podman 4.9.3,
# systemd --user, linger). Idempotent: a re-run with nothing changed restarts nothing.
#
#   scripts/install.sh [--public-url URL] [--no-runners] [--db-password-file F]
#                      [--no-start] [--no-smoke] [--smoke-timeout S] [--dry-run]
#
#   --public-url URL       write N8N_HOST, N8N_PROTOCOL, N8N_EDITOR_BASE_URL, N8N_WEBHOOK_URL
#                          and N8N_PROXY_HOPS=1 into ~/.config/n8n/n8n.env (tunnel / NPM)
#   --no-runners           N8N_RUNNERS_MODE=internal: no task-runner sidecar (an installed
#                          one is removed). Set N8N_RUNNERS_MODE=external to add it back.
#   --db-password-file F   first install only: take the DB password from F instead of
#                          generating one (an existing secret is never replaced)
#   --no-start             install the files and daemon-reload only
#   --no-smoke             skip tests/smoke.sh at the end
#   --smoke-timeout S      seconds tests/smoke.sh waits for health (default 300)
#   --dry-run              render and validate, report what would change; change nothing
#
# The first run creates ~/.config/n8n/n8n.env from config/n8n.env.example and stops so you
# can review it. A host that runs the old podman-compose stack uses migrate-legacy.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

public_url='' no_runners=0 db_pw_file='' no_start=0 no_smoke=0 smoke_timeout=300
while (($#)); do
  case $1 in
    --public-url) public_url=${2:?--public-url needs a URL}; shift ;;
    --no-runners) no_runners=1 ;;
    --db-password-file) db_pw_file=${2:?--db-password-file needs a file}; shift ;;
    --no-start) no_start=1 ;;
    --no-smoke) no_smoke=1 ;;
    --smoke-timeout) smoke_timeout=${2:?--smoke-timeout needs seconds}; shift ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ----------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
ql_lock "$APP"

# ---- 2. per-host settings (D2: values come from the env file, never from the repo) ---------
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
render_env=$ENV_FILE
if [[ ! -f $ENV_FILE ]]; then
  render_env=$ENV_EXAMPLE # --dry-run on a fresh host: render the defaults
else
  [[ -z $public_url ]] || app_set_public_url "$public_url"
  ((!no_runners)) || ql_env_set "$ENV_FILE" N8N_RUNNERS_MODE internal
  if [[ $QL_ENV_CREATED == 1 ]]; then
    ql_info "review $ENV_FILE, then run $0 again"
    exit 0
  fi
fi
ql_env_load "$render_env"
app_validate_env

# ---- 3. legacy guards (Quadlet's `podman run --replace` would delete a same-named container)
for u in "${LEGACY_UNITS[@]}"; do
  if systemctl --user is-active --quiet "$u" 2>/dev/null; then
    ql_die "legacy unit $u is running; migrate this host with scripts/migrate-legacy.sh"
  fi
done
mapfile -t containers < <(app_containers)
for c in "${containers[@]}"; do ql_check_container_collision "${c%%:*}" "${c#*:}"; done

# ---- 4. stage, render, validate -----------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
ql_cleanup work rm -rf "$WORK"
app_render "$WORK" "$render_env"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# ---- 5. images and secrets before any unit changes (a pull never runs inside a start timeout)
ql_pull_images "$WORK/out"
if [[ -n $db_pw_file ]]; then
  [[ -r $db_pw_file ]] || ql_die "cannot read $db_pw_file"
  # shellcheck disable=SC2034 # read by ql_secret_ensure through env:DB_PASSWORD_FROM_FILE
  DB_PASSWORD_FROM_FILE=$(<"$db_pw_file")
  ql_secret_ensure "$SECRET_DB" env:DB_PASSWORD_FROM_FILE
  unset DB_PASSWORD_FROM_FILE
else
  ql_secret_ensure "$SECRET_DB" random:32
fi
ql_secret_ensure "$SECRET_RUNNERS" random:64

# ---- 6. install changed files, then start / restart only what changed ---------------------
if ! app_runners_enabled && app_installed_file n8n-runners.container; then
  ql_info "N8N_RUNNERS_MODE=internal: removing the task-runner sidecar"
  ql_remove_files "$APP" n8n-runners.container
fi
changed=$(ql_install_files "$WORK/out" "$APP")
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
[[ $render_env != "$ENV_FILE" ]] || app_env_mark_if_changed
if [[ $dry == 1 ]]; then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
mapfile -t units < <(app_units)
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start $TARGET"
  exit 0
fi
ql_apply_units "$APP" "${units[@]}"
app_env_record

# ---- 7. smoke ------------------------------------------------------------------------------
if ((no_smoke)); then
  ql_info "$APP is installed and started (smoke test skipped)"
  exit 0
fi
"$REPO/tests/smoke.sh" --timeout "$smoke_timeout" || ql_die "smoke test failed; see: journalctl --user -u n8n.service -n 100"
ql_info "$APP is installed and healthy at $(app_base_url)/"
