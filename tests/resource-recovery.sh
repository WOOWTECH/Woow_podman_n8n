#!/usr/bin/env bash
# A Podman system reset removes the network and volumes while systemd's oneshot
# Quadlet units can remain active. Install must recreate the missing resources.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"

declare -A present=(
  [n8n-network]=0
  [n8n_n8n_data]=0
  [n8n_postgres_data]=0
)
declare -a restarted=()
podman() {
  case "$1 $2 $3" in
    'network exists n8n-network') [[ ${present[n8n-network]} == 1 ]] ;;
    'volume exists n8n_n8n_data') [[ ${present[n8n_n8n_data]} == 1 ]] ;;
    'volume exists n8n_postgres_data') [[ ${present[n8n_postgres_data]} == 1 ]] ;;
    *) printf 'unexpected podman call: %s\n' "$*" >&2; return 2 ;;
  esac
}
systemctl() {
  [[ $1 == --user ]] || return 2
  shift
  case "$1" in
    is-active) [[ $2 == --quiet ]] || return 2; return 0 ;;
    restart)
      restarted+=("$2")
      case "$2" in
        n8n-network.service) present[n8n-network]=1 ;;
        n8n-data-volume.service) present[n8n_n8n_data]=1 ;;
        n8n-postgres-data-volume.service) present[n8n_postgres_data]=1 ;;
        *) return 2 ;;
      esac
      ;;
    *) printf 'unexpected systemctl call: %s\n' "$*" >&2; return 2 ;;
  esac
}

app_reconcile_resources
[[ ${present[n8n-network]} == 1 && ${present[n8n_n8n_data]} == 1 && ${present[n8n_postgres_data]} == 1 ]]
[[ ${#restarted[@]} == 3 ]]
app_reconcile_resources
[[ ${#restarted[@]} == 3 ]]
echo 'ok   stale active Quadlet resources are recreated once'
