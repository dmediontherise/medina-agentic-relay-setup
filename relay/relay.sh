#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Medina Agentic Relay - tmux control plane (macOS / Linux).
#
# Opus (orchestrator) drives three Antigravity panes - executor, scout and
# mutator - plus an Opus validator, as live tmux panes. Content moves over a
# file bus (.relay/) so results are clean and lossless; tmux provides process
# persistence, liveness, and the ability to send follow-up instructions into a
# running agent.
#
# The validator is the only Claude pane. Executor, scout and mutator all run
# Antigravity CLI and spend no Claude quota, so evidence gathering is free and
# deliberately deep (re-run, probe, assertion audit, mutation); the scout
# compacts that depth into a capped evidence file so the one paid pane reads
# findings, not raw log volume.
#
# This is the POSIX counterpart to relay.ps1. Same subcommands, same bus
# layout, same charters - so a task file written on one platform runs on the
# other unchanged.
#
# Portability notes: written for bash 3.2 (macOS system bash) - no associative
# arrays, no `mapfile`. Uses only tmux, git, ps and coreutils.
# ---------------------------------------------------------------------------
set -euo pipefail

RELAY_HOME="${RELAY_HOME:-$HOME/.claude/relay}"
STATE_FILE="$RELAY_HOME/state"
SESSION="${RELAY_SESSION:-relay}"

ALL_AGENTS="executor validator scout mutator"

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

save_state() {
  cat > "$STATE_FILE" <<EOF
SESSION="$SESSION"
WORKSPACE="$WORKSPACE"
EXECUTOR_PANE="$EXECUTOR_PANE"
VALIDATOR_PANE="$VALIDATOR_PANE"
SCOUT_PANE="$SCOUT_PANE"
MUTATOR_PANE="$MUTATOR_PANE"
BUS_PANE="$BUS_PANE"
SAFE="$SAFE"
CREATED="$CREATED"
L_EXECUTOR="$L_EXECUTOR"
L_VALIDATOR="$L_VALIDATOR"
L_SCOUT="$L_SCOUT"
L_MUTATOR="$L_MUTATOR"
BOOT_EXECUTOR="$BOOT_EXECUTOR"
BOOT_VALIDATOR="$BOOT_VALIDATOR"
BOOT_SCOUT="$BOOT_SCOUT"
BOOT_MUTATOR="$BOOT_MUTATOR"
EOF
}

pane_for() {
  case "$1" in
    executor)  printf '%s' "${EXECUTOR_PANE:-}"  ;;
    validator) printf '%s' "${VALIDATOR_PANE:-}" ;;
    scout)     printf '%s' "${SCOUT_PANE:-}"     ;;
    mutator)   printf '%s' "${MUTATOR_PANE:-}"   ;;
    *) fail "Unknown agent '$1'. Use executor, scout, mutator or validator." ;;
  esac
}

# The agent's own executable, used to tell a live pane from a dead one. See
# agent_process_alive.
agent_proc_name() {
  case "$1" in
    validator) printf 'claude' ;;
    *)         printf 'agy' ;;
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

bus_artifact() { printf '%s/.relay/%s/%s.md' "$WORKSPACE" "$1" "$2"; }

make_bus_dirs() {
  # 'probe' is the scout's sanctioned scratch area. 'mutants' holds one isolated
  # snapshot of the workspace per task and 'mutation' the mutator's findings -
  # that snapshot is what keeps the mutation lane off the critical path, since
  # the mutator can rewrite source in its own copy while the executor is already
  # editing the real tree for the next task.
  mkdir -p "$1/.relay"/{tasks,results,evidence,reports,logs,launch,probe,mutants,mutation}
}

# --- pane state classification ---------------------------------------------
#
# Everything below exists because a pane that has stopped working looks EXACTLY
# like a healthy idle one. Never infer health from the idle chrome: match faults
# explicitly, and prove liveness by making the agent answer.

# Panes are tiled and therefore narrow, so a banner may be hard-wrapped mid-word.
# A wrap either replaces a space with a newline or splits a word - test the raw
# text, the text with newlines removed, and the text with whitespace collapsed.
pane_match() {
  local txt="$1" pat="$2"
  printf '%s' "$txt" | grep -qiE "$pat" && return 0
  printf '%s' "$txt" | tr -d '\n' | grep -qiE "$pat" && return 0
  printf '%s' "$txt" | tr -s '[:space:]' ' ' | grep -qiE "$pat" && return 0
  return 1
}

pane_text() {
  tmux capture-pane -t "$1" -p 2>/dev/null | tail -n "${2:-40}" || true
}

BOOTED_PAT='READY|\? for shortcuts|shift\+tab to cycle|bypass permissions on|accept edits on'
# Match ONLY interrupt hints shown while actually running. Do not match completed-step
# summaries like "Cogitated" - those stay on screen forever, so an idle pane would read
# as permanently busy and health could never look at it again.
BUSY_PAT='esc to cancel|esc to interrupt|ctrl\+c to (stop|cancel)|Running\.\.\.|Running…|Cogitating|Thinking…'

# Blocking modals we know how to clear. Each swallows input, so a dispatched
# instruction is absorbed and never acted on.
clear_blocking_prompts() {
  local target="$1" txt
  txt="$(pane_text "$target")"
  if pane_match "$txt" 'trust (the contents of this|this folder)'; then
    tmux send-keys -t "$target" Enter; sleep 0.6; printf 'folder-trust prompt'; return 0
  fi
  # agy periodically asks for CLI feedback; it blocks the input line exactly like
  # the trust gate does.
  if pane_match "$txt" "How's the CLI experience so far"; then
    tmux send-keys -t "$target" 0; sleep 0.6; printf 'agy feedback survey'; return 0
  fi
  return 0
}

# Faults no keystroke fixes - these need the process restarted.
pane_fault() {
  local target="$1" txt
  txt="$(pane_text "$target")"
  # agy's OAuth access token can refresh into a state the server rejects, after
  # which every request 401s forever. It never self-heals and afterwards the pane
  # drops back to a normal-looking idle prompt.
  pane_match "$txt" 'Agent execution terminated due to error' && { printf 'agy agent fault (usually a wedged OAuth token)'; return 0; }
  pane_match "$txt" 'UNAUTHENTICATED|invalid authentication credentials' && { printf 'expired/rejected credentials'; return 0; }
  pane_match "$txt" '/rate-limit-options|usage limit reached|Claude usage limit' && { printf 'Claude rate limit'; return 0; }
  pane_match "$txt" 'Please run /login|Invalid API key|not authenticated' && { printf 'agent is signed out'; return 0; }
  return 0
}

pane_busy() { pane_match "$(pane_text "$1")" "$BUSY_PAT"; }

pane_pid_of() {
  local pane_id="$1" row
  row="$(tmux list-panes -t "$SESSION:agents" -F '#{pane_id} #{pane_pid}' 2>/dev/null | grep -E "^${pane_id} " || true)"
  [ -n "$row" ] || return 1
  printf '%s' "${row##* }"
}

