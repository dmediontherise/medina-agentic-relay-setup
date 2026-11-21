#!/usr/bin/env bash
# Stand-in for agy / opencode / claude in the lanes tests. Finds the dispatch argument
# (the one containing "RELAY LANE DISPATCH"), reads ROLE / TASK / IN SCOPE / OUTPUT from
# it, and behaves according to env:
#   STUB_<role>=ok|quota|hang|nooutput|stray|commit|limit   (default ok)
#   STUB_VERDICTS="FAIL PASS ..."   validator verdicts, consumed one per call
#   STUB_STATE=<dir>                counters + call log (calls.log)
#   STUB_SLEEP=<secs>               work time per call (default 0)
name="$(basename "$0")"
prompt=""
for a in "$@"; do case "$a" in *"RELAY LANE DISPATCH"*) prompt="$a" ;; esac; done
field() { printf '%s\n' "$prompt" | sed -n "s/^$1: //p" | head -1; }
role="$(field ROLE)"; task="$(field TASK)"; out="$(field OUTPUT)"; scope="$(field 'IN SCOPE')"
state="${STUB_STATE:-/tmp}"; mkdir -p "$state"
mode_var="STUB_${role}"; mode="${!mode_var:-ok}"
printf '%s %s %s start %s cwd=%s\n' "$name" "$role" "$task" "$(date +%s%N)" "$PWD" >> "$state/calls.log"

if [ "$mode" = quota ] && [ "$name" = agy ]; then
  echo "⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 3h."; exit 1
fi
if [ "$mode" = limit ] && [ "$name" = claude ]; then
  echo "Claude usage limit reached. /rate-limit-options"; exit 1
fi
[ "$mode" = hang ] && exec sleep 600
sleep "${STUB_SLEEP:-0}"

first_scope="${scope%% *}"
case "$role" in
  write|inline)
    if [ -n "$first_scope" ]; then mkdir -p "$first_scope"; printf '%s\n' "$task" >> "$first_scope/$task.txt"; fi
    [ "$mode" = stray ] && printf 'oops\n' > stray.txt
    [ "$mode" = commit ] && { git add -A; git commit -qm "stub commit" >/dev/null 2>&1; }
    body="## Changed
- $first_scope/$task.txt
CHECKS: PASS" ;;
  prebrief) body="# Pre-brief: $task
| R1 | \"clause\" | expected | probe | (Written: pre)" ;;
  evidence) body="# Evidence: $task
| Probe | Case | Written | Outcome |" ;;
  validator)
    n="$(cat "$state/vcount" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$state/vcount"
    v="$(printf '%s\n' ${STUB_VERDICTS:-PASS} | sed -n "${n}p")"; v="${v:-PASS}"
    body="VERDICT: $v" ;;
  *) body="stub $role output" ;;
esac
[ "$mode" = nooutput ] || { [ -n "$out" ] && printf '%s\n' "$body" > "$out"; }
printf '%s %s %s end %s\n' "$name" "$role" "$task" "$(date +%s%N)" >> "$state/calls.log"
echo DONE
