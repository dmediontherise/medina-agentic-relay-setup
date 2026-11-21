# shellcheck shell=bash
# Lane commands. Each one prints exactly one protocol line on stdout:
#   LANE <lane> <status> <run-dir>
# and all chatter on stderr, so an orchestrator can parse the result with ${out##* }.

CHARTERS="$RELAY_HOME/charters"

# Parses the common options into WS DOC TASK ROW FEATURE QUESTION MUTATE.
lane_args() {
  WS="$PWD"; DOC=""; TASK=""; QUESTION=""; MUTATE="${RELAY_LANES_MUTATE:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -w|--workspace) WS="$2"; shift 2 ;;
      --doc)          DOC="$2"; shift 2 ;;
      --task)         TASK="$2"; shift 2 ;;
      --question)     QUESTION="$2"; shift 2 ;;
      --mutate)       MUTATE=1; shift ;;
      *) lanes_fail "unknown option: $1" ;;
    esac
  done
  [ -d "$WS" ] || lanes_fail "workspace not found: $WS"
  WS="$(cd "$WS" && pwd)"
  [ -n "$DOC" ] || lanes_fail "--doc odd/tasks/<feature>.md is required"
  case "$DOC" in /*) ;; *) DOC="$WS/$DOC" ;; esac
  [ -f "$DOC" ] || lanes_fail "feature doc not found: $DOC"
  FEATURE="$(basename "$DOC" .md)"
  ROW=""
  if [ -n "$TASK" ]; then
    ROW="$(lane_row "$DOC" "$TASK")"
    [ -n "$ROW" ] || lanes_fail "no row $TASK in ## Tasks of $DOC"
  fi
  lane_init_ws "$WS"
}

# <role> <charter...> -- <line...> -> dispatch text
lane_prompt() {
  local role="$1" c list=""; shift
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do list="$list $1"; shift; done
  [ "${1:-}" = "--" ] && shift
  lanes_rea_on && list="$list $CHARTERS/rea.md"
  printf 'RELAY LANE DISPATCH - one bounded turn, then stop.\n'
  printf 'ROLE: %s\n' "$role"
  printf 'CHARTERS (read in this order; the last one overrides bus paths):'
  for c in $list; do printf ' %s' "$c"; done
  printf '\n'
  printf '%s\n' "$@"
}

# base charters per role; lane-mode.md last
lane_charters() {
  local hs="$CHARTERS/house-style.md" lm="$CHARTERS/lane-mode.md"
  case "$1" in
    explore)          printf '%s %s' "$hs" "$CHARTERS/lane-explore.md" ;;
    write)            printf '%s %s %s' "$hs" "$CHARTERS/executor.md" "$lm" ;;
    prebrief|evidence) printf '%s %s %s' "$hs" "$CHARTERS/scout.md" "$lm" ;;
    validator)        printf '%s %s' "$CHARTERS/validator.md" "$lm" ;;
    mutate)           printf '%s %s %s' "$hs" "$CHARTERS/mutator.md" "$lm" ;;
    inline)           printf '%s' "$CHARTERS/lane-inline.md" ;;
  esac
}

# <run> <doc> <row>: write the verbatim task excerpt the lanes read as SPECS
lane_write_specs() {
  local run="$1" doc="$2" row="$3"
  # shellcheck disable=SC2046  # one S-id per word
  { printf '# Task excerpt (verbatim from %s)\n\n' "$doc"
    lane_doc_header "$doc"
    printf '\n## Task row\n\n%s\n\n## Specs for this task\n\n' "$row"
    lane_spec_text "$doc" $(lane_row_specs "$row")
  } > "$run/specs.md"
}

cmd_explore() {
  lane_args "$@"
  [ -n "$TASK" ] || lanes_fail "explore needs --task"
  local run st
  run="$(lane_new_run "$WS" "$FEATURE" "$TASK" explore)"
  lane_write_specs "$run" "$DOC" "$ROW"
  # shellcheck disable=SC2046
  st="$(lane_exec "$run" explore explore "$WS" "$(lane_prompt explore $(lane_charters explore) -- \
        "TASK: $TASK" "SPECS: $run/specs.md" "FEATURE DOC: $DOC" \
        "QUESTION: ${QUESTION:-what must change to satisfy SPECS, and where}" "OUTPUT: $run/map.md")" "$run/map.md")"
  printf 'LANE explore %s %s\n' "$st" "$run"
}

# <run> <role write|inline> <in> -> status of the writer turn (no scope handling)
lane_writer() {
  local run="$1" role="$2" in="$3"
  lane_write_specs "$run" "$DOC" "$ROW"
  # shellcheck disable=SC2046
  lane_exec "$run" "$role" "$role" "$WS" "$(lane_prompt "$role" $(lane_charters "$role") -- \
    "TASK: $TASK" "SPECS: $run/specs.md" "FEATURE DOC: $DOC" "IN SCOPE: $in" "OUTPUT: $run/result.md")" "$run/result.md"
}

# <run> <head0> <pre> <in>: undo writer commits, revert out-of-scope paths.
# Prints the reverted paths (one per line) and records them in <run>/scope-violations.txt.
lane_enforce_scope() {
  local run="$1" head0="$2" pre="$3" in="$4" bad p
  if [ "$(git -C "$WS" rev-parse HEAD)" != "$head0" ]; then
    lanes_warn "a writer committed on its own - soft-resetting to $head0 (autopilot owns commits)"
    git -C "$WS" reset -q --soft "$head0"
  fi
  lane_tree_state "$WS" > "$run/tree-post.tsv"
  bad="$(lane_tree_delta "$pre" "$run/tree-post.tsv" | lane_out_of_scope "$in")"
  [ -n "$bad" ] || return 0
  printf '%s\n' "$bad" > "$run/scope-violations.txt"
  while IFS= read -r p; do lane_revert_path "$WS" "$p" "$pre"; done <<< "$bad"
  lanes_warn "reverted out-of-scope changes: $(printf '%s' "$bad" | tr '\n' ' ')"
  printf '%s\n' "$bad"
}

# <run>: citation check on the writer's ## Changed files, logged to <run>/cite.txt
lane_cite() {
  local run="$1" base
  lanes_cite_on || return 0
  [ -f "$run/result.md" ] || return 0
  base="$FEATURE-$TASK"
  mkdir -p "$WS/.relay/results"; cp "$run/result.md" "$WS/.relay/results/$base.md"
  timeout 240 "$CITE_PY" -I "$CITE_HELPER" "$WS" "$base" 2>/dev/null | head -n 1 > "$run/cite.txt" || true
}

cmd_write() {
  lane_args "$@"
  [ -n "$TASK" ] || lanes_fail "write needs --task"
  local run st in head0 bad
  in="$(lane_row_in "$ROW")"
  [ -n "$in" ] || lanes_fail "row $TASK has no In: scope - a write lane needs one"
  run="$(lane_new_run "$WS" "$FEATURE" "$TASK" write)"
  head0="$(git -C "$WS" rev-parse HEAD)"
  lane_tree_state "$WS" > "$run/tree-pre.tsv"
  st="$(lane_writer "$run" write "$in")"
  bad="$(lane_enforce_scope "$run" "$head0" "$run/tree-pre.tsv" "$in")"
  [ -n "$bad" ] && [ "$st" = ok ] && st=scope-violation
  lane_cite "$run"
  printf 'LANE write %s %s\n' "$st" "$run"
}

# The pre-brief runs in a temp dir OUTSIDE the repo holding only specs.md and the
# charters, so the scout is never pointed at code: a probe whose expected value comes from
# the implementation cannot fail (README "Why the scout exists"). agy also gets --sandbox.
# -> status; on ok, <run>/prebrief.md exists
lane_prebrief() {
  local run="$1" sb st c
  sb="$(mktemp -d "${TMPDIR:-/tmp}/relay-prebrief-XXXXXX")"
  lane_write_specs "$run" "$DOC" "$ROW"
  cp "$run/specs.md" "$sb/specs.md"
  for c in $(lane_charters prebrief); do cp "$c" "$sb/"; done
  # shellcheck disable=SC2046
  st="$(lane_exec "$run" prebrief prebrief "$sb" "$(lane_prompt prebrief \
        $(for c in $(lane_charters prebrief); do printf '%s ' "$sb/$(basename "$c")"; done) -- \
        "TASK: $TASK" "SPECS: $sb/specs.md" "OUTPUT: $sb/prebrief.md")" "$sb/prebrief.md")"
  [ -f "$sb/prebrief.md" ] && cp "$sb/prebrief.md" "$run/prebrief.md"
  rm -rf "$sb"
  printf '%s' "$st"
}

cmd_prebrief() {
  lane_args "$@"
  [ -n "$TASK" ] || lanes_fail "prebrief needs --task"
  local run st
  run="$(lane_new_run "$WS" "$FEATURE" "$TASK" prebrief)"
  st="$(lane_prebrief "$run")"
  printf 'LANE prebrief %s %s\n' "$st" "$run"
}

# <verdict.md> -> PASS | PASS-WITH-CONCERNS | FAIL. A report without a VERDICT line goes
# to Jev when enabled; anything still unclear is FAIL (one follow-up costs less than a
# laundered pass - same asymmetry as relay_jev.py).
lane_verdict_word() {
  local v
  v="$(grep -m1 -oE '^VERDICT:[[:space:]]*(PASS-WITH-CONCERNS|PASS|FAIL)' "$1" 2>/dev/null | sed -E 's/^VERDICT:[[:space:]]*//' || true)"
  if [ -z "$v" ] && [ -f "$1" ] && lanes_jev_on; then v="$(lanes_jev verdict "$WS" "$1")"; v="${v%% *}"; fi
  case "$v" in PASS|PASS-WITH-CONCERNS|FAIL) printf '%s' "$v" ;; *) printf 'FAIL' ;; esac
}

