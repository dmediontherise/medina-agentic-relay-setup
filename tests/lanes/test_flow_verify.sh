#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
L="$RELAY_HOME/lanes.sh"
ws="$(t_repo)"; cp "$here/fixtures/odd/tasks/demo.md" "$ws/odd/tasks/demo.md"
git -C "$ws" add -A; git -C "$ws" commit -qm doc
mkdir -p "$ws/src/c"; printf 'c\n' > "$ws/src/c/data.txt"     # the candidate

out="$(bash "$L" verify -w "$ws" --doc odd/tasks/demo.md --task T3)"
t_has "verify PASS" "$out" "LANE verify PASS"
run="${out##* }"
calls="$(cat "$STUB_STATE/calls.log")"
order="$(grep -oE '(prebrief|evidence|validator) T3 start' "$STUB_STATE/calls.log" | awk '{print $1}' | tr '\n' ' ')"
t_eq  "chain order" "$order" "prebrief evidence validator "
pb_cwd="$(grep 'prebrief T3 start' "$STUB_STATE/calls.log" | sed 's/.*cwd=//')"
t_hasnt "prebrief ran outside the repo" "$pb_cwd" "$ws"
t_has   "validator is claude" "$calls" "claude validator T3"
t_has   "diff captured" "$(cat "$run/diff.patch")" "src/c/data.txt"
t_file  "prebrief copied into verify run" "$run/prebrief.md"
t_has   "validator prompt names evidence" "$(cat "$run"/validator-1.sh)" "EVIDENCE: $run/evidence.md"

rm -f "$STUB_STATE/vcount"
out="$(STUB_VERDICTS="FAIL" bash "$L" verify -w "$ws" --doc odd/tasks/demo.md --task T3)"
t_has "verify FAIL" "$out" "LANE verify FAIL"

out="$(STUB_evidence=nooutput bash "$L" verify -w "$ws" --doc odd/tasks/demo.md --task T3)"
t_has "no evidence is not a pass" "$out" "LANE verify no-evidence"

rm -f "$STUB_STATE/vcount"
out="$(bash "$L" verify -w "$ws" --doc odd/tasks/demo.md --task T3 --mutate)"
sleep 2
t_true "mutation lane ran in background" 'grep -q "mutate T3" "$STUB_STATE/calls.log"'
t_done
