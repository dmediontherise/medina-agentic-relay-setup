#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Medina lanes - delegation backend for a gentle-ai (ODD) orchestrator.
#
# The orchestrator works inline by default and calls a lane only for a named reason:
#   explore   read-only map, when understanding exceeds the inline budget
#   write     an agy writer for one independent unit with its own In: scope
#   prebrief  scout probes written from the S# specs alone, before/without code
#   verify    prebrief -> scout evidence -> Sonnet verdict, for a high-risk change
#   autopilot drain an ODD feature document's ## Tasks unattended
# Each lane is one headless agent turn in a tmux window (session: lanes). relay.sh is
# untouched and remains the fallback. Design: docs/superpowers/specs/2026-11-21-gentle-ai-lanes-design.md
# ---------------------------------------------------------------------------
set -euo pipefail

LANES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_HOME="${RELAY_HOME:-$LANES_SRC}"
# shellcheck source=lanes/lib.sh
. "$LANES_SRC/lanes/lib.sh"
# shellcheck source=lanes/exec.sh
. "$LANES_SRC/lanes/exec.sh"
# shellcheck source=lanes/flow.sh
. "$LANES_SRC/lanes/flow.sh"
[ -f "$LANES_SRC/lanes/autopilot.sh" ] && . "$LANES_SRC/lanes/autopilot.sh"

usage() {
  cat <<'EOF'
lanes.sh <command> [-w <workspace>] --doc odd/tasks/<feature>.md [--task <id>] [options]

  explore   --task T [--question "..."]   read-only path:line map        -> map.md
  write     --task T                      agy writer inside the row's In: -> result.md
  prebrief  --task T                      spec-only probes (no code)      -> prebrief.md
  verify    --task T [--mutate]           prebrief, evidence, verdict     -> verdict.md
  autopilot                               drain ## Tasks unattended
  doctor | status | down

Prints one line on stdout: LANE <lane> <status> <run-dir>
Env: RELAY_AGY_MODEL[_EXECUTOR|_SCOUT|_MUTATOR], RELAY_OPENCODE_MODEL[...],
     RELAY_LANE_TIMEOUT (1800), RELAY_QUOTA_COOLDOWN (3600), RELAY_NO_OPENCODE_FALLBACK,
     RELAY_LANES_SAFE, RELAY_LANES_MUTATE, RELAY_LANES_MAX_PARALLEL (3), RELAY_JEV,
     RELAY_CITE, RELAY_REA. Stop autopilot: touch <workspace>/.relay/STOP
EOF
}

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    explore)   cmd_explore "$@" ;;
    write)     cmd_write "$@" ;;
    prebrief)  cmd_prebrief "$@" ;;
    verify)    cmd_verify "$@" ;;
    autopilot) cmd_autopilot "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    status)    cmd_status "$@" ;;
    down)      cmd_down "$@" ;;
    ''|-h|--help|help) usage ;;
    *) usage; lanes_fail "unknown command: $cmd" ;;
  esac
}

main "$@"
