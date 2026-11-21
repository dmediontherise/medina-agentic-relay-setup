#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
L="$RELAY_HOME/lanes.sh"
fresh() { local w; w="$(t_repo)"; cp "$here/fixtures/odd/tasks/demo.md" "$w/odd/tasks/demo.md"
          git -C "$w" add -A; git -C "$w" commit -qm doc; printf '%s' "$w"; }
mark() { local r; r="$(grep -E "^- \[.\] $2 " "$1/odd/tasks/demo.md")"; printf '%s' "${r:3:1}"; }

# 1. happy path: T1+T2 parallel low-risk writes, T3 high-risk inline + verify
ws="$(fresh)"
rc=0; STUB_SLEEP=1 bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || rc=$?
t_eq "drained exit 0" "$rc" "0"
t_eq "T1 done" "$(mark "$ws" T1)" "x"; t_eq "T2 done" "$(mark "$ws" T2)" "x"; t_eq "T3 done" "$(mark "$ws" T3)" "x"
t_eq "3 task commits + doc commit" "$(git -C "$ws" rev-list --count HEAD)" "6"
t_has "T1 commit recorded" "$(grep -E '^- \[x\] T1 ' "$ws/odd/tasks/demo.md")" "commit: $(git -C "$ws" log --format=%h --grep 'T1' -1)"
t_true "tree clean after run" '[ -z "$(git -C "$ws" status --porcelain)" ]'
t_has "log says drained" "$(cat "$ws/odd/tasks/demo.md")" "autopilot: queue drained"
s1="$(grep 'agy write T1 start' "$STUB_STATE/calls.log" | awk '{print $5}')"
e2="$(grep 'agy write T2 end' "$STUB_STATE/calls.log" | awk '{print $5}')"
s2="$(grep 'agy write T2 start' "$STUB_STATE/calls.log" | awk '{print $5}')"
e1="$(grep 'agy write T1 end' "$STUB_STATE/calls.log" | awk '{print $5}')"
t_true "T1 and T2 overlapped (parallel)" '[ "$s1" -lt "$e2" ] && [ "$s2" -lt "$e1" ]'
t_true "T3 inline went to claude" 'grep -q "claude inline T3" "$STUB_STATE/calls.log"'

# 2. FAIL then PASS: follow-up row, root closed by follow-up's commit
: > "$STUB_STATE/calls.log"; rm -f "$STUB_STATE/vcount"
ws="$(fresh)"
STUB_VERDICTS="FAIL PASS" bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || true
t_eq "T3 closed" "$(mark "$ws" T3)" "x"
t_eq "T3.f1 closed" "$(mark "$ws" T3.f1)" "x"

# 3. FAIL twice: blocked, needs a decision, exit 4
rm -f "$STUB_STATE/vcount"
ws="$(fresh)"
rc=0; STUB_VERDICTS="FAIL FAIL" bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || rc=$?
t_eq "T3 blocked" "$(mark "$ws" T3)" "!"
t_eq "T3.f1 blocked" "$(mark "$ws" T3.f1)" "!"
t_has "needs decision logged" "$(cat "$ws/odd/tasks/demo.md")" "Needs your decision: T3.f1 failed twice"
t_eq "T1 still done" "$(mark "$ws" T1)" "x"

# 4. Claude limit: inline row blocked, independent write rows still run
rm -f "$STUB_STATE/vcount"
ws="$(fresh)"
STUB_inline=limit bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || true
t_eq "T3 blocked on limit" "$(mark "$ws" T3)" "!"
t_has "limit logged" "$(cat "$ws/odd/tasks/demo.md")" "Needs your decision: Claude limit"
t_eq "T2 done anyway" "$(mark "$ws" T2)" "x"

# 5. dirty tree refused; STOP honoured
ws="$(fresh)"; printf 'x\n' >> "$ws/README.md"
out="$(bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md 2>&1 || true)"
t_has "dirty tree refused" "$out" "clean tree"
ws="$(fresh)"; mkdir -p "$ws/.relay"; touch "$ws/.relay/STOP"
bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || true
t_eq "STOP: nothing ran" "$(mark "$ws" T1)" " "
t_done
