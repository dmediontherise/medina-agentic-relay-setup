#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Medina Agentic Relay - tmux control plane (macOS / Linux).
#
# Opus (orchestrator) drives an executor and two Claude reviewers as live tmux
# panes. Content moves over a file bus (.relay/) so results are clean and
# lossless; tmux provides process persistence, liveness, and the ability to
# send follow-up instructions into a running agent.
#
# This is the POSIX counterpart to relay.ps1. Same subcommands, same bus
# layout, same charters - so a task file written on one platform runs on the
# other unchanged.
# ---------------------------------------------------------------------------
set -euo pipefail

RELAY_HOME="${RELAY_HOME:-$HOME/.claude/relay}"
STATE_FILE="$RELAY_HOME/state"
SESSION="${RELAY_SESSION:-relay}"

say()  { printf '\033[36m[relay]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[relay] WARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31m[relay] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need_tmux() {
  command -v tmux >/dev/null 2>&1 || fail "tmux not found. macOS: brew install tmux . Debian/Ubuntu: sudo apt install tmux"
}

load_state() {
  [ -f "$STATE_FILE" ] || fail "Relay is not up. Run: relay.sh up -w <workspace>"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

pane_for() {
  case "$1" in
    executor)  printf '%s' "$EXECUTOR_PANE" ;;
    validator) printf '%s' "$VALIDATOR_PANE" ;;
    scout)     printf '%s' "$SCOUT_PANE" ;;
    *) fail "Unknown agent '$1'. Use executor, validator or scout." ;;
  esac
}

# Clear whatever is sitting in the agent's input line before typing, then send
# the payload literally and press Enter separately. Agent TUIs routinely leave
# ghost text in the prompt; without the C-u your instruction is appended to it.
send_line() {
  local target="$1" line="$2"
  tmux send-keys -t "$target" C-u
  sleep 0.15
  tmux send-keys -t "$target" -l -- "$line"
  sleep 0.25
  tmux send-keys -t "$target" Enter
}

# Resolve bus paths against the workspace: artifact paths are written relative
# to it, but the orchestrator rarely runs from there.
bus_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$WORKSPACE" "$1" ;;
  esac
}

usage() {
  cat <<'EOF'
Medina Agentic Relay - tmux control plane

  relay.sh up   [-w <workspace>] [--safe]   Build the session and boot the agents
  relay.sh down                             Tear the session down
  relay.sh status                           Session health, pane state, bus contents
  relay.sh send     -a <agent> -t <text>    Type a line into a running agent
  relay.sh dispatch -a <agent> -T <task.md> Hand a task file to an agent
  relay.sh capture  -a <agent> [-n 60]      Print the tail of a pane
  relay.sh wait     -f <artifact> [-a <agent>] [--timeout 900]
  relay.sh bus                              List artifacts on the file bus
  relay.sh attach                           Print the attach command

  agents: executor | validator | scout
EOF
}

