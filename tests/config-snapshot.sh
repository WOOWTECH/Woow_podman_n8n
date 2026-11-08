#!/usr/bin/env bash
# The upgrade rollback must preserve runner config under units/config/, where
# ql_install_files routes it back to ~/.config/n8n/ instead of a Quadlet dir.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/n8n-snapshot.XXXXXX")
trap 'rm -r -- "$test_root"' EXIT
export QL_CONFIG_ROOT="$test_root/config" QL_STATE_ROOT="$test_root/state" \
  QL_QUADLET_DIR="$test_root/quadlet"
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"

python3 -m json.tool "$REPO/config/n8n-task-runners.json" >/dev/null
mkdir -p "$QL_CONFIG_ROOT/n8n" "$QL_STATE_ROOT/n8n" "$QL_QUADLET_DIR"
cp "$REPO/config/n8n-task-runners.json" "$QL_CONFIG_ROOT/n8n/"
cp "$REPO/quadlet/n8n.container" "$QL_QUADLET_DIR/"
for path in "$QL_CONFIG_ROOT/n8n/n8n-task-runners.json" "$QL_QUADLET_DIR/n8n.container"; do
  printf '%s  %s\n' "$(sha256sum "$path" | cut -d' ' -f1)" "$path" >>"$(app_manifest)"
done
app_snapshot_units "$test_root/snapshot/units"
cmp "$REPO/config/n8n-task-runners.json" "$test_root/snapshot/units/config/n8n-task-runners.json"
cmp "$REPO/quadlet/n8n.container" "$test_root/snapshot/units/n8n.container"
test ! -e "$test_root/snapshot/units/n8n-task-runners.json"
echo 'ok   runner config and Quadlet unit are restorable from the snapshot'
