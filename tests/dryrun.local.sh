# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2154,SC2034 # REPO, base, optional and failures belong to tests/dryrun.sh
# tests/dryrun.local.sh: n8n-specific checks, sourced at the end of tests/dryrun.sh.
#   1. n8nio/n8n and n8nio/runners carry the same version (an upstream requirement).
#   2. The toypark1234 fixture also renders with the optional runner sidecar, which is
#      what that host installs (N8N_RUNNERS_MODE=external).

v_n8n=$(sed -n 's#^Image=docker.io/n8nio/n8n:##p' "$REPO/quadlet/n8n.container")
v_run=$(sed -n 's#^Image=docker.io/n8nio/runners:##p' "$REPO/quadlet/optional/n8n-runners.container")
v_worker=$(sed -n 's#^Image=docker.io/n8nio/n8n:##p' "$REPO/quadlet/queue/n8n-worker.container")
v_webhook=$(sed -n 's#^Image=docker.io/n8nio/n8n:##p' "$REPO/quadlet/queue/n8n-webhook.container")
v_worker_run=$(sed -n 's#^Image=docker.io/n8nio/runners:##p' "$REPO/quadlet/queue/n8n-worker-runners.container")
if [[ -n $v_n8n && $v_n8n == "$v_run" && $v_n8n == "$v_worker" && $v_n8n == "$v_webhook" && $v_n8n == "$v_worker_run" ]]; then
  echo "ok   version lockstep: main, worker, webhook and both runners at $v_n8n"
else
  echo "FAIL version lockstep: main=$v_n8n worker=$v_worker webhook=$v_webhook runners=$v_run worker-runners=$v_worker_run"
  failures=$((failures + 1))
fi

run_variant fixture-toypark1234+optional "$REPO/tests/fixtures/toypark1234.env" "${base[@]}" "${optional[@]}"

# Exercise the installer's conditional staging as well as Quadlet's generated units.
# The regular variants above never include the queue fragment or optional services.
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"
run_queue_variant() {
  local name=$1 webhook=$2 disable_main=$3
  local env=$WORK/$name/n8n.env out=$WORK/$name/out
  mkdir -p "$WORK/$name"
  cp -p "$REPO/config/n8n.env.example" "$env"
  if [[ $name == queue-true-disable-main-false ]]; then
    sed -i '/^WEBHOOK_PORT=/d' "$env" # older installations do not receive new defaults
  fi
  ql_env_set "$env" EXECUTIONS_MODE queue
  ql_env_set "$env" N8N_QUEUE_WEBHOOK_PROCESSOR "$webhook"
  ql_env_set "$env" N8N_QUEUE_DISABLE_MAIN_WEBHOOKS "$disable_main"
  if [[ $disable_main == true ]]; then ql_env_set "$env" WORKER_CONCURRENCY 7; fi
  ql_env_load "$env"
  app_validate_env
  app_render "$WORK/$name" "$env"
  ql_lint_policy "$out"
}
for setting in false:false true:false true:true; do
  webhook=${setting%%:*} disable_main=${setting#*:}
  name=queue-$webhook-disable-main-$disable_main
  variants=$((variants + 1))
  out=$WORK/$name/out
  if (run_queue_variant "$name" "$webhook" "$disable_main") \
    && grep -qx 'Environment=EXECUTIONS_MODE=queue' "$out/n8n.container" \
    && grep -qx 'Environment=N8N_DEFAULT_BINARY_DATA_MODE=database' "$out/n8n-worker.container" \
    && grep -qx 'Environment=N8N_RUNNERS_TASK_BROKER_URI=http://n8n-worker:5679' "$out/n8n-worker-runners.container" \
    && { [[ $disable_main == false ]] || grep -qx 'Exec=worker --concurrency=7' "$out/n8n-worker.container"; } \
    && [[ -f $out/n8n-valkey.container && -f $out/config/start-valkey.sh ]] \
    && { [[ $webhook == true && -f $out/n8n-webhook.container ]] || [[ $webhook == false && ! -f $out/n8n-webhook.container ]]; } \
    && { [[ $name != queue-true-disable-main-false ]] || grep -qx 'PublishPort=127.0.0.1:15679:5678' "$out/n8n-webhook.container"; } \
    && { [[ $disable_main == true ]] && grep -qx 'Environment=N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true' "$out/n8n.container" || [[ $disable_main == false ]]; }; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    failures=$((failures + 1))
  fi
done
"$REPO/tests/config-snapshot.sh"
"$REPO/tests/resource-recovery.sh"
