#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
L="$RELAY_HOME/lanes.sh"
out="$(bash "$L" doctor 2>&1)"
t_has "doctor lists agy"       "$out" "agy"
t_has "doctor lists gentle-ai" "$out" "gentle-ai"
t_has "doctor lists engram"    "$out" "engram"
t_has "doctor reports quota"   "$out" "agy quota"
ws="$(t_repo)"; cp "$here/fixtures/odd/tasks/demo.md" "$ws/odd/tasks/demo.md"
bash "$L" explore -w "$ws" --doc odd/tasks/demo.md --task T1 >/dev/null
t_has "status shows last step" "$(bash "$L" status -w "$ws" 2>&1)" '"status": "ok"'
bash "$L" down
t_true "down kills session" '! tmux has-session -t "$RELAY_LANES_SESSION" 2>/dev/null'
t_done