# --- process-level liveness -------------------------------------------------
#
# The classification above reads the SCREEN. That misses the failure where the
# agent process simply exits: panes are launched so a crash stays inspectable,
# which means the pane survives as a bare shell. A bare prompt matches no fault
# pattern, shows no busy hint and prints nothing alarming - invisible to every
# check above.
#
# tmux cannot help: '#{pane_current_command}' reports the pane's root process,
# which for a launcher-script pane is the shell, not the agent. What works is
# '#{pane_pid}' plus a walk of that pid's descendants looking for the agent's
# own executable (it sits below the launcher shell).
agent_process_alive() {
  local agent="$1" want pane_id root table
  pane_id="$(pane_for "$agent")"
  [ -n "$pane_id" ] || return 1
  want="$(agent_proc_name "$agent")"
  root="$(pane_pid_of "$pane_id" || true)"
  [ -n "$root" ] || return 1

  table="$(ps -eo pid=,ppid=,comm= 2>/dev/null || true)"
  # If we cannot read the process table at all, never report a false crash.
  [ -n "$table" ] || return 0

  printf '%s\n' "$table" | awk -v root="$root" -v want="$want" '
    { p=$1; pp[p]=$2; cm[p]=$3; all[n++]=p }
    END {
      qn=0; q[qn++]=root; seen[root]=1
      for (i=0; i<qn; i++) {
        for (j=0; j<n; j++) {
          c=all[j]
          if (pp[c]==q[i] && !(c in seen)) {
            if (index(cm[c], want) > 0) exit 0
            seen[c]=1; q[qn++]=c
          }
        }
      }
      exit 1
    }'
}

# One call answering "can I hand this agent work right now?" - screen faults,
# blocking modals and a dead process in one place. Prints the reason it cannot,
# or nothing when the agent looks usable.
agent_trouble() {
  local agent="$1" target f
  target="$(pane_for "$agent")"
  if [ -z "$target" ]; then
    printf "no pane for '%s' - this relay was started before that agent existed" "$agent"; return 0
  fi
  clear_blocking_prompts "$target" >/dev/null
  f="$(pane_fault "$target")"
  if [ -n "$f" ]; then printf '%s' "$f"; return 0; fi
  if ! agent_process_alive "$agent"; then
    printf '%s is not running - the agent exited and left a bare shell' "$(agent_proc_name "$agent")"
    return 0
  fi
  return 0
}

# The only check that distinguishes a working agent from a wedged one: make it
# say something new.
#
# The expected answer is never written into the prompt we send. The pane echoes
# whatever we type, and a pane that has dropped to a bare shell echoes it again
# inside a "command not found" error - so any probe whose answer appears in its
# own question can be passed by something that is not an agent at all. Here the
# two halves are only ever adjacent in a real reply.
agent_responsive() {
  local target="$1" timeout="${2:-75}" nonce expect deadline txt
  nonce="$(date +%s | tail -c 7)$$"; nonce="$(printf '%s' "$nonce" | tr -dc '0-9' | tail -c 6)"
  expect="RELAYOK$nonce"
  send_line "$target" "Reply with the word RELAYOK immediately followed by $nonce as one word, nothing else. Do not use any tools."
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 3
    txt="$(pane_text "$target" 60)"
    printf '%s' "$txt" | grep -q "$expect" && return 0
    [ -n "$(pane_fault "$target")" ] && return 1
  done
  return 1
}

wait_pane_booted() {
  local target="$1" timeout="${2:-90}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(pane_fault "$target")" ] && return 1
    pane_match "$(pane_text "$target")" "$BOOTED_PAT" && return 0
    sleep 3
  done
  return 1
}

