# shellcheck shell=bash
# Unattended drain of an ODD feature document. Autopilot is the document's single writer
# for the run and updates it deterministically: a row is checked off only on observed
# proof (the header's Runner: command exiting 0 for low risk; a validator PASS or
# PASS-WITH-CONCERNS for high risk), and autopilot makes every commit itself.
#
# Exit: 0 drained or stopped by .relay/STOP; 4 rows remain that need a human decision.

AP_BLOCKED_IN=""     # In: entries of blocked rows; overlapping rows are not run
AP_CLAUDE_DOWN=0     # set on a Claude limit; inline and high-risk rows wait

ap_root_id() { printf '%s' "${1%%.f*}"; }

# <id> <reason>: mark [!] (and its root, for a follow-up), remember its scope, log it
ap_block() {
  local id="$1" why="$2" row root
  row="$(lane_row "$DOC" "$id")"
  lane_doc_replace_row "$DOC" "$id" "$(lane_row_with "$row" '!')"
  root="$(ap_root_id "$id")"
  if [ "$root" != "$id" ]; then lane_doc_replace_row "$DOC" "$root" "$(lane_row_with "$(lane_row "$DOC" "$root")" '!')"; fi
  AP_BLOCKED_IN="$AP_BLOCKED_IN $(lane_row_in "$row")"
  lane_doc_log "$DOC" "Needs your decision: $why"
}

# <id> -> 0 when the row can run now. Blocks rows that can never run (no scope, bad
# route, blocked dependency) as a side effect, so they stop being pending.
ap_runnable() {
  local id="$1" row route in dep m
  row="$(lane_row "$DOC" "$id")"; route="$(lane_row_route "$row")"; in="$(lane_row_in "$row")"
  case "$route" in inline|write|explore) ;; *) ap_block "$id" "$id has route '${route:-none}' (expected inline, write or explore)"; return 1 ;; esac
  if [ -z "$in" ] && [ "$route" != explore ]; then ap_block "$id" "$id has no In: scope"; return 1; fi
  for dep in $(lane_row_after "$row"); do
    m="$(lane_row_mark "$(lane_row "$DOC" "$dep")")"
    [ "$m" = "!" ] && { ap_block "$id" "$id depends on blocked $dep"; return 1; }
    [ "$m" = "x" ] || return 1
  done
  if [ "$AP_CLAUDE_DOWN" = 1 ] && { [ "$route" = inline ] || lane_row_risk_high "$row"; }; then return 1; fi
  [ -n "$(printf '%s' "$AP_BLOCKED_IN" | tr -d ' ')" ] && [ -n "$in" ] && lane_scopes_overlap "$in" "$AP_BLOCKED_IN" && return 1
  return 0
}

# Sets AP_BATCH to the ids to run next: one row, or a batch of low-risk write rows with
# pairwise-disjoint In: (at most RELAY_LANES_MAX_PARALLEL). A global rather than stdout,
# because ap_runnable's blocks must update AP_BLOCKED_IN in this shell, not a subshell.
ap_next_batch() {
  local id row first="" scopes="" n=0 max="${RELAY_LANES_MAX_PARALLEL:-3}"
  AP_BATCH=""
  for id in $(lane_pending_ids "$DOC"); do
    ap_runnable "$id" || continue
    row="$(lane_row "$DOC" "$id")"
    if [ -z "$first" ]; then
      first="$id"; AP_BATCH="$id"; scopes="$(lane_row_in "$row")"; n=1
      { [ "$(lane_row_route "$row")" = write ] && ! lane_row_risk_high "$row"; } || break
      continue
    fi
    [ "$n" -ge "$max" ] && break
    [ "$(lane_row_route "$row")" = write ] || continue
    lane_row_risk_high "$row" && continue
    lane_scopes_overlap "$(lane_row_in "$row")" "$scopes" && continue
    AP_BATCH="$AP_BATCH $id"; scopes="$scopes $(lane_row_in "$row")"; n=$((n + 1))
  done
}

# <id> <title> <in> -> short sha of a new commit holding only <in>, or "-" if nothing changed
ap_commit() {
  local id="$1" title="$2" in="$3"
  set -f
  # shellcheck disable=SC2086  # In: entries are pathspecs
  git -C "$WS" add -A -- $in
  set +f
  if git -C "$WS" diff --cached --quiet; then printf -- '-'; return 0; fi
  git -C "$WS" commit -q -m "feat($FEATURE): $title [$id]"
  git -C "$WS" rev-parse --short HEAD
}

