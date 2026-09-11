# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # REPO, base, optional and failures belong to tests/dryrun.sh
# tests/dryrun.local.sh: n8n-specific checks, sourced at the end of tests/dryrun.sh.
#   1. n8nio/n8n and n8nio/runners carry the same version (an upstream requirement).
#   2. The toypark1234 fixture also renders with the optional runner sidecar, which is
#      what that host installs (N8N_RUNNERS_MODE=external).

v_n8n=$(sed -n 's#^Image=docker.io/n8nio/n8n:##p' "$REPO/quadlet/n8n.container")
v_run=$(sed -n 's#^Image=docker.io/n8nio/runners:##p' "$REPO/quadlet/optional/n8n-runners.container")
if [[ -n $v_n8n && $v_n8n == "$v_run" ]]; then
  echo "ok   version lockstep: n8nio/n8n $v_n8n = n8nio/runners $v_run"
else
  echo "FAIL version lockstep: n8nio/n8n ($v_n8n) != n8nio/runners ($v_run)"
  failures=$((failures + 1))
fi

run_variant fixture-toypark1234+optional "$REPO/tests/fixtures/toypark1234.env" "${base[@]}" "${optional[@]}"