# =============================================================== UP ==========
cmd_up() {
  local workspace="" safe=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -w|--workspace) workspace="$2"; shift 2 ;;
      --safe) safe=1; shift ;;
      *) fail "Unknown option for up: $1" ;;
    esac
  done
  [ -n "$workspace" ] || workspace="$PWD"
  [ -d "$workspace" ] || fail "Workspace not found: $workspace"
  workspace="$(cd "$workspace" && pwd)"

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    say "Session '$SESSION' already running. Use 'down' first to rebuild."
    exit 0
  fi

  mkdir -p "$RELAY_HOME"
  mkdir -p "$workspace/.relay"/{tasks,results,evidence,reports,logs,launch}

  # Charters describe each agent's contract with the bus.
  for c in executor validator scout; do
    [ -f "$RELAY_HOME/charters/$c.md" ] && cp -f "$RELAY_HOME/charters/$c.md" "$workspace/.relay/$c.md"
  done

  # Preflight. Gemini CLI's "Sign in with Google" was retired for individual
  # accounts on 2026-06-18, so the executor runs Antigravity CLI (agy), which
  # authenticates through the normal Google browser sign-in.
  local agy_exe claude_exe
  agy_exe="$(command -v agy || true)"
  [ -z "$agy_exe" ] && [ -x "$HOME/.local/bin/agy" ] && agy_exe="$HOME/.local/bin/agy"
  claude_exe="$(command -v claude || true)"
  [ -z "$claude_exe" ] && [ -x "$HOME/.local/bin/claude" ] && claude_exe="$HOME/.local/bin/claude"

  if [ -z "$agy_exe" ]; then
    warn "'agy' (Antigravity CLI) not found - the executor pane will not start."
    warn "Install: curl -fsSL https://antigravity.google/cli/install.sh | sh"
    agy_exe="agy"
  fi
  if [ -z "$claude_exe" ]; then
    warn "'claude' not found - scout and validator will not start."
    claude_exe="claude"
  fi
  say "executor bin : $agy_exe"
  say "claude  bin  : $claude_exe"

  # --- launchers -----------------------------------------------------------
  # Each pane execs a generated script rather than having a command typed into
  # an interactive shell. Typed launches are fragile: the payload is subject to
  # send-keys quoting rules, and the pane shell inherits its environment from
  # the tmux server, which may have been started by anything.
  local launch="$workspace/.relay/launch"
  local exec_flags="--dangerously-skip-permissions"
  local claude_mode="bypassPermissions"
  if [ "$safe" -eq 1 ]; then
    exec_flags="--mode accept-edits"
    claude_mode="acceptEdits"
  fi

  write_launcher() {
    local name="$1" body="$2"
    {
      printf '#!/usr/bin/env bash\n'
      printf 'export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"\n'
      printf 'cd %q || exit 1\n' "$workspace"
      printf '%s\n' "$body"
    } > "$launch/$name.sh"
    chmod +x "$launch/$name.sh"
    printf '%s' "$launch/$name.sh"
  }

  local exec_boot val_boot scout_boot
  exec_boot="Read .relay/executor.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for task files."
  val_boot="Read .relay/validator.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for evidence files to grade."
  scout_boot="Read .relay/scout.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for result files to gather evidence on."

  local l_exec l_val l_scout l_bus
  l_exec="$(write_launcher executor "$(printf 'exec %q --model gemini-3.6-flash-high %s -i %q' "$agy_exe" "$exec_flags" "$exec_boot")")"
  l_val="$(write_launcher validator "$(printf 'exec %q --model opus --permission-mode %s %q' "$claude_exe" "$claude_mode" "$val_boot")")"
  l_scout="$(write_launcher scout "$(printf 'exec %q --model sonnet --permission-mode %s %q' "$claude_exe" "$claude_mode" "$scout_boot")")"
  l_bus="$(write_launcher buswatch 'while true; do clear; printf "== RELAY BUS ==\n\n"; find .relay -type f -name "*.md" -not -path "*/launch/*" -exec ls -lt {} + 2>/dev/null | head -14; sleep 3; done')"

  say "Building session '$SESSION' in $workspace"

  tmux new-session  -d -s "$SESSION" -n agents -c "$workspace" "$l_exec"
  sleep 1
  for l in "$l_val" "$l_scout" "$l_bus"; do
    tmux split-window -t "$SESSION:agents" -c "$workspace" "$l"
    sleep 1
  done
  tmux select-layout -t "$SESSION:agents" tiled
  sleep 0.5

  # Stable pane IDs (%N) so later targeting survives index shuffling.
  local ids
  ids="$(tmux list-panes -t "$SESSION:agents" -F '#{pane_index} #{pane_id}' | sort -n | awk '{print $2}')"
  [ "$(printf '%s\n' "$ids" | wc -l)" -ge 4 ] || fail "Expected 4 panes."

  cat > "$STATE_FILE" <<EOF
SESSION="$SESSION"
WORKSPACE="$workspace"
EXECUTOR_PANE="$(printf '%s\n' "$ids" | sed -n 1p)"
VALIDATOR_PANE="$(printf '%s\n' "$ids" | sed -n 2p)"
SCOUT_PANE="$(printf '%s\n' "$ids" | sed -n 3p)"
BUS_PANE="$(printf '%s\n' "$ids" | sed -n 4p)"
SAFE="$safe"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
  load_state

  # Agents boot into a folder-trust gate. A pane sitting on that prompt is
  # indistinguishable from a busy one in a capture, and it is this relay's
  # single most common failure mode - so clear it explicitly.
  say "Waiting for agents to boot and clearing startup prompts..."
  local deadline=$(( $(date +%s) + 90 ))
  local pending="$EXECUTOR_PANE $VALIDATOR_PANE $SCOUT_PANE"
  while [ -n "${pending// /}" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 3
    local still=""
    for p in $pending; do
      local txt; txt="$(tmux capture-pane -t "$p" -p 2>/dev/null || true)"
      if printf '%s' "$txt" | grep -qiE 'trust (the contents of this|this folder)'; then
        tmux send-keys -t "$p" Enter; say "Accepted folder-trust prompt in pane $p"; sleep 0.6
      elif printf '%s' "$txt" | grep -qiE 'READY|\? for shortcuts|shift\+tab to cycle'; then
        : # already past the gate
      else
        still="$still $p"
      fi
    done
    pending="$still"
  done
  for p in $pending; do warn "pane $p never cleared its startup prompt - inspect with 'capture'."; done

  say "Relay up."
  say "  executor  (agy / gemini-3.6-flash-high) -> $EXECUTOR_PANE"
  say "  validator (claude opus)                 -> $VALIDATOR_PANE"
  say "  scout     (claude sonnet)               -> $SCOUT_PANE"
  say "  bus watch                               -> $BUS_PANE"
  say "Attach with: tmux attach -t $SESSION"
}

# ============================================================= DOWN ==========
cmd_down() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$STATE_FILE"
  say "Relay '$SESSION' torn down."
}

# =========================================================== STATUS ==========
cmd_status() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    printf '\033[33m[relay] DOWN - no tmux session '\''%s'\''.\033[0m\n' "$SESSION"; exit 0
  fi
  load_state
  printf '\033[32m[relay] UP  session=%s  workspace=%s\033[0m\n' "$SESSION" "$WORKSPACE"
  printf '        safe-mode=%s\n' "$SAFE"
  tmux list-panes -t "$SESSION:agents" -F '        pane #{pane_index} (#{pane_id}) cmd=#{pane_current_command} active=#{pane_active}'
  for d in tasks results evidence reports; do
    local n; n="$(find "$WORKSPACE/.relay/$d" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '        %s: %s artifact(s)\n' "$d" "$n"
    find "$WORKSPACE/.relay/$d" -maxdepth 1 -type f 2>/dev/null | head -3 | while read -r f; do
      printf '            - %s\n' "$(basename "$f")"
    done
  done
}

# ============================================================= SEND ==========
cmd_send() {
  local agent="" text=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--agent) agent="$2"; shift 2 ;;
      -t|--text)  text="$2";  shift 2 ;;
      *) fail "Unknown option for send: $1" ;;
    esac
  done
  [ -n "$agent" ] || fail "-a <agent> required"
  [ -n "$text" ]  || fail "-t <text> required"
  load_state
  send_line "$(pane_for "$agent")" "$text"
  say "Sent to $agent."
}

# ========================================================= DISPATCH ==========
# The task file IS the interface - it keeps quoting sane and gives the agent a
# durable spec it can re-read.
cmd_dispatch() {
  local agent="executor" task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--agent) agent="$2"; shift 2 ;;
      -T|--task)  task="$2";  shift 2 ;;
      *) fail "Unknown option for dispatch: $1" ;;
    esac
  done
  [ -n "$task" ] || fail "-T <task .md> required"
  load_state
  local abs rel msg
  abs="$(bus_path "$task")"
  [ -f "$abs" ] || fail "Task file not found: $abs"
  rel="${abs#"$WORKSPACE"/}"
  case "$agent" in
    executor)  msg="New task on the bus: $rel . Read it, execute it per your contract in .relay/executor.md, and write your completion report to the results path named in the task." ;;
    scout)     msg="Gather evidence for: $rel . Follow your contract in .relay/scout.md - re-run the verification commands yourself, record what you observe, and write to the evidence path named in the task. Do not issue a verdict." ;;
    validator) msg="Grade this task: $rel . Follow your contract in .relay/validator.md - read the task, the executor result, and the scout evidence, then write your verdict to the report path named in the task." ;;
    *) fail "Unknown agent '$agent'." ;;
  esac
  send_line "$(pane_for "$agent")" "$msg"
  say "Dispatched $rel -> $agent"
}

# ========================================================== CAPTURE ==========
cmd_capture() {
  local agent="" lines=60
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--agent) agent="$2"; shift 2 ;;
      -n|--lines) lines="$2"; shift 2 ;;
      *) fail "Unknown option for capture: $1" ;;
    esac
  done
  [ -n "$agent" ] || fail "-a <agent> required"
  load_state
  tmux capture-pane -t "$(pane_for "$agent")" -p | tail -n "$lines"
}

# ============================================================= WAIT ==========
# Block until an artifact lands on the bus. This is what closes the loop.
cmd_wait() {
  local file="" agent="" timeout=900
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--file)    file="$2";    shift 2 ;;
      -a|--agent)   agent="$2";   shift 2 ;;
      --timeout)    timeout="$2"; shift 2 ;;
      *) fail "Unknown option for wait: $1" ;;
    esac
  done
  [ -n "$file" ] || fail "-f <artifact path> required"
  load_state
  local watch; watch="$(bus_path "$file")"
  say "Waiting for $watch (timeout ${timeout}s)..."
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$watch" ]; then
      sleep 0.7   # let the writer finish flushing
      say "Artifact landed: $watch"
      cat "$watch"
      exit 0
    fi
    sleep 3
  done
  warn "TIMEOUT after ${timeout}s - $watch never appeared."
  if [ -n "$agent" ]; then
    say "Last 30 lines from the $agent pane:"
    tmux capture-pane -t "$(pane_for "$agent")" -p | tail -30
  fi
  exit 2
}

# ============================================================== BUS ==========
cmd_bus() {
  load_state
  find "$WORKSPACE/.relay" -type f -not -path '*/launch/*' -exec ls -lt {} + 2>/dev/null |
    awk -v ws="$WORKSPACE" '{ $1=$2=$3=$4=$5=""; sub("^ +",""); sub(ws,""); print }'
}

# =========================================================== ATTACH ==========
cmd_attach() {
  say "Run this in your own terminal (cannot attach from a tool call):"
  printf '    tmux attach -t %s\n' "$SESSION"
}

# ============================================================= MAIN ==========
need_tmux
sub="${1:-status}"; shift || true
case "$sub" in
  up)       cmd_up       "$@" ;;
  down)     cmd_down     "$@" ;;
  status)   cmd_status   "$@" ;;
  send)     cmd_send     "$@" ;;
  dispatch) cmd_dispatch "$@" ;;
  capture)  cmd_capture  "$@" ;;
  wait)     cmd_wait     "$@" ;;
  bus)      cmd_bus      "$@" ;;
  attach)   cmd_attach   "$@" ;;
  -h|--help|help) usage ;;
  *) usage; fail "Unknown subcommand: $sub" ;;
esac
