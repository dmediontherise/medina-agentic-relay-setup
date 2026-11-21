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