# <run>: mutation lane on a snapshot, in the background; never on the critical path
lane_mutate_bg() {
  local run="$1" snap="$1/snapshot"
  mkdir -p "$snap"
  (cd "$WS" && git ls-files -co --exclude-standard -z -- . ':(exclude).relay' | xargs -0 -r cp --parents -t "$snap")
  # shellcheck disable=SC2046
  ( lane_exec "$run" mutate mutate "$snap" "$(lane_prompt mutate $(lane_charters mutate) -- \
      "TASK: $TASK" "SPECS: $run/specs.md" "SNAPSHOT: $snap" "OUTPUT: $run/mutation.md")" "$run/mutation.md" \
      > "$run/mutate.status" ) < /dev/null > /dev/null 2>&1 &
  lanes_say "mutation lane started in the background -> $run/mutation.md"
}

# Runs prebrief (unless a finished one exists for this task), evidence and the verdict.
# -> PASS | PASS-WITH-CONCERNS | FAIL | no-evidence | <lane status>; run dir in VERIFY_RUN
lane_verify_run() {
  local run pb st ev
  run="$(lane_new_run "$WS" "$FEATURE" "$TASK" verify)"; VERIFY_RUN="$run"
  lane_write_specs "$run" "$DOC" "$ROW"
  pb="$WS/.relay/runs/$FEATURE/$TASK/latest-prebrief/prebrief.md"
  if [ -f "$pb" ]; then cp "$pb" "$run/prebrief.md"; else
    st="$(lane_prebrief "$run")"
    [ "$st" = ok ] || lanes_warn "prebrief $st - evidence will be gathered without pre probes"
  fi
  lane_diff "$WS" > "$run/diff.patch"
  local res=""; [ -f "$WS/.relay/runs/$FEATURE/$TASK/latest-write/result.md" ] && res="RESULT: $WS/.relay/runs/$FEATURE/$TASK/latest-write/result.md"
  # shellcheck disable=SC2046
  ev="$(lane_exec "$run" evidence evidence "$WS" "$(lane_prompt evidence $(lane_charters evidence) -- \
        "TASK: $TASK" "SPECS: $run/specs.md" "FEATURE DOC: $DOC" "PREBRIEF: $run/prebrief.md" \
        "DIFF: $run/diff.patch" ${res:+"$res"} "OUTPUT: $run/evidence.md")" "$run/evidence.md")"
  if [ "$ev" != ok ]; then
    case "$ev" in limit|auth) printf '%s' "$ev" ;; *) printf 'no-evidence' ;; esac; return 0
  fi
  [ "$MUTATE" = "1" ] && lane_mutate_bg "$run"
  # shellcheck disable=SC2046
  st="$(lane_exec "$run" validator validator "$WS" "$(lane_prompt validator $(lane_charters validator) -- \
        "TASK: $TASK" "SPECS: $run/specs.md" "PREBRIEF: $run/prebrief.md" "EVIDENCE: $run/evidence.md" \
        "DIFF: $run/diff.patch" "OUTPUT: $run/verdict.md")" "$run/verdict.md")"
  if [ "$st" != ok ]; then printf '%s' "$st"; return 0; fi
  lane_verdict_word "$run/verdict.md"
}

