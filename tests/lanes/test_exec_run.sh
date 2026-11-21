#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
. "$RELAY_HOME/lanes/lib.sh"; . "$RELAY_HOME/lanes/exec.sh"
ws="$(t_repo)"; run="$ws/.relay/runs/x"; mkdir -p "$run"
P() { printf 'RELAY LANE DISPATCH\nROLE: %s\nTASK: T1\nOUTPUT: %s\n' "$1" "$2"; }

st="$(lane_exec "$run" s1 explore "$ws" "$(P explore "$run/map.md")" "$run/map.md")"
t_eq   "ok run"              "$st" "ok"
t_file "output written"      "$run/map.md"
t_has  "step json"           "$(cat "$run/s1.json")" '"status": "ok"'
t_has  "agy used"            "$(cat "$STUB_STATE/calls.log")" "agy explore T1 start"

: > "$STUB_STATE/calls.log"
st="$(STUB_explore=quota lane_exec "$run" s2 explore "$ws" "$(P explore "$run/m2.md")" "$run/m2.md")"
t_eq  "quota falls back"     "$st" "ok"
t_has "opencode took over"   "$(cat "$STUB_STATE/calls.log")" "opencode explore T1 end"
t_has "json records route"   "$(cat "$run/s2.json")" 'agy:failed opencode:ok'

: > "$STUB_STATE/calls.log"
lane_exec "$run" s3 explore "$ws" "$(P explore "$run/m3.md")" "$run/m3.md" >/dev/null
t_hasnt "cooldown skips agy" "$(cat "$STUB_STATE/calls.log")" "agy explore"
rm -f "$RELAY_LANES_STATE/agy-quota-at"

: > "$STUB_STATE/calls.log"
st="$(STUB_explore=nooutput lane_exec "$run" s4 explore "$ws" "$(P explore "$run/m4.md")" "$run/m4.md")"
t_eq "no output -> failed after retry" "$st" "failed"
t_eq "exactly two attempts" "$(grep -c 'explore T1 start' "$STUB_STATE/calls.log")" "2"
t_has "both tries recorded" "$(cat "$run/s4.json")" 'agy:failed agy:failed'

st="$(STUB_explore=hang RELAY_LANE_TIMEOUT=2 lane_exec "$run" s5 explore "$ws" "$(P explore "$run/m5.md")" "$run/m5.md")"
t_eq "hang -> stalled" "$st" "stalled"

st="$(STUB_validator=limit lane_exec "$run" s6 validator "$ws" "$(P validator "$run/v.md")" "$run/v.md")"
t_eq "claude limit, no fallback" "$st" "limit"
t_done
