#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RELAY_HOME; RELAY_HOME="$(cd "$here/../../relay" && pwd)"
unset RELAY_AGY_MODEL RELAY_AGY_MODEL_EXECUTOR RELAY_AGY_MODEL_SCOUT RELAY_AGY_MODEL_MUTATOR RELAY_OPENCODE_MODEL RELAY_LANES_SAFE
tmp="$(mktemp -d)"; export RELAY_LANES_STATE="$tmp/state"
. "$here/assert.sh"; . "$here/../../relay/lanes/lib.sh"; . "$here/../../relay/lanes/exec.sh"

printf 'working...\n⚠ Individual quota reached. Please upgrade. Resets in 3h.\n' > "$tmp/q.log"
printf 'Claude usage limit reached\n' > "$tmp/l.log"
printf 'all good\n' > "$tmp/ok.log"
t_eq "agy quota"        "$(lane_classify_log "$tmp/q.log" agy)" "quota"
t_eq "claude limit"     "$(lane_classify_log "$tmp/l.log" claude)" "limit"
t_eq "clean log"        "$(lane_classify_log "$tmp/ok.log" agy)" ""
t_eq "quota ignored for claude" "$(lane_classify_log "$tmp/q.log" claude)" ""

t_eq "write model"      "$(RELAY_AGY_MODEL_EXECUTOR=m-x lane_model_for agy write)" "m-x"
t_eq "scout default"    "$(lane_model_for agy evidence)" "gemini-3.8-flash-medium"
t_eq "opencode default" "$(lane_model_for opencode write)" "opencode/big-pickle"
t_eq "validator model"  "$(lane_model_for claude validator)" "claude-sonnet-5-5"
t_eq "inline model"     "$(lane_model_for claude inline)" "claude-opus-5-5"

c="$(lane_cmdline agy m /w 'hi there' prebrief)"
t_has "agy print mode"  "$c" " -p hi\\ there"
t_has "agy sandbox for prebrief" "$c" "--sandbox"
t_hasnt "no sandbox for write" "$(lane_cmdline agy m /w hi write)" "--sandbox"
t_has "claude validator acceptEdits" "$(lane_cmdline claude m /w hi validator)" "--permission-mode acceptEdits"
t_has "claude validator reads charters" "$(lane_cmdline claude m /w hi validator)" "--add-dir $RELAY_HOME/charters"
t_has "claude inline reads charters" "$(lane_cmdline claude m /w hi inline)" "--add-dir $RELAY_HOME/charters"
t_has "claude prompt after -- (add-dir is variadic)" "$(lane_cmdline claude m /w 'hi there' validator)" " -- hi\\ there"
t_has "claude inline bypass" "$(lane_cmdline claude m /w hi inline)" "--permission-mode bypassPermissions"
t_has "safe mode inline" "$(RELAY_LANES_SAFE=1 lane_cmdline claude m /w hi inline)" "--permission-mode acceptEdits"
t_has "opencode run" "$(lane_cmdline opencode m /w hi write)" " run -m m hi"

t_true "not cooling"    '! lane_agy_cooling'
lane_mark_agy_quota
t_true "cooling after quota" 'lane_agy_cooling'
t_true "cooldown expires" '! RELAY_QUOTA_COOLDOWN=0 lane_agy_cooling_check_at "$(( $(date +%s) + 1 ))"'
t_done