cmd_verify() {
  lane_args "$@"
  [ -n "$TASK" ] || lanes_fail "verify needs --task"
  local v
  VERIFY_RUN=""
  v="$(lane_verify_run)"
  # lane_verify_run ran in a subshell; recover its run dir from the latest link
  printf 'LANE verify %s %s\n' "$v" "$(cd "$WS/.relay/runs/$FEATURE/$TASK/latest-verify" && pwd -P)"
}

cmd_doctor() {
  local b v note
  for b in agy opencode claude tmux git gentle-ai engram; do
    v="$(lane_bin "$b")"
    if command -v "$v" >/dev/null 2>&1 || [ -x "$v" ]; then
      printf '  %-10s %s\n' "$b" "$v"
    else
      note=""; case "$b" in gentle-ai|engram) note=" (lanes still run without it)" ;; esac
      printf '  %-10s MISSING%s\n' "$b" "$note"
    fi
  done
  if lane_agy_cooling; then printf '  agy quota  cooling down since %s -> lanes use opencode\n' "$(date -d "@$(cat "$LANES_STATE/agy-quota-at")" 2>/dev/null)"
  else printf '  agy quota  no exhaustion recorded\n'; fi
  printf '  jev        %s\n' "$(lanes_jev_on && echo on || echo off)"
  printf '  cite       %s\n' "$(lanes_cite_on && echo on || echo off)"
  printf '  rea        %s\n' "$(lanes_rea_on && echo on || echo off)"
  printf '  charters   %s\n' "$CHARTERS"
}

cmd_status() {
  local ws="$PWD"
  [ "${1:-}" = "-w" ] && ws="$2"
  tmux list-windows -t "$LANES_SESSION" -F '  window #{window_name}' 2>/dev/null || printf '  no lanes session\n'
  find "$ws/.relay/runs" -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 10 |
    while read -r _ f; do printf '  %s\n    %s\n' "$f" "$(cat "$f")"; done
}

cmd_down() { tmux kill-session -t "$LANES_SESSION" 2>/dev/null || true; lanes_say "lanes session '$LANES_SESSION' stopped"; }