clear_trust_prompts() {
  local targets="$1" timeout="${2:-90}" deadline pending still p cleared
  deadline=$(( $(date +%s) + timeout ))
  pending="$targets"
  while [ -n "$(printf '%s' "$pending" | tr -d ' ')" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 3
    still=""
    for p in $pending; do
      cleared="$(clear_blocking_prompts "$p")"
      if [ -n "$cleared" ]; then
        say "Cleared $cleared in pane $p"
      elif pane_match "$(pane_text "$p")" "$BOOTED_PAT"; then
        : # past the gate
      elif [ -n "$(pane_fault "$p")" ]; then
        : # already broken; waiting out the deadline only delays the diagnosis
      else
        still="$still $p"
      fi
    done
    pending="$still"
  done
}

usage() {
  cat <<'EOF'
Medina Agentic Relay - tmux control plane

  relay.sh new  <project-name|path>         Scaffold a project, then bring the relay up on it
  relay.sh up   [-w <workspace>] [--safe]   Build the session and boot the agents
  relay.sh down                             Tear the session down
  relay.sh status                           Session state, pane list, bus contents
  relay.sh health   [-a <agent>] [--deep]   Prove each agent still answers
  relay.sh restart  -a <agent|all>          Respawn a wedged or crashed pane in place
  relay.sh send     -a <agent> -t <text>    Type a line into a running agent
  relay.sh dispatch -a <agent> -T <task.md> Hand a task file to an agent
  relay.sh capture  -a <agent> [-n 60]      Print the tail of a pane
  relay.sh wait     -f <artifact> [-a <agent>] [--timeout 900]
  relay.sh snapshot -T <task.md>            Freeze the workspace for a mutation pass
  relay.sh autopilot [options]              Run the whole queue unattended
  relay.sh bus                              List artifacts on the file bus
  relay.sh attach                           Print the attach command

  agents: executor | validator | scout | mutator

  autopilot options:
    --budget-min N          wall-clock cap for the run           (default 480)
    --max-cycles N          task cycles in one run               (default 24)
    --max-fails N           consecutive FAILs before stopping    (default 3)
    --mutation-drain-min N  wait for late mutation reports       (default 20)
    --no-mutation           skip the mutation lane entirely
EOF
}

# ============================================================== NEW ==========
cmd_new() {
  local name="${1:-}"
  [ -n "$name" ] || fail "Usage: relay.sh new <project-name|path>"

  local target="$name"
  case "$target" in /*) ;; *) target="$PWD/$name" ;; esac

  # Never scaffold over existing work. An empty directory is fine to adopt.
  if [ -e "$target" ]; then
    if [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
      fail "$target already exists and is not empty. Use 'up -w \"$target\"' to run the relay on it as-is."
    fi
  else
    mkdir -p "$target"
  fi
  target="$(cd "$target" && pwd)"
  local proj; proj="$(basename "$target")"
  say "Created  $target"

  # The scout reads 'git diff' as its primary evidence, and the mutator needs a
  # repo to build its isolated worktree from, so git is not optional here.
  command -v git >/dev/null 2>&1 || warn "git not found. The scout falls back to file listings, and the mutator falls back to copying the tree."

  cat > "$target/.gitignore" <<'EOF'
# Relay coordination bus - artifacts stay on disk, out of version control
.relay/

# Editors / OS
.vscode/
.idea/
.DS_Store
Thumbs.db

# Common build & dependency output
node_modules/
dist/
build/
target/
__pycache__/
*.py[cod]
.venv/
venv/

# Logs & local env
*.log
.env
.env.local
EOF

  cat > "$target/README.md" <<EOF
# $proj

Worked on with the [Medina Agentic Relay](https://github.com/dmediontherise/medina-agentic-relay-setup).

## Relay

\`\`\`
relay.sh status                 # session state and bus contents
relay.sh health                 # prove each agent still answers
relay.sh autopilot              # run the whole queue unattended
relay.sh down                   # tear it down
\`\`\`

Task specs live in \`.relay/tasks/\`. Verdicts land in \`.relay/reports/\`.
EOF

  if command -v git >/dev/null 2>&1; then
    ( cd "$target" && git init -q && git add -A ) || true
    if ( cd "$target" && git commit -q -m "Initial commit" >/dev/null 2>&1 ); then
      say "git init + initial commit"
    else
      warn "git commit failed - repo initialized but nothing committed. Check: git config --global user.email"
    fi
  fi

  make_bus_dirs "$target"
  cat > "$target/.relay/tasks/001-first-task.md" <<'EOF'
# Task 001: <title>

## Objective
<What "done" means, in one or two sentences.>

## Scope
- In:  <files or areas the executor may touch>
- Out: <explicitly off-limits>

## Requirements
<Numbered and individually verifiable. The validator grades against THIS
file, so anything vague here produces a worthless verdict. Write them so
someone who did not read this conversation could check them.>

1.
2.

## Verification
<Commands that must pass, with the expected outcome. The scout re-runs
every one of these itself rather than trusting the executor.

Each command must be a SINGLE LINE that runs as written. The executor
rewrites commands it cannot run and then reports the result it expected
rather than the one it observed - so no try/except, if or for after a
semicolon in a `python -c`. Prefer exact stdout, an assert one-liner, or
pushing the assertion into the test suite and verifying with `pytest -q`.>

- `<command>` -> <expected>

## Artifacts
- results:  `.relay/results/001-first-task.md`
- evidence: `.relay/evidence/001-first-task.md`
- report:   `.relay/reports/001-first-task.md`
EOF
  say "Seeded   .relay/tasks/001-first-task.md"

  cmd_up -w "$target"
  printf '\n  \033[1mNext:\033[0m\n'
  printf '    1. Fill in .relay/tasks/001-first-task.md (requirements + verification)\n'
  printf '    2. Run /relay-task in Claude Code from %s, or /relay-auto for the whole queue\n' "$target"
}

# =============================================================== UP ==========
cmd_up() {
  local workspace="" safe=0 deep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -w|--workspace) workspace="$2"; shift 2 ;;
      --safe) safe=1; shift ;;
      --deep) deep=1; shift ;;
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
  make_bus_dirs "$workspace"

  for c in $ALL_AGENTS; do
    [ -f "$RELAY_HOME/charters/$c.md" ] && cp -f "$RELAY_HOME/charters/$c.md" "$workspace/.relay/$c.md"
  done

  local agy_exe claude_exe
  agy_exe="$(command -v agy || true)"
  [ -z "$agy_exe" ] && [ -x "$HOME/.local/bin/agy" ] && agy_exe="$HOME/.local/bin/agy"
  claude_exe="$(command -v claude || true)"
  [ -z "$claude_exe" ] && [ -x "$HOME/.local/bin/claude" ] && claude_exe="$HOME/.local/bin/claude"

  if [ -z "$agy_exe" ]; then
    warn "'agy' (Antigravity CLI) not found - the agy panes will not start."
    warn "Install: curl -fsSL https://antigravity.google/cli/install.sh | sh"
    agy_exe="agy"
  fi
  if [ -z "$claude_exe" ]; then
    warn "'claude' not found - the validator will not start."
    claude_exe="claude"
  fi
  say "agy    bin   : $agy_exe   (executor + scout + mutator)"
  say "claude bin   : $claude_exe   (validator)"

  local launch="$workspace/.relay/launch"
  local agy_model="gemini-3.6-flash-high"
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

  local exec_boot val_boot scout_boot mut_boot
  exec_boot="Read .relay/executor.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for task files."
  val_boot="Read .relay/validator.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for evidence files to grade."
  scout_boot="Read .relay/scout.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for result files to gather evidence on."
  mut_boot="Read .relay/mutator.md and follow it as your operating contract for this session. Reply READY when loaded, then wait to be pointed at a mutation snapshot."

  # The mutator exists as its own pane for one reason: mutation testing is slow
  # (minutes to tens of minutes) and the relay cannot hold the validator behind
  # it. A pane does one thing at a time, so giving mutation work to the primary
  # scout would serialise it into the critical path - which is exactly what a
  # second free agy pane buys us out of. It runs against a frozen snapshot in
  # .relay/mutants/<task>/, so it can still be grinding on task 007 while the
  # executor edits the real tree for task 008.
  local l_exec l_val l_scout l_mut l_bus
  l_exec="$(write_launcher executor  "$(printf 'exec %q --add-dir %q --model %s %s -i %q' "$agy_exe" "$workspace" "$agy_model" "$exec_flags" "$exec_boot")")"
  l_val="$(write_launcher  validator "$(printf 'exec %q --model opus --permission-mode %s %q' "$claude_exe" "$claude_mode" "$val_boot")")"
  l_scout="$(write_launcher scout    "$(printf 'exec %q --add-dir %q --model %s %s -i %q' "$agy_exe" "$workspace" "$agy_model" "$exec_flags" "$scout_boot")")"
  l_mut="$(write_launcher  mutator   "$(printf 'exec %q --add-dir %q --model %s %s -i %q' "$agy_exe" "$workspace" "$agy_model" "$exec_flags" "$mut_boot")")"
  l_bus="$(write_launcher  buswatch  'while true; do clear; printf "== RELAY BUS ==\n\n"; find .relay -type f -name "*.md" -not -path "*/launch/*" -exec ls -lt {} + 2>/dev/null | head -14; sleep 3; done')"

  say "Building session '$SESSION' in $workspace"

  tmux new-session -d -s "$SESSION" -n agents -c "$workspace" "$l_exec"
  sleep 1
  # Re-tile after EVERY split, not once at the end. Each split halves the pane it
  # targets, so splitting five ways in a row runs the last one out of rows - which
  # is how the fifth pane silently failed to exist when this went from four panes
  # to five. Tiling between splits keeps every pane large enough to split again.
  for l in "$l_val" "$l_scout" "$l_mut" "$l_bus"; do
    tmux split-window -t "$SESSION:agents" -c "$workspace" "$l"
    sleep 1
    tmux select-layout -t "$SESSION:agents" tiled
    sleep 0.3
  done
  sleep 0.5

  local ids
  ids="$(tmux list-panes -t "$SESSION:agents" -F '#{pane_index} #{pane_id}' | sort -n | awk '{print $2}')"
  [ "$(printf '%s\n' "$ids" | wc -l)" -ge 5 ] || fail "Expected 5 panes, got $(printf '%s\n' "$ids" | wc -l)."

  WORKSPACE="$workspace"
  EXECUTOR_PANE="$(printf  '%s\n' "$ids" | sed -n 1p)"
  VALIDATOR_PANE="$(printf '%s\n' "$ids" | sed -n 2p)"
  SCOUT_PANE="$(printf     '%s\n' "$ids" | sed -n 3p)"
  MUTATOR_PANE="$(printf   '%s\n' "$ids" | sed -n 4p)"
  BUS_PANE="$(printf       '%s\n' "$ids" | sed -n 5p)"
  SAFE="$safe"
  CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  L_EXECUTOR="$l_exec"; L_VALIDATOR="$l_val"; L_SCOUT="$l_scout"; L_MUTATOR="$l_mut"
  local now; now="$(date +%s)"
  BOOT_EXECUTOR="$now"; BOOT_VALIDATOR="$now"; BOOT_SCOUT="$now"; BOOT_MUTATOR="$now"
  save_state

  say "Waiting for agents to boot and clearing startup prompts..."
  clear_trust_prompts "$EXECUTOR_PANE $VALIDATOR_PANE $SCOUT_PANE $MUTATOR_PANE"

  # Do not report a relay as up on the strength of the panes existing. Every
  # silent failure this relay has had looked fine at exactly this point.
  say "Verifying each agent answers..."
  local bad="" n t
  for n in $ALL_AGENTS; do
    t="$(pane_for "$n")"
    if [ -n "$(pane_fault "$t")" ]; then bad="$bad $n"; continue; fi
    # The validator is Claude and every probe costs quota, so it gets the cheap
    # passive check unless --deep is asked for. The agy panes are free: probe them.
    if [ "$n" = "validator" ] && [ "$deep" -eq 0 ]; then
      if wait_pane_booted "$t"; then say "  $n : booted (passive check - pass --deep to probe it)"
      else bad="$bad $n"; fi
      continue
    fi
    if agent_responsive "$t"; then say "  $n : responding"; else bad="$bad $n"; fi
  done

  if [ -n "$(printf '%s' "$bad" | tr -d ' ')" ]; then
    printf '\n\033[31m[relay] RELAY IS NOT HEALTHY - do not dispatch work yet:%s\033[0m\n' "$bad"
    printf '\033[33m        Inspect: relay.sh capture -a <name>\n        Recover: relay.sh restart -a <name>\033[0m\n'
    exit 3
  fi

  say "Relay up - all four agents answered."
  say "  executor  (agy / $agy_model) -> $EXECUTOR_PANE"
  say "  validator (claude opus)                  -> $VALIDATOR_PANE"
  say "  scout     (agy / $agy_model) -> $SCOUT_PANE"
  say "  mutator   (agy / $agy_model) -> $MUTATOR_PANE"
  say "  bus watch                                -> $BUS_PANE"
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

  local d n f
  for d in tasks results evidence reports mutation; do
    n="$(find "$WORKSPACE/.relay/$d" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '        %s: %s artifact(s)\n' "$d" "$n"
    find "$WORKSPACE/.relay/$d" -maxdepth 1 -type f 2>/dev/null | head -3 | while read -r f; do
      printf '            - %s\n' "$(basename "$f")"
    done
  done

  # A result with no evidence means the scout was skipped or broken - the exact
  # silent degradation that once had Opus doing the scout's work for six cycles.
  local missing=""
  for f in "$WORKSPACE/.relay/results/"*.md; do
    [ -f "$f" ] || continue
    [ -f "$WORKSPACE/.relay/evidence/$(basename "$f")" ] || missing="$missing $(basename "$f" .md)"
  done
  if [ -n "$(printf '%s' "$missing" | tr -d ' ')" ]; then
    printf '\033[33m        WARNING: task(s) have results but NO scout evidence:%s\n' "$missing"
    printf '                 Check the scout: relay.sh health -a scout\033[0m\n'
  fi

  # Long-lived agy panes have wedged their OAuth token before (~12h uptime).
  if [ -n "${BOOT_SCOUT:-}" ]; then
    local hrs; hrs=$(( ( $(date +%s) - BOOT_SCOUT ) / 3600 ))
    if [ "$hrs" -gt 8 ]; then
      printf '\033[33m        NOTE: agy panes have been up %sh. restart -a all is cheap insurance.\033[0m\n' "$hrs"
    fi
  fi
  printf '\033[90m        Agent liveness is NOT checked here - run: relay.sh health\033[0m\n'
}

# =========================================================== HEALTH ==========
# The check 'status' could never do. 'status' proves panes exist; this proves the
# agents in them still work. Exits non-zero when any agent is unhealthy so a
# caller cannot skim past a dead lane.
cmd_health() {
  local only="" deep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--agent) only="$2"; shift 2 ;;
      --deep) deep=1; shift ;;
      *) fail "Unknown option for health: $1" ;;
    esac
  done
  load_state
  tmux has-session -t "$SESSION" 2>/dev/null || { printf '\033[31m[relay] DOWN - no tmux session.\033[0m\n'; exit 1; }

  local names="$ALL_AGENTS"
  [ -n "$only" ] && [ "$only" != "all" ] && names="$only"

  local unhealthy=0 n t age boot cleared f
  for n in $names; do
    t="$(pane_for "$n")"
    if [ -z "$t" ]; then
      printf '  %-10s \033[33mABSENT - this relay predates the %s pane. Rebuild: relay.sh down && relay.sh up\033[0m\n' "$n" "$n"
      unhealthy=$((unhealthy+1)); continue
    fi
    eval "boot=\${BOOT_$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]'):-}"
    age=""
    [ -n "$boot" ] && age=" (up $(( ( $(date +%s) - boot ) / 3600 ))h)"

    cleared="$(clear_blocking_prompts "$t")"
    [ -n "$cleared" ] && printf '  %-10s \033[33mBLOCKED -> cleared %s\033[0m\n' "$n" "$cleared"

    f="$(pane_fault "$t")"
    if [ -n "$f" ]; then
      printf '  %-10s \033[31mFAULT: %s%s\033[0m\n             recover with: relay.sh restart -a %s\n' "$n" "$f" "$age" "$n"
      unhealthy=$((unhealthy+1)); continue
    fi

    # Checked before the busy test on purpose: a dead agent's pane is not busy and
    # not faulted, so without this it falls through to the probe and merely looks
    # slow. This is the check that names it as a crash.
    if ! agent_process_alive "$n"; then
      printf '  %-10s \033[31mCRASHED - %s is not running in that pane%s\033[0m\n             the pane survived as a bare shell; recover with: relay.sh restart -a %s\n' \
        "$n" "$(agent_proc_name "$n")" "$age" "$n"
      unhealthy=$((unhealthy+1)); continue
    fi

    if pane_busy "$t"; then
      printf '  %-10s \033[36mBUSY (working - not probed)%s\033[0m\n' "$n" "$age"; continue
    fi

    if [ "$n" = "validator" ] && [ "$deep" -eq 0 ]; then
      if pane_match "$(pane_text "$t")" "$BOOTED_PAT"; then
        printf '  %-10s \033[90mIDLE at its prompt, no fault detected%s  (pass --deep to probe it - costs Claude quota)\033[0m\n' "$n" "$age"
      else
        printf '  %-10s \033[33mNOT AT ITS PROMPT - neither booted nor faulted%s\033[0m\n' "$n" "$age"
        unhealthy=$((unhealthy+1))
      fi
      continue
    fi

    if agent_responsive "$t"; then
      printf '  %-10s \033[32mOK - answered%s\033[0m\n' "$n" "$age"
    else
      printf '  %-10s \033[31mUNRESPONSIVE - no answer to a liveness probe%s\033[0m\n             recover with: relay.sh restart -a %s\n' "$n" "$age" "$n"
      unhealthy=$((unhealthy+1))
    fi
  done

  if [ "$unhealthy" -gt 0 ]; then
    printf '\033[31m[relay] %s agent(s) unhealthy.\033[0m\n' "$unhealthy"; exit 1
  fi
  say "All checked agents healthy."
}

# ========================================================== RESTART ==========
# A wedged agy pane is fixed by restarting that process and nothing else - its
# credentials are re-read clean at startup. Restarting only the broken pane keeps
# the other agents' conversation context, which a full down/up throws away.
#
# Do NOT reach for 'respawn-pane'. Use kill-pane + split-window: the new pane
# becomes active, so its id can be read straight back off the window.
restart_agents() {
  local names="$1" deep="${2:-0}" win="$SESSION:agents" targets="" n launcher old new
  for n in $names; do
    eval "launcher=\${L_$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]'):-}"
    [ -n "$launcher" ] && [ -f "$launcher" ] || fail "Launcher for '$n' is missing. Run 'down' then 'up'."

    old="$(pane_for "$n")"
    if [ -n "$old" ]; then tmux kill-pane -t "$old" 2>/dev/null || true; sleep 0.8; fi
    tmux split-window -t "$win" -c "$WORKSPACE" "$launcher"
    sleep 1.5
    new="$(tmux display-message -p -t "$win" '#{pane_id}')"
    [ -n "$new" ] || fail "Could not resolve the new pane id for '$n'."

    case "$n" in
      executor)  EXECUTOR_PANE="$new" ;;
      validator) VALIDATOR_PANE="$new" ;;
      scout)     SCOUT_PANE="$new" ;;
      mutator)   MUTATOR_PANE="$new" ;;
    esac
    eval "BOOT_$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')=$(date +%s)"
    say "Restarted $n -> $new"
    targets="$targets $new"
  done

  tmux select-layout -t "$win" tiled
  save_state

  say "Waiting for restarted agents to boot..."
  sleep 5
  clear_trust_prompts "$targets"

  # Always PROBE after a restart, validator included - never accept the passive
  # "reached its prompt" check here. The quota argument for passive-checking the
  # validator applies to routine polling, not to a restart: a restart exists to
  # establish that a broken agent works again, and one probe is a negligible
  # price for that answer. Skipping it reports success on exactly the case you
  # restarted to fix - observed on a long-lived validator pane that came back
  # "booted" and then silently swallowed every message sent to it. If a restart
  # does not fix an agent, go to down/up rather than restarting the pane again.
  RESTART_BAD=""
  local i=0
  for n in $names; do
    i=$((i+1))
    local tgt; tgt="$(printf '%s' "$targets" | awk -v k="$i" '{print $k}')"
    if agent_responsive "$tgt"; then say "  $n : responding"; else RESTART_BAD="$RESTART_BAD $n"; fi
  done
}

cmd_restart() {
  local agent=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--agent) agent="$2"; shift 2 ;;
      --deep) shift ;;
      *) fail "Unknown option for restart: $1" ;;
    esac
  done
  [ -n "$agent" ] || fail "-a <executor|scout|mutator|validator|all> required"
  load_state
  local names="$ALL_AGENTS"
  [ "$agent" != "all" ] && names="$agent"
  restart_agents "$names"
  if [ -n "$(printf '%s' "$RESTART_BAD" | tr -d ' ')" ]; then
    printf '\033[31m[relay] still unhealthy after restart:%s\033[0m\n' "$RESTART_BAD"
    printf '\033[33m        Inspect with: relay.sh capture -a <name>\033[0m\n'
    exit 1
  fi
  say "Restart complete - agents responding."
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
dispatch_message() {
  local agent="$1" rel="$2" base="$3"
  case "$agent" in
    scout)     printf 'Gather evidence for: %s . Follow your contract in .relay/scout.md - re-run the verification yourself, probe the edge cases the task implies, audit the tests for real assertions, and write the compacted evidence file named in the task. Do NOT do mutation testing; the mutator pane owns that. Observations only, no verdict.' "$rel" ;;
    mutator)   printf 'Mutation pass for: %s . Follow your contract in .relay/mutator.md . Your isolated snapshot of the workspace is at .relay/mutants/%s/ - do all mutation work in there and never in the live tree. Write findings to .relay/mutation/%s.md . Surviving mutants only, no verdict.' "$rel" "$base" "$base" ;;
    validator) printf 'Grade this task: %s . Follow your contract in .relay/validator.md - read the task, the executor result, the scout evidence, and the mutation report at .relay/mutation/%s.md if it exists, then write your verdict to the report path named in the task.' "$rel" "$base" ;;
    *)         printf 'New task on the bus: %s . Read it, execute it per your contract in .relay/executor.md, and write your completion report to the results path named in the task.' "$rel" ;;
  esac
}

# Returns 0 on success; prints the fault and returns 1 when the lane is broken.
# Check the lane before shouting down it: a faulted pane accepts send-keys
# silently, so without this the dispatch "succeeds" and the caller waits out a
# full timeout on an agent that died hours ago.
do_dispatch() {
  local agent="$1" abs="$2" note="${3:-}" rel base target cleared f msg
  rel="${abs#"$WORKSPACE"/}"
  base="$(basename "$abs" .md)"
  target="$(pane_for "$agent")"
  cleared="$(clear_blocking_prompts "$target")"
  [ -n "$cleared" ] && say "Cleared $cleared in $agent before dispatching"
  f="$(pane_fault "$target")"
  if [ -n "$f" ]; then printf '%s' "$f"; return 1; fi
  msg="$(dispatch_message "$agent" "$rel" "$base")"
  [ -n "$note" ] && msg="$msg $note"
  send_line "$target" "$msg"
  say "Dispatched $rel -> $agent"
  return 0
}

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
  local abs; abs="$(bus_path "$task")"
  [ -f "$abs" ] || fail "Task file not found: $abs"
  local f
  if ! f="$(do_dispatch "$agent" "$abs")"; then
    printf '\033[31m[relay] REFUSING TO DISPATCH - %s has faulted: %s\033[0m\n' "$agent" "$f"
    printf '\033[33m        Recover with: relay.sh restart -a %s\033[0m\n' "$agent"
    exit 3
  fi
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
cmd_wait() {
  local file="" agent="" timeout=900
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--file)  file="$2";    shift 2 ;;
      -a|--agent) agent="$2";   shift 2 ;;
      --timeout)  timeout="$2"; shift 2 ;;
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
      sleep 0.7
      say "Artifact landed: $watch"
      cat "$watch"
      exit 0
    fi
    sleep 3
  done
  warn "TIMEOUT after ${timeout}s - $watch never appeared."

  # A timeout is the moment to say WHY. Treating it as "the model is slow" is what
  # once let a dead scout be quietly written out of the loop for six task cycles.
  if [ -n "$agent" ]; then
    local t f; t="$(pane_for "$agent")"; f="$(pane_fault "$t")"
    if [ -n "$f" ]; then
      printf '\033[31m[relay] CAUSE: %s has faulted: %s\033[0m\n' "$agent" "$f"
      printf '\033[33m        This does not recover on its own:\n            relay.sh restart -a %s\n            relay.sh dispatch -a %s -T <task file>\033[0m\n' "$agent" "$agent"
    elif pane_busy "$t"; then
      warn "$agent is still working - consider a longer --timeout."
    else
      warn "$agent is idle with no artifact written - it may have missed the dispatch."
    fi
    say "Last 30 lines from the $agent pane:"
    tmux capture-pane -t "$t" -p | tail -30
  fi
  exit 2
}

# ========================================================= SNAPSHOT ==========
# Freeze the workspace as it stands right now into .relay/mutants/<task>/, so the
# mutator can rewrite source without touching the tree the executor works in.
#
# This is the whole basis of "mutation does not slow anything down": the snapshot
# costs seconds and is taken at the one moment nothing is being written - just
# after the executor's result lands - after which the mutator grinds for as long
# as it needs while the rest of the relay moves on.
#
# Dependency directories are symlinked, not copied: node_modules is routinely
# larger than everything else combined, and a mutation run that spends four
# minutes copying it before it starts is one nobody will leave enabled.
new_mutant_snapshot() {
  local base="$1" ws="$WORKSPACE" dest method="copy" stash u dep
  dest="$ws/.relay/mutants/$base"

  if [ -e "$dest" ]; then
    git -C "$ws" worktree remove --force "$dest" >/dev/null 2>&1 || true
    rm -rf "$dest"
    git -C "$ws" worktree prune >/dev/null 2>&1 || true
  fi

  if command -v git >/dev/null 2>&1 &&
     git -C "$ws" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
     git -C "$ws" rev-parse --verify HEAD >/dev/null 2>&1 &&
     git -C "$ws" worktree add --detach "$dest" HEAD >/dev/null 2>&1; then
    method="worktree"

    # A worktree checks out HEAD, but the work being mutated is usually still
    # uncommitted - so carry the working tree over too. 'stash create' builds a
    # commit object for the current tree without touching the tree or the stash
    # list. Done as a patch file instead, this breaks on binary hunks.
    #
    # DO NOT "improve" this to leave the index alone. Staging the carried-over
    # state is what makes the mutator's restore step correct: its charter has it
    # revert each mutant with `git checkout <file>`, which restores from the
    # INDEX. With the task's changes staged that reverts the mutation and keeps
    # the work under test; if the index still matched HEAD, the same command
    # would throw away the change being mutation-tested, and every mutant after
    # the first would apply to the pre-task baseline.
    stash="$(git -C "$ws" stash create 2>/dev/null || true)"
    if [ -n "$stash" ]; then
      git -C "$dest" checkout "$stash" -- . >/dev/null 2>&1 ||
        warn "could not replay uncommitted changes into the snapshot - mutation runs against HEAD."
    fi

    # --exclude-standard keeps .relay/ and other ignored paths out, which is what
    # we want: the bus must not be duplicated into the snapshot.
    git -C "$ws" ls-files --others --exclude-standard 2>/dev/null | while read -r u; do
      [ -f "$ws/$u" ] || continue
      mkdir -p "$dest/$(dirname "$u")"
      cp -f "$ws/$u" "$dest/$u" 2>/dev/null || true
    done
  else
    mkdir -p "$dest"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --exclude '.git' --exclude '.relay' --exclude 'node_modules' \
            --exclude '.venv' --exclude 'venv' --exclude '__pycache__' \
            --exclude 'dist' --exclude 'build' --exclude 'target' --exclude '.next' \
            "$ws/" "$dest/"
    else
      ( cd "$ws" && tar --exclude=./.git --exclude=./.relay --exclude=./node_modules \
          --exclude=./.venv --exclude=./venv --exclude=./__pycache__ \
          --exclude=./dist --exclude=./build --exclude=./target -cf - . ) |
        ( cd "$dest" && tar -xf - )
    fi
  fi

  # Link the dependency trees rather than copying them. Tests import from these
  # and never write to them, so sharing one copy across snapshots is safe.
  #
  # The `|| true` is not decoration: under `set -e` a failing test at the end of a
  # loop iteration can take the whole function down before it prints its result,
  # and the caller would then see an empty method rather than a snapshot path.
  for dep in node_modules .venv venv; do
    if [ -d "$ws/$dep" ] && [ ! -e "$dest/$dep" ]; then
      ln -s "$ws/$dep" "$dest/$dep" || warn "could not link $dep into the snapshot"
    fi
  done

  printf '%s' "$method"
}

cmd_snapshot() {
  local task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -T|--task) task="$2"; shift 2 ;;
      *) fail "Unknown option for snapshot: $1" ;;
    esac
  done
  [ -n "$task" ] || fail "-T <task file or base name> required"
  load_state
  local base method
  base="$(basename "$task" .md)"
  method="$(new_mutant_snapshot "$base")"
  say "Snapshot ($method) -> $WORKSPACE/.relay/mutants/$base"
}

# ======================================================== AUTOPILOT ==========
# Drive the whole queue unattended: every pending task through execute -> scout
# -> validate, self-healing broken panes as it goes, with the mutation lane
# running alongside instead of in the way.
#
# Everything here is bounded. An unattended loop with no ceiling is not autonomy,
# it is an unsupervised process burning a workspace.

RUN_LOG=""
ORPHANED=""

run_log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUN_LOG"
  printf '\033[36m[auto]\033[0m %s\n' "$*"
}

stop_requested() { [ -f "$WORKSPACE/.relay/STOP" ]; }

# Tasks with no report yet, in id order. Never dispatch the unfilled seed
# template: it states no requirements, can never earn a report, and would be
# picked first on every pass forever.
pending_tasks() {
  local f
  for f in "$WORKSPACE/.relay/tasks/"*.md; do
    [ -f "$f" ] || continue
    [ -f "$WORKSPACE/.relay/reports/$(basename "$f")" ] && continue
    grep -q '<What "done" means' "$f" 2>/dev/null && continue
    grep -qE '#[[:space:]]*Task[[:space:]]+[0-9]+:[[:space:]]*<title>' "$f" 2>/dev/null && continue
    printf '%s\n' "$f"
  done | sort
}

# PASS-WITH-CONCERNS must be tested before PASS or it grades as a clean pass.
get_verdict() {
  local r="$1" head
  [ -f "$r" ] || { printf 'MISSING'; return; }
  head="$(head -n 12 "$r")"
  printf '%s' "$head" | grep -qE 'VERDICT:[[:space:]]*PASS-WITH-CONCERNS' && { printf 'PASS-WITH-CONCERNS'; return; }
  printf '%s' "$head" | grep -qE 'VERDICT:[[:space:]]*FAIL'               && { printf 'FAIL'; return; }
  printf '%s' "$head" | grep -qE 'VERDICT:[[:space:]]*PASS'               && { printf 'PASS'; return; }
  printf 'UNPARSED'
}

# agy panes wedge after long uptime plus a long idle gap, and autopilot makes the
# idle gaps longer. Two defences, both free: keepalive (make idle panes answer
# during long waits so their token never sits expired for hours) and recycle
# (restart on a timer, before reaching the age where the wedge has been seen).
# Neither touches the validator: it is the one pane where a probe costs money.
keepalive() {
  local n="$1" t
  [ "$n" = "validator" ] && return 0
  t="$(pane_for "$n")"; [ -n "$t" ] || return 0
  pane_busy "$t" && return 0
  agent_responsive "$t" 45 && return 0
  run_log "keepalive: $n did not answer - recycling it now"
  restart_agents "$n" || true
}

recycle_if_old() {
  local n="$1" max_h="$2" boot hrs
  [ "$n" = "validator" ] && return 0
  [ -n "$(pane_for "$n")" ] || return 0
  eval "boot=\${BOOT_$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]'):-}"
  [ -n "$boot" ] || return 0
  hrs=$(( ( $(date +%s) - boot ) / 3600 ))
  [ "$hrs" -lt "$max_h" ] && return 0
  pane_busy "$(pane_for "$n")" && return 0
  run_log "recycling $n preemptively (up ${hrs}h)"
  restart_agents "$n" || true
  [ -n "$(printf '%s' "$RESTART_BAD" | tr -d ' ')" ] && run_log "WARNING: $n did not come back cleanly"
  return 0
}

budget_left() { eval "printf '%s' \"\${BUDGET_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')}\""; }
budget_dec()  { local k; k="BUDGET_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; eval "$k=\$(( $k - 1 ))"; }

assert_agent_ready() {
  local n="$1" trouble left
  trouble="$(agent_trouble "$n")"
  [ -z "$trouble" ] && return 0
  left="$(budget_left "$n")"
  if [ "$left" -le 0 ]; then
    run_log "$n is broken ($trouble) and its restart budget is spent - giving up on that lane"
    return 1
  fi
  budget_dec "$n"
  run_log "$n trouble: $trouble - restarting ($left restart(s) were left)"
  restart_agents "$n" || true
  if [ -n "$(printf '%s' "$RESTART_BAD" | tr -d ' ')" ]; then
    run_log "$n is STILL unhealthy after a restart"; return 1
  fi
  run_log "$n restarted and responding"
  return 0
}

# Block until an artifact lands, watching the working agent for faults and
# keeping the other agy panes warm. Prints ok|stopped|timeout|fault:<reason>.
wait_artifact() {
  local path="$1" timeout="$2" agent="$3" idle="$4"
  local deadline last_touch last_health now trouble ia
  deadline=$(( $(date +%s) + timeout ))
  last_touch="$(date +%s)"; last_health="$last_touch"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$path" ]; then sleep 0.9; printf 'ok'; return 0; fi

    # A stop takes effect immediately - that is the point of a stop file - but the
    # agent it interrupts does NOT stop. It keeps working and will likely write its
    # artifact minutes after this run has exited, with nothing watching for it. The
    # defect was never that stopping is fast; it was that in-flight work went
    # unrecorded. So record it.
    if stop_requested; then
      local leaf; leaf="$(basename "$path")"
      run_log "STOP received while waiting on $agent for $leaf"
      run_log "  -> $agent is STILL WORKING and may write $leaf after this run exits"
      ORPHANED="$ORPHANED
- $agent was mid-task on \`$leaf\` - check whether it landed, and whether it also wrote new task files"
      printf 'stopped'; return 0
    fi

    now="$(date +%s)"
    # Throttled: the process walk is a full ps parse, too expensive every poll.
    if [ $(( now - last_health )) -ge 30 ]; then
      last_health="$now"
      trouble="$(agent_trouble "$agent")"
      if [ -n "$trouble" ]; then printf 'fault:%s' "$trouble"; return 0; fi
    fi
    if [ $(( now - last_touch )) -ge 720 ]; then
      last_touch="$now"
      for ia in $idle; do keepalive "$ia"; done
    fi
    sleep 5
  done
  printf 'timeout'
}

# One dispatch-and-wait phase, with the retry that used to require a human.
invoke_phase() {
  local agent="$1" task="$2" artifact="$3" timeout="$4" idle="$5" note="${6:-}"
  local attempt r r2
  for attempt in 1 2; do
    assert_agent_ready "$agent" || { printf 'agent-down'; return 0; }
    if ! do_dispatch "$agent" "$task" "$note" >/dev/null; then
      run_log "$agent refused dispatch"
      assert_agent_ready "$agent" || { printf 'agent-down'; return 0; }
      continue
    fi
    r="$(wait_artifact "$artifact" "$timeout" "$agent" "$idle")"
    case "$r" in
      ok)      printf 'ok'; return 0 ;;
      stopped) printf 'stopped'; return 0 ;;
    esac
    run_log "$agent attempt ${attempt}: $r"

    # A timeout on an agent visibly still working is a bad guess at how long the
    # work takes, not a failure. Extend once rather than restarting the pane and
    # throwing away everything it has done.
    if [ "$r" = "timeout" ] && pane_busy "$(pane_for "$agent")"; then
      run_log "$agent is still working - extending the wait once"
      r2="$(wait_artifact "$artifact" "$timeout" "$agent" "$idle")"
      case "$r2" in
        ok)      printf 'ok'; return 0 ;;
        stopped) printf 'stopped'; return 0 ;;
      esac
      run_log "$agent after extension: $r2"
    fi
    assert_agent_ready "$agent" || { printf 'agent-down'; return 0; }
  done
  printf 'failed'
}

# The validator writes its report and its follow-up task file as separate
# actions, and the report - which every wait keys on - can land first. Never
# conclude "no follow-up was written" from a scan taken the moment a report
# appears: give the writer a settle window and re-scan.
wait_for_new_tasks() {
  local before="$1" timeout="${2:-45}" deadline after new
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    after="$(cd "$WORKSPACE/.relay/tasks" && ls -1 ./*.md 2>/dev/null | sort || true)"
    new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null || true)"
    if [ -n "$(printf '%s' "$new" | tr -d '[:space:]')" ]; then
      sleep 3; printf '%s' "$new"; return 0
    fi
    sleep 5
  done
  printf ''
}

cmd_autopilot() {
  local budget_min=480 max_cycles=24 max_fails=3 drain_min=20 no_mutation=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --budget-min)         budget_min="$2"; shift 2 ;;
      --max-cycles)         max_cycles="$2"; shift 2 ;;
      --max-fails)          max_fails="$2";  shift 2 ;;
      --mutation-drain-min) drain_min="$2";  shift 2 ;;
      --no-mutation)        no_mutation=1;   shift ;;
      *) fail "Unknown option for autopilot: $1" ;;
    esac
  done
  load_state
  tmux has-session -t "$SESSION" 2>/dev/null || fail "Relay is not running. Bring it up first: relay.sh up -w <path>"

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$WORKSPACE/.relay/logs"
  RUN_LOG="$WORKSPACE/.relay/logs/autopilot-$stamp.md"
  printf '# Autopilot run %s\nworkspace: %s\n\n' "$stamp" "$WORKSPACE" > "$RUN_LOG"

  # A stale STOP from a previous run would end this one before it started.
  if stop_requested; then rm -f "$WORKSPACE/.relay/STOP"; run_log "cleared a stale .relay/STOP"; fi

  BUDGET_EXECUTOR=4 BUDGET_SCOUT=4 BUDGET_MUTATOR=3 BUDGET_VALIDATOR=2

  local mutation_on=1
  [ "$no_mutation" -eq 1 ] && { mutation_on=0; run_log "mutation lane disabled by --no-mutation"; }
  [ -z "${MUTATOR_PANE:-}" ] && { mutation_on=0; run_log "mutation lane unavailable - this relay has no mutator pane (down/up to add it)"; }

  local seen_file="$WORKSPACE/.relay/logs/mutation-seen.txt"
  touch "$seen_file"

  local start_ts deadline cycles=0 consec=0 stop_reason="queue drained" sweep_done=0
  local summary=""
  start_ts="$(date +%s)"
  deadline=$(( start_ts + budget_min * 60 ))

  run_log "autopilot start - budget ${budget_min}m, max ${max_cycles} cycles, mutation=$mutation_on"

  while true; do
    if stop_requested;                      then stop_reason="stopped by .relay/STOP"; break; fi
    if [ "$(date +%s)" -ge "$deadline" ];   then stop_reason="wall-clock budget of ${budget_min}m exhausted"; break; fi
    if [ "$cycles" -ge "$max_cycles" ];     then stop_reason="cycle cap of $max_cycles reached"; break; fi

    local pending; pending="$(pending_tasks)"

    if [ -z "$(printf '%s' "$pending" | tr -d '[:space:]')" ]; then
      # Queue empty. Before finishing, give the mutation lane a chance to land what
      # it is still chewing on, then let the validator decide whether any of it
      # deserves a follow-up task. If it writes one, the loop picks it up.
      [ "$mutation_on" -eq 0 ] && break
      [ "$sweep_done" -eq 1 ] && break
      sweep_done=1

      local outstanding="" m
      for m in "$WORKSPACE/.relay/mutation/"*.md; do
        [ -f "$m" ] || continue
        grep -qxF "$(basename "$m" .md)" "$seen_file" && continue
        outstanding="$outstanding $m"
      done
      if pane_busy "$(pane_for mutator)"; then
        run_log "queue drained; mutator still working - draining for up to ${drain_min}m"
        local dend=$(( $(date +%s) + drain_min * 60 ))
        while [ "$(date +%s)" -lt "$dend" ] && pane_busy "$(pane_for mutator)"; do
          stop_requested && break
          sleep 15
        done
        outstanding=""
        for m in "$WORKSPACE/.relay/mutation/"*.md; do
          [ -f "$m" ] || continue
          grep -qxF "$(basename "$m" .md)" "$seen_file" && continue
          outstanding="$outstanding $m"
        done
      fi
      [ -z "$(printf '%s' "$outstanding" | tr -d ' ')" ] && break

      run_log "mutation sweep over $(printf '%s' "$outstanding" | wc -w | tr -d ' ') unreviewed report(s)"
      assert_agent_ready validator || { stop_reason="validator unavailable for the mutation sweep"; break; }

      local sweep_name="mutation-sweep-$stamp"
      local sweep_path="$WORKSPACE/.relay/reports/$sweep_name.md"
      local list=""; for m in $outstanding; do list="$list .relay/mutation/$(basename "$m") ,"; done
      local next_id
      next_id="$(printf '%03d' "$(( $(ls -1 "$WORKSPACE/.relay/tasks/" 2>/dev/null | sed -n 's/^0*\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1) + 1 ))")"
      local tasks_before; tasks_before="$(cd "$WORKSPACE/.relay/tasks" && ls -1 ./*.md 2>/dev/null | sort || true)"

      send_line "$(pane_for validator)" "Mutation sweep. These mutation reports have not been folded into any verdict yet:$list . Read each one. For every surviving mutant, decide whether it is a real gap in the tests or noise. Write a short summary to .relay/reports/$sweep_name.md , first line VERDICT: PASS or VERDICT: FAIL - PASS if nothing is worth acting on. For each real gap that IS worth closing, also write a new task file to .relay/tasks/ using the standard task format (Objective, Scope, Requirements, Verification, Artifacts), starting at id $next_id and incrementing. Write no task files if nothing warrants one."

      local sr; sr="$(wait_artifact "$sweep_path" 1800 validator "scout executor")"
      run_log "mutation sweep: $sr"
      for m in $outstanding; do basename "$m" .md >> "$seen_file"; done
      summary="$summary
| mutation sweep | - | $sr |"

      if [ "$sr" = "ok" ]; then
        local newt; newt="$(wait_for_new_tasks "$tasks_before" 45)"
        if [ -n "$(printf '%s' "$newt" | tr -d '[:space:]')" ]; then
          run_log "sweep dispatched:$(printf '%s' "$newt" | tr '\n' ' ')"
        else
          run_log "sweep dispatched no follow-up tasks"
        fi
      fi
      continue
    fi

    # --- one full cycle ----------------------------------------------------
    local task base
    task="$(printf '%s\n' "$pending" | head -1)"
    base="$(basename "$task" .md)"
    cycles=$(( cycles + 1 ))
    run_log "=== cycle $cycles : $base ==="

    # Recycle before the cycle rather than during it: this is the one moment when
    # no agent is mid-task, so a restart costs nothing but the boot time.
    local a
    for a in executor scout mutator; do recycle_if_old "$a" 3; done

    local result_p evidence_p report_p mutation_p
    result_p="$(bus_artifact results  "$base")"
    evidence_p="$(bus_artifact evidence "$base")"
    report_p="$(bus_artifact reports  "$base")"
    mutation_p="$(bus_artifact mutation "$base")"

    # Phases whose artifact is already on the bus are skipped, which makes a run
    # resumable. Without this the executor is dispatched, the stale result file is
    # seen instantly, and the cycle sails on to scout a result never regenerated -
    # looking exactly like a fast success.
    local r
    if [ -f "$result_p" ]; then
      run_log "$base already has a result - skipping the executor (resuming)"
    else
      r="$(invoke_phase executor "$task" "$result_p" 1800 "scout mutator")"
      [ "$r" = "stopped" ] && { stop_reason="stopped by .relay/STOP"; break; }
      if [ "$r" != "ok" ]; then
        run_log "executor did not produce a result for $base ($r) - stopping"
        summary="$summary
| $base | executor $r | run halted |"
        stop_reason="executor could not complete $base"; break
      fi
    fi

    # The mutation lane starts here and is never waited on.
    if [ "$mutation_on" -eq 1 ] && [ ! -f "$mutation_p" ]; then
      if assert_agent_ready mutator; then
        local meth; meth="$(new_mutant_snapshot "$base" 2>/dev/null || printf 'failed')"
        if [ "$meth" = "failed" ]; then
          run_log "snapshot for $base failed - skipping mutation for this task"
        else
          run_log "snapshot for $base ready ($meth) - mutation pass starts in the background"
          do_dispatch mutator "$task" >/dev/null || run_log "mutator refused dispatch"
        fi
      fi
    fi

    local note=""
    if [ -f "$evidence_p" ]; then
      run_log "$base already has scout evidence - skipping the scout (resuming)"
    else
      r="$(invoke_phase scout "$task" "$evidence_p" 1200 "mutator")"
      [ "$r" = "stopped" ] && { stop_reason="stopped by .relay/STOP"; break; }
      if [ "$r" != "ok" ]; then
        run_log "NO SCOUT EVIDENCE for $base ($r) - validating degraded"
        note="There is NO scout evidence for this task - the scout failed twice. Grade it degraded per your contract: PASS-WITH-CONCERNS at best, never a clean PASS, and mark every requirement you establish yourself as self-verified."
      fi
    fi

    if [ -f "$mutation_p" ]; then
      basename "$mutation_p" .md >> "$seen_file"
      run_log "mutation report for $base landed in time - the validator will read it"
    fi
    local tasks_before2; tasks_before2="$(cd "$WORKSPACE/.relay/tasks" && ls -1 ./*.md 2>/dev/null | sort || true)"

    r="$(invoke_phase validator "$task" "$report_p" 1800 "scout mutator executor" "$note")"
    [ "$r" = "stopped" ] && { stop_reason="stopped by .relay/STOP"; break; }
    if [ "$r" != "ok" ]; then
      run_log "validator produced no report for $base ($r) - stopping"
      summary="$summary
| $base | validator $r | run halted |"
      stop_reason="validator could not grade $base"; break
    fi

    local verdict; verdict="$(get_verdict "$report_p")"
    run_log "VERDICT $base : $verdict"
    summary="$summary
| $base | $verdict | |"

    if [ "$verdict" = "FAIL" ]; then
      consec=$(( consec + 1 ))
      if [ "$consec" -ge "$max_fails" ]; then
        stop_reason="$consec consecutive FAIL verdicts - the work is not converging"; break
      fi
      local newt2; newt2="$(wait_for_new_tasks "$tasks_before2" 45)"
      if [ -z "$(printf '%s' "$newt2" | tr -d '[:space:]')" ]; then
        stop_reason="$base FAILED and the validator wrote no follow-up task - a human needs to decide the next move"; break
      fi
      run_log "follow-up queued:$(printf '%s' "$newt2" | tr '\n' ' ')"
    else
      consec=0
    fi

    sweep_done=0
  done

  # --- run summary ---------------------------------------------------------
  local elapsed=$(( ( $(date +%s) - start_ts ) / 60 ))
  {
    printf '\n## Summary\n\n'
    printf 'stopped because: %s\n' "$stop_reason"
    printf 'cycles: %s   elapsed: %sm\n\n' "$cycles" "$elapsed"
    printf '| Task | Verdict | Note |\n|---|---|---|%s\n' "$summary"
    if [ -n "$(printf '%s' "$ORPHANED" | tr -d '[:space:]')" ]; then
      printf '\n## Work left in flight\n%s\n' "$ORPHANED"
      printf '\nRe-run `status` in a few minutes: late artifacts are real output, and a validator interrupted mid-sweep can still dispatch tasks that nothing is watching for.\n'
    fi
  } >> "$RUN_LOG"
  cp -f "$RUN_LOG" "$WORKSPACE/.relay/logs/autopilot-latest.md"

  printf '\n\033[32m[relay] AUTOPILOT FINISHED - %s\033[0m\n' "$stop_reason"
  printf '        cycles=%s  elapsed=%sm\n' "$cycles" "$elapsed"
  printf '%s\n' "$summary" | sed '/^$/d;s/^/        /'
  if [ -n "$(printf '%s' "$ORPHANED" | tr -d '[:space:]')" ]; then
    printf '\n\033[33m[relay] WORK LEFT IN FLIGHT - an interrupted agent kept working:\033[0m\n'
    printf '%s\n' "$ORPHANED" | sed '/^$/d;s/^/        /'
    printf '\033[33m        Check the bus again shortly - these artifacts land after this run exits.\033[0m\n'
  fi
  printf '        Run log: %s\n' "$RUN_LOG"

  # 0 = queue drained cleanly, 2 = stopped early and needs a human.
  [ "$stop_reason" = "queue drained" ] && exit 0
  exit 2
}

# ============================================================== BUS ==========
cmd_bus() {
  load_state
  find "$WORKSPACE/.relay" -type f -not -path '*/launch/*' -not -path '*/mutants/*' -exec ls -lt {} + 2>/dev/null |
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
  new)       cmd_new       "$@" ;;
  up)        cmd_up        "$@" ;;
  down)      cmd_down      "$@" ;;
  status)    cmd_status    "$@" ;;
  health)    cmd_health    "$@" ;;
  restart)   cmd_restart   "$@" ;;
  send)      cmd_send      "$@" ;;
  dispatch)  cmd_dispatch  "$@" ;;
  capture)   cmd_capture   "$@" ;;
  wait)      cmd_wait      "$@" ;;
  snapshot)  cmd_snapshot  "$@" ;;
  autopilot) cmd_autopilot "$@" ;;
  bus)       cmd_bus       "$@" ;;
  attach)    cmd_attach    "$@" ;;
  -h|--help|help) usage ;;
  *) usage; fail "Unknown subcommand: $sub" ;;
esac
