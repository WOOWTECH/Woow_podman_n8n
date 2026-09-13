#!/usr/bin/env bash
# tests/smoke.sh: post-install health checks for the n8n stack. Read-only; exit 0 = healthy.
#
#   tests/smoke.sh [--timeout S] [--public-url URL]
#
#   --timeout S       seconds to wait for the healthchecks and HTTP (default 300; upgrades
#                     run DB migrations on the first start, so upgrade.sh passes 900)
#   --public-url URL  also GET <URL>/healthz through the tunnel / proxy
#
# Checks: units active; podman healthchecks; /healthz and /healthz/readiness; the running
# versions equal the installed units (n8n, runners); no "Python 3 is missing" or WEBHOOK_URL
# deprecation in the log; the encryption key exists; the port listens only on HOST_BIND.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"
export QL_LOG_PREFIX=smoke QL_HEALTH_ACTIVE=1

timeout=300 public_url=''
while (($#)); do
  case $1 in
    --timeout) timeout=${2:?--timeout needs seconds}; shift ;;
    --public-url) public_url=${2:?--public-url needs a URL}; shift ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_env_load "$ENV_FILE"

fails=0
ok() { ql_info "ok   $*"; }
bad() { ql_warn "FAIL $*"; fails=$((fails + 1)); }
check() {
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

# 1. units
mapfile -t units < <(app_units)
for u in "${units[@]}"; do check "$u is active" systemctl --user is-active --quiet "$u"; done

# 2. podman healthchecks
mapfile -t containers < <(app_containers)
for c in "${containers[@]}"; do check "${c%%:*} is healthy" ql_wait_container_healthy "${c%%:*}" "$timeout"; done

# 3. HTTP on the published port
base=$(app_base_url)
check "GET $base/healthz" ql_wait_http "$base/healthz" 200 "$timeout"
check "GET $base/healthz/readiness (DB connected and migrated)" ql_wait_http "$base/healthz/readiness" 200 "$timeout"

# 4. the running versions equal the installed units (the repo pins after an install/upgrade)
want=$(app_tag "$(app_installed_image n8n.container)")
v=$(app_running_version)
if [[ $v == "$want" ]]; then ok "n8n version $v = installed unit"; else bad "n8n version '${v:-?}' != installed unit $want"; fi
if app_runners_enabled; then
  want=$(app_installed_image n8n-runners.container)
  img=$(podman inspect --format '{{.ImageName}}' n8n-runners 2>/dev/null || true)
  if [[ $img == "$want" ]]; then ok "n8n-runners image $img = installed unit"; else bad "n8n-runners image '${img:-?}' != installed unit $want"; fi
fi

# 5. the log of this container instance (Quadlet recreates it on every start)
log=$(podman logs n8n 2>&1 || true)
if app_runners_enabled; then
  if grep -q 'Python 3 is missing' <<<"$log"; then bad "n8n still starts internal runners (Python 3 is missing)"; else ok "no internal-runner warning"; fi
  if grep -q 'Registered runner' <<<"$log"; then
    ok "a task runner registered with the broker"
  else
    ql_info "note: no runner registration logged yet (the launcher starts runners on the first Code-node task)"
  fi
fi
if grep -q 'WEBHOOK_URL ->' <<<"$log"; then bad "deprecated WEBHOOK_URL is still set (use N8N_WEBHOOK_URL)"; else ok "no WEBHOOK_URL deprecation"; fi

# 6. the credentials encryption key lives in the n8n_n8n_data volume
check "encryption key present in /home/node/.n8n/config" podman exec n8n test -s /home/node/.n8n/config

# 7. the published port listens only where HOST_BIND says
port=$(ql_env_get HOST_PORT) bind=$(ql_env_get HOST_BIND)
expected_listener() {
  case $1 in
    "$bind:$port") return 0 ;;
    "0.0.0.0:$port" | "*:$port") [[ $bind == 0.0.0.0 ]] ;;
    *) return 1 ;;
  esac
}
if command -v ss >/dev/null 2>&1; then
  mapfile -t listeners < <(ss -ltnH "sport = :$port" | awk '{print $4}' | sort -u)
  unexpected=0
  for l in "${listeners[@]}"; do expected_listener "$l" || unexpected=1; done
  if ((${#listeners[@]} && !unexpected)); then
    ok "port $port listens on ${listeners[*]}"
  else
    bad "port $port listeners '${listeners[*]}' do not match HOST_BIND=$bind"
  fi
else
  ql_info "note: ss not found; listener check skipped"
fi

# 8. through the tunnel / proxy
if [[ -n $public_url ]]; then
  check "GET ${public_url%/}/healthz" ql_wait_http "${public_url%/}/healthz" 200 120
fi

if ((fails)); then
  ql_warn "$fails check(s) failed"
  exit 1
fi
ql_info "all checks passed"