# <id> <reason> <evidence-path>: first failure -> follow-up row; second -> blocked
ap_fail() {
  local id="$1" why="$2" link="$3" row fid
  row="$(lane_row "$DOC" "$id")"
  case "$id" in *.f*) ap_block "$id" "$id failed twice in a row ($why), see $link"; return 0 ;; esac
  fid="$id.f1"
  lane_doc_replace_row "$DOC" "$id" "$(lane_row_with "$row" '~')"
  lane_doc_insert_after "$DOC" "$id" "- [ ] $fid $(printf '%s' "${row:6}" | awk '{print $2}') Fix $id: $why - see $link (route: $(lane_row_route "$row"); risk: $(lane_row_kv "$row" risk); In: $(lane_row_in "$row"); commit: pending)"
  lane_doc_log "$DOC" "$id: $why -> follow-up $fid ($link)"
}

# <id> <sha> <note>: check off the row (and its root when it is a follow-up)
ap_done() {
  local id="$1" sha="$2" note="$3" root
  lane_doc_replace_row "$DOC" "$id" "$(lane_row_with "$(lane_row "$DOC" "$id")" x "$sha")"
  root="$(ap_root_id "$id")"
  [ "$root" != "$id" ] && lane_doc_replace_row "$DOC" "$root" "$(lane_row_with "$(lane_row "$DOC" "$root")" x "$sha")"
  lane_doc_log "$DOC" "$id done ($sha): $note"
}

# -> pass | fail | none   (the header's Runner: command, the only proof autopilot trusts)
ap_runner() {
  local cmd; cmd="$(lane_doc_runner "$DOC")"
  [ -n "$cmd" ] || { printf 'none'; return 0; }
  if (cd "$WS" && timeout "${RELAY_RUNNER_TIMEOUT:-900}" bash -c "$cmd") > "$WS/.relay/runs/$FEATURE/runner-last.log" 2>&1; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

ap_run_explore() {
  local id="$1" out st
  out="$(cmd_explore -w "$WS" --doc "$DOC" --task "$id")"; st="$(printf '%s' "$out" | awk '{print $3}')"
  if [ "$st" = ok ]; then ap_done "$id" "-" "map ${out##* }/map.md"; else ap_block "$id" "$id explore lane $st (${out##* })"; fi
}

# Runs the writers for a batch (parallel when >1), then scope, proof, verify and commit.
ap_run_batch() {
  local ids="$1" id row in route union="" head0 pre runs="" r st pb_pid="" proof v
  head0="$(git -C "$WS" rev-parse HEAD)"
  mkdir -p "$WS/.relay/runs/$FEATURE"
  pre="$WS/.relay/runs/$FEATURE/tree-pre-$$.tsv"; lane_tree_state "$WS" > "$pre"
  for id in $ids; do
    TASK="$id"; ROW="$(lane_row "$DOC" "$id")"; in="$(lane_row_in "$ROW")"; route="$(lane_row_route "$ROW")"
    union="$union $in"
    r="$(lane_new_run "$WS" "$FEATURE" "$id" write)"; runs="${runs:+$runs }$r"
    # A high-risk row's pre-brief runs alongside its writer: it needs only the specs.
    if lane_row_risk_high "$ROW"; then
      ( pr="$(lane_new_run "$WS" "$FEATURE" "$id" prebrief)"; lane_prebrief "$pr" > /dev/null ) & pb_pid=$!
    fi
    [ "$route" = inline ] && role=inline || role=write
    ( TASK="$id"; ROW="$(lane_row "$DOC" "$id")"; lane_writer "$r" "$role" "$in" > "$r/status" ) &
  done
  wait
  r="$(lane_enforce_scope "${runs%% *}" "$head0" "$pre" "$union")"
  [ -n "$r" ] && lane_doc_log "$DOC" "scope: reverted out-of-scope edits from $ids: $(printf '%s' "$r" | tr '\n' ' ')"
  proof="$(ap_runner)"

  set -- $runs
  for id in $ids; do
    r="$1"; shift
    TASK="$id"; ROW="$(lane_row "$DOC" "$id")"; in="$(lane_row_in "$ROW")"
    st="$(cat "$r/status" 2>/dev/null || echo failed)"
    case "$st" in
      limit) AP_CLAUDE_DOWN=1; ap_block "$id" "Claude limit reached while running $id ($(date -u +%FT%TZ)); rerun autopilot when it resets"; continue ;;
      ok) ;;
      *) ap_block "$id" "$id writer $st (${r})"; continue ;;
    esac
    if grep -q '^## Needs a decision' "$r/result.md" 2>/dev/null; then
      ap_block "$id" "$id writer needs a decision, see $r/result.md"; continue
    fi
    if lane_row_risk_high "$ROW"; then
      [ -n "$pb_pid" ] && wait "$pb_pid" 2>/dev/null || true
      v="$(lane_verify_run)"
      case "$v" in
        PASS|PASS-WITH-CONCERNS) ap_done "$id" "$(ap_commit "$id" "$(lane_row_title "$ROW")" "$in")" "verify $v ($WS/.relay/runs/$FEATURE/$id/latest-verify/verdict.md)" ;;
        FAIL) ap_fail "$id" "validator FAIL" "$WS/.relay/runs/$FEATURE/$id/latest-verify/verdict.md" ;;
        limit) AP_CLAUDE_DOWN=1; ap_block "$id" "Claude limit reached while verifying $id ($(date -u +%FT%TZ))" ;;
        *) ap_block "$id" "$id verify $v - no verdict without evidence ($WS/.relay/runs/$FEATURE/$id/latest-verify)" ;;
      esac
      continue
    fi
    case "$proof" in
      pass) ap_done "$id" "$(ap_commit "$id" "$(lane_row_title "$ROW")" "$in")" "Runner passed" ;;
      fail) ap_fail "$id" "Runner failed after the writer" "$WS/.relay/runs/$FEATURE/runner-last.log" ;;
      none)
        if grep -q '^CHECKS: FAIL' "$r/result.md"; then ap_fail "$id" "writer reported CHECKS: FAIL" "$r/result.md"
        else ap_done "$id" "$(ap_commit "$id" "$(lane_row_title "$ROW")" "$in")" "UNVERIFIED by autopilot: no Runner: in the doc header; writer said $(grep -m1 '^CHECKS:' "$r/result.md" || echo 'nothing')"; fi ;;
    esac
  done
  rm -f "$pre"
}

ap_finish() {
  if ! git -C "$WS" diff --quiet -- "$DOC"; then
    git -C "$WS" add -- "$DOC"
    git -C "$WS" commit -q -m "docs(odd): update $FEATURE task log"
  fi
}

cmd_autopilot() {
  lane_args "$@"
  local dirty batch first
  dirty="$(git -C "$WS" status --porcelain -- . ':(exclude).relay' ':(exclude)odd')"
  [ -z "$dirty" ] || lanes_fail "autopilot needs a clean tree outside odd/ and .relay/ - commit or stash first"
  lane_doc_log "$DOC" "autopilot started $(date -u +%FT%TZ); Engram mirror is not updated headless - reconcile on resume"
  while :; do
    if [ -f "$WS/.relay/STOP" ]; then lane_doc_log "$DOC" "autopilot stopped by .relay/STOP"; ap_finish; return 0; fi
    ap_next_batch; batch="$AP_BATCH"
    if [ -z "$batch" ]; then
      if [ -n "$(lane_pending_ids "$DOC")" ]; then
        lane_doc_log "$DOC" "Needs your decision: rows still pending but none can run ($(lane_pending_ids "$DOC" | tr '\n' ' '))"
        ap_finish; return 4
      fi
      if grep -qE '^- \[!\] ' "$DOC"; then
        lane_doc_log "$DOC" "autopilot: finished with blocked rows"; ap_finish; return 4
      fi
      lane_doc_log "$DOC" "autopilot: queue drained"; ap_finish; return 0
    fi
    first="${batch%% *}"
    lanes_say "running: $batch"
    if [ "$(lane_row_route "$(lane_row "$DOC" "$first")")" = explore ]; then ap_run_explore "$first"
    else ap_run_batch "$batch"; fi
  done
}
