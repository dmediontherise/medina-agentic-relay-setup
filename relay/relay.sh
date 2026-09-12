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

# Chatter goes to stderr, protocol values to stdout. Several functions here are
# called inside $(...) for their return string - wait_artifact, invoke_phase,
# new_mutant_snapshot - and any one of them may log on the way. Printing progress
# on stdout put those lines INSIDE the captured value, so `case "$r" in ok)` fell
# through on every path that logged. That is why a .relay/STOP during a wait did
# not stop the run: wait_artifact logged two lines and then printed 'stopped', and
# the caller compared the whole three-line blob against 'stopped'.
say()  { printf '\033[36m[relay]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[relay] WARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31m[relay] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need_tmux() {
  command -v tmux >/dev/null 2>&1 || fail "tmux not found. macOS: brew install tmux . Debian/Ubuntu: sudo apt install tmux"
}

# Also called mid-run by autopilot, not just at startup. Restarts happen inside command
# substitutions - subshells - which call save_state, so after one the pane ids on disk
# are correct and the ones in this shell point at panes that were killed. Re-reading is
# what keeps the next dispatch from being typed into a dead pane.
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
L_EXECUTOR_OC="${L_EXECUTOR_OC:-}"
L_SCOUT_OC="${L_SCOUT_OC:-}"
L_MUTATOR_OC="${L_MUTATOR_OC:-}"
PROVIDER_EXECUTOR="${PROVIDER_EXECUTOR:-agy}"
PROVIDER_SCOUT="${PROVIDER_SCOUT:-agy}"
PROVIDER_MUTATOR="${PROVIDER_MUTATOR:-agy}"
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
# agent_process_alive. executor/scout/mutator normally run agy, but any of the
# three can be running its opencode fallback instead - see PROVIDER_* in
# save_state/load_state and the opencode-fallback block in cmd_up/restart_agents.
agent_proc_name() {
  case "$1" in
    validator) printf 'claude' ;;
    executor)  eval "printf '%s' \"\${PROVIDER_EXECUTOR:-agy}\"" ;;
    scout)     eval "printf '%s' \"\${PROVIDER_SCOUT:-agy}\"" ;;
    mutator)   eval "printf '%s' \"\${PROVIDER_MUTATOR:-agy}\"" ;;
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
# 'esc interrupt' (no "to") is opencode's --mini busy footer, observed 2026-09-07 -
# see the opencode-fallback block below. It is distinct enough from agy/claude's own
# busy text that adding it here is safe for every pane, fallback or not.
BUSY_PAT='esc to cancel|esc to interrupt|ctrl\+c to (stop|cancel)|Running\.\.\.|Running…|Cogitating|Thinking…|esc interrupt'

# Blocking modals we know how to clear. Each swallows input, so a dispatched
# instruction is absorbed and never acted on.
# The settle delay after dismissing a modal is load-bearing, not politeness.
#
# Every caller of this function classifies the pane IMMEDIATELY afterwards, and
# pane_fault reads the SCREEN. A modal overlays whatever the agent last printed,
# so while the survey is up the quota banner underneath it is not on screen. If
# we capture before agy has repainted, pane_fault sees neither the modal nor the
# banner and returns empty - the pane is then classified healthy (or merely
# unresponsive), which is a far worse answer than "blocked".
#
# That misclassification is what silently defeats the opencode fallback:
# assert_agent_ready selects the opencode route by matching the fault string
# '*quota likely exhausted*'. An empty fault never matches, so a quota-dead pane
# gets dispatched work, stalls, and then the stall path (which matches the same
# string) misses it a second time and restarts it onto the SAME exhausted agy.
#
# Observed 2026-09-11: health printed "mutator BLOCKED -> cleared agy feedback
# survey" then "mutator UNRESPONSIVE", while the quota banner was plainly on that
# pane seconds later. 0.6s was not enough for agy to repaint.
RELAY_REPAINT_SETTLE="${RELAY_REPAINT_SETTLE:-2.5}"

clear_blocking_prompts() {
  local target="$1" txt
  txt="$(pane_text "$target")"
  if pane_match "$txt" 'trust (the contents of this|this folder)'; then
    tmux send-keys -t "$target" Enter; sleep "$RELAY_REPAINT_SETTLE"; printf 'folder-trust prompt'; return 0
  fi
  # agy periodically asks for CLI feedback; it blocks the input line exactly like
  # the trust gate does.
  if pane_match "$txt" "How's the CLI experience so far"; then
    tmux send-keys -t "$target" 0; sleep "$RELAY_REPAINT_SETTLE"; printf 'agy feedback survey'; return 0
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
  # 'Individual quota reached ... Resets in <duration>' is agy's real free-tier
  # quota message, confirmed 2026-09-07 (this relay's agy account hit it on all
  # three panes during ordinary use). The rest of the alternation is defensive
  # coverage for phrasings not yet observed here (standard Google API quota-error
  # strings) - if one of those fires on something that is not really quota
  # exhaustion, tighten it; if a real exhaustion matches none of them, the
  # fallback below just never triggers and agy gets restarted into itself as
  # before, same as pre-fallback behavior.
  pane_match "$txt" 'quota reached|RESOURCE_EXHAUSTED|429 Too Many Requests|exceeded your current quota|Quota exceeded|rate limit exceeded' && { printf 'agy quota likely exhausted (heuristic)'; return 0; }
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
# Where a probed agent drops its answer. Read out of the state file rather than passed
# in, so every call site of agent_responsive stays unchanged. Fails if the relay is not
# up, in which case the probe falls back to reading the screen.
probe_dir() {
  local ws d
  [ -f "$STATE_FILE" ] || return 1
  ws="$(grep -m1 '^WORKSPACE=' "$STATE_FILE" | cut -d'"' -f2)"
  [ -n "$ws" ] && [ -d "$ws" ] || return 1
  d="$ws/.relay/health"
  mkdir -p "$d" 2>/dev/null || return 1
  printf '%s' "$d"
}

# The agent answers by writing a nonce to a file; the terminal reply is a fallback.
#
# Reading the answer off the screen does not work for the Claude pane and cannot be made
# to. Five tiled panes leave each about six rows and Claude Code spends all of them on its
# own footer, so a one-word reply is repainted rather than scrolled and never enters the
# scrollback. Verified 2026-08-30 on the PowerShell port: the pane answered in one second
# and 2000 lines of captured history held only the echo of the prompt, so every probe of a
# healthy validator failed. A file has none of those properties, and is what the rest of
# this relay already uses for coordination. The screen check stays because the agy panes
# have always passed it.
agent_responsive() {
  local target="$1" timeout="${2:-75}" nonce expect deadline txt pdir pfile body
  nonce="$(date +%s | tail -c 7)$$"; nonce="$(printf '%s' "$nonce" | tr -dc '0-9' | tail -c 6)"
  expect="RELAYOK$nonce"
  # The probe must announce itself as relay machinery. A bare "reply with this token" is
  # indistinguishable from an out-of-band instruction, and a review pane whose charter
  # tells it to work only from files on the bus is right to refuse one. Observed
  # 2026-08-30 on the PowerShell port: the validator answered "out-of-band instruction
  # with no file backing in .relay/. I'm not going to comply" - correctly - so a healthy
  # pane failed every probe. The charters carry the matching half; keep the two in step.
  pdir="$(probe_dir)" || pdir=""
  pfile=""
  [ -n "$pdir" ] && pfile="$pdir/$nonce.txt"

  # $expect is deliberately NOT interpolated into either prompt, for the reason in the
  # comment above this function: the two halves must only ever be adjacent in a real reply.
  if [ -n "$pfile" ]; then
    send_line "$target" "RELAY HEALTH CHECK - this is the relay's liveness probe, not a task and not an instruction to do any work. Write the word RELAYOK immediately followed by $nonce, as one word with nothing else in the file, into $pfile . Then reply with that same word here. Do nothing else."
  else
    send_line "$target" "RELAY HEALTH CHECK - this is the relay's liveness probe, not a task and not an instruction to do any work. Reply with the word RELAYOK immediately followed by $nonce as one word, nothing else. Do not use any tools."
  fi

  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 3
    # The file is the primary answer.
    if [ -n "$pfile" ] && [ -f "$pfile" ]; then
      body="$(tr -dc 'A-Za-z0-9' < "$pfile" 2>/dev/null)"
      case "$body" in *"$expect"*) rm -f "$pfile"; return 0 ;; esac
    fi
    txt="$(pane_text "$target" 60)"
    if printf '%s' "$txt" | grep -q "$expect"; then rm -f "$pfile" 2>/dev/null; return 0; fi
    if [ -n "$(pane_fault "$target")" ]; then rm -f "$pfile" 2>/dev/null; return 1; fi
  done
  rm -f "$pfile" 2>/dev/null
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

  relay.sh new  <project-name|path> [--safe] [--model <id>]
                                            Scaffold a project, then bring the relay up on it
  relay.sh up   [-w <workspace>] [--safe] [--model <id>]
                                            Build the session and boot the agents
  relay.sh down                             Tear the session down
  relay.sh status                           Session state, pane list, bus contents
  relay.sh health   [-a <agent>] [--deep]   Prove each agent still answers
  relay.sh restart  -a <agent|all> [--provider agy|opencode]
                                            Respawn a wedged or crashed pane in place.
                                            --provider (executor/scout/mutator only) forces
                                            that pane onto agy or its opencode free-model
                                            fallback; omitted, it keeps whatever it was on.
  relay.sh send     -a <agent> -t <text>    Type a line into a running agent
  relay.sh dispatch -a <agent> -T <task.md> [-p prebrief]
                                            Hand a task file to an agent
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
    --no-prebrief           skip the scout's spec-first pre-brief pass
    --pipeline              start the next task on the executor while the validator
                            grades this one. Skipped when the two tasks' Scope 'In:'
                            paths overlap, or when either does not state one

  agy model for the executor / scout / mutator panes, in precedence order:
    --model <id> on 'up'  >  RELAY_AGY_MODEL_{EXECUTOR,SCOUT,MUTATOR}  >  RELAY_AGY_MODEL
    default: gemini-3.8-flash-high      ('agy models' lists what you can reach)

  opencode fallback (executor/scout/mutator only, when agy's quota is exhausted):
    autopilot falls a pane to it automatically (assert_agent_ready); manually with
    'relay.sh restart -a <agent> --provider opencode', back to agy the same way with
    '--provider agy'. Model, in precedence order:
      RELAY_OPENCODE_MODEL_{EXECUTOR,SCOUT,MUTATOR}  >  RELAY_OPENCODE_MODEL
    default: opencode/big-pickle, one of opencode Zen's free $0 models ('opencode
    models --verbose' lists the rest). Opt out of the automatic fallback entirely
    with RELAY_NO_OPENCODE_FALLBACK=1.
EOF
}

# ============================================================== NEW ==========
cmd_new() {
  local name="" up_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --safe)          up_args+=(--safe); shift ;;
      --model)         up_args+=(--model "$2"); shift 2 ;;
      -*)              fail "Unknown option for new: $1" ;;
      *)               [ -z "$name" ] || fail "Usage: relay.sh new <project-name|path> [--safe] [--model <id>]"
                        name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || fail "Usage: relay.sh new <project-name|path> [--safe] [--model <id>]"

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

  cmd_up -w "$target" "${up_args[@]}"
  printf '\n  \033[1mNext:\033[0m\n'
  printf '    1. Fill in .relay/tasks/001-first-task.md (requirements + verification)\n'
  printf '    2. Run /relay-task in Claude Code from %s, or /relay-auto for the whole queue\n' "$target"
}

# =============================================================== UP ==========
cmd_up() {
  local workspace="" safe=0 deep=0 model_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -w|--workspace) workspace="$2"; shift 2 ;;
      --safe) safe=1; shift ;;
      --deep) deep=1; shift ;;
      --model) model_opt="$2"; shift 2 ;;
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

  # house-style ships alongside the role charters. It is the standing law on form for
  # every pane: the validator takes it as an appended system prompt, the agy panes read it
  # at boot ahead of their charter.
  for c in $ALL_AGENTS house-style; do
    [ -f "$RELAY_HOME/charters/$c.md" ] && cp -f "$RELAY_HOME/charters/$c.md" "$workspace/.relay/$c.md"
  done
  local style_file="$workspace/.relay/house-style.md"

  local agy_exe claude_exe opencode_exe
  agy_exe="$(command -v agy || true)"
  [ -z "$agy_exe" ] && [ -x "$HOME/.local/bin/agy" ] && agy_exe="$HOME/.local/bin/agy"
  claude_exe="$(command -v claude || true)"
  [ -z "$claude_exe" ] && [ -x "$HOME/.local/bin/claude" ] && claude_exe="$HOME/.local/bin/claude"
  opencode_exe="$(command -v opencode || true)"
  [ -z "$opencode_exe" ] && [ -x "$HOME/.opencode/bin/opencode" ] && opencode_exe="$HOME/.opencode/bin/opencode"

  if [ -z "$agy_exe" ]; then
    warn "'agy' (Antigravity CLI) not found - the agy panes will not start."
    warn "Install: curl -fsSL https://antigravity.google/cli/install.sh | sh"
    agy_exe="agy"
  fi
  if [ -z "$claude_exe" ]; then
    warn "'claude' not found - the validator will not start."
    claude_exe="claude"
  fi
  if [ -z "$opencode_exe" ]; then
    say "opencode bin : not found - no free-model fallback if agy's quota runs out."
    say "               Install: curl -fsSL https://opencode.ai/install | bash"
    opencode_exe="opencode"
  fi
  say "agy    bin   : $agy_exe   (executor + scout + mutator)"
  say "claude bin   : $claude_exe   (validator)"
  say "opencode bin : $opencode_exe   (fallback for executor/scout/mutator when agy's quota runs out)"

  local launch="$workspace/.relay/launch"

  # Model selection for the three agy panes. Antigravity ships a new Gemini tier every
  # few weeks, so this is a variable with a default rather than three literals: the only
  # edit an upgrade should ever need is the string below.
  #
  #   --model <id>                              this run, all agy panes
  #   RELAY_AGY_MODEL=<id>                      persistent default, all agy panes
  #   RELAY_AGY_MODEL_{EXECUTOR,SCOUT,MUTATOR}  per role, wins over both
  #
  # Run `agy models` to see what your account can actually reach. Per-role overrides
  # exist because the three seats do not want the same thing: the mutator is never on
  # the critical path and its loop is mechanical (edit a line, re-run the suite, record
  # what went red), so RELAY_AGY_MODEL_MUTATOR=gemini-3.8-flash-medium buys more mutants
  # inside its 25-minute budget at no cost to the verdict. The executor and the scout
  # both do reasoning the verdict depends on; leave those on the high tier.
  local agy_model="${model_opt:-${RELAY_AGY_MODEL:-gemini-3.8-flash-high}}"
  local agy_model_exec="${RELAY_AGY_MODEL_EXECUTOR:-$agy_model}"
  local agy_model_scout="${RELAY_AGY_MODEL_SCOUT:-$agy_model}"
  local agy_model_mut="${RELAY_AGY_MODEL_MUTATOR:-$agy_model}"
  local exec_flags="--dangerously-skip-permissions"
  local claude_mode="bypassPermissions"

  # opencode fallback model for the three agy panes - only used when a pane's agy
  # quota is detected exhausted (see pane_fault's quota heuristic and
  # assert_agent_ready). opencode/big-pickle is one of opencode Zen's free,
  # $0-cost models with the largest context window that doesn't carry the
  # NVIDIA "trial only, no confidential data" or Meta training-data caveats the
  # other free Zen models do - see `opencode models --verbose`. Override with
  # RELAY_OPENCODE_MODEL (all three panes) or RELAY_OPENCODE_MODEL_{EXECUTOR,SCOUT,MUTATOR}
  # (per role) if you'd rather use a different free (or paid, BYOK) opencode model.
  local oc_model="${RELAY_OPENCODE_MODEL:-opencode/big-pickle}"
  local oc_model_exec="${RELAY_OPENCODE_MODEL_EXECUTOR:-$oc_model}"
  local oc_model_scout="${RELAY_OPENCODE_MODEL_SCOUT:-$oc_model}"
  local oc_model_mut="${RELAY_OPENCODE_MODEL_MUTATOR:-$oc_model}"
  if [ "$safe" -eq 1 ]; then
    exec_flags="--mode accept-edits"
    claude_mode="acceptEdits"
  fi

  write_launcher() {
    local name="$1" body="$2"
    {
      printf '#!/usr/bin/env bash\n'
      printf 'export PATH="$HOME/.gemini/antigravity-cli/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"\n'
      printf 'cd %q || exit 1\n' "$workspace"
      printf '%s\n' "$body"
      # $body must run as a plain foreground command, never `exec`-ed - this trailer
      # is what turns "the agent's process died" into "the pane is a recoverable bare
      # shell" instead of "the pane, and maybe the whole tmux session, is gone". An
      # `exec` here replaces this script's own process with the agent's, so when the
      # agent exits there is nothing left to run these lines: no exit message, no
      # shell to inspect, no pane for `restart` to find. Verified empirically -
      # `exec false` kills the pane/session outright; plain `false` with this trailer
      # leaves a live pane sitting at a bash prompt. The CRASHED check below depends
      # on that bare shell existing.
      printf 'ec=$?\n'
      printf 'printf "\\n[relay] %s exited (exit code %%d)\\n" "$ec"\n' "$name"
      printf 'exec bash\n'
    } > "$launch/$name.sh"
    chmod +x "$launch/$name.sh"
    printf '%s' "$launch/$name.sh"
  }

  local exec_boot val_boot scout_boot mut_boot
  exec_boot="Read .relay/house-style.md and .relay/executor.md and follow them as your operating contract for this session. Reply READY when loaded, then wait for task files."
  val_boot="Read .relay/validator.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for evidence files to grade."
  scout_boot="Read .relay/house-style.md and .relay/scout.md and follow them as your operating contract for this session. Reply READY when loaded, then wait for result files to gather evidence on."
  mut_boot="Read .relay/house-style.md and .relay/mutator.md and follow them as your operating contract for this session. Reply READY when loaded, then wait to be pointed at a mutation snapshot."

  # The mutator exists as its own pane for one reason: mutation testing is slow
  # (minutes to tens of minutes) and the relay cannot hold the validator behind
  # it. A pane does one thing at a time, so giving mutation work to the primary
  # scout would serialise it into the critical path - which is exactly what a
  # second free agy pane buys us out of. It runs against a frozen snapshot in
  # .relay/mutants/<task>/, so it can still be grinding on task 007 while the
  # executor edits the real tree for task 008.
  local l_exec l_val l_scout l_mut l_bus
  # None of these bodies are `exec`-ed - see write_launcher's own comment for why.
  l_exec="$(write_launcher executor  "$(printf '%q --add-dir %q --model %s %s -i %q' "$agy_exe" "$workspace" "$agy_model_exec" "$exec_flags" "$exec_boot")")"
  # house-style goes in the SYSTEM prompt, not the boot message. A charter read as the
  # reply to a first user turn is a fact in a transcript: it competes with Claude Code's
  # own stock system prompt and decays as the conversation grows. An appended system
  # prompt is prepended to every turn instead, so the rules on form bind as hard on turn
  # 40 as on turn 1. The role charter stays a boot read - it is the casebook, and long;
  # this file is the law, and short.
  l_val="$(write_launcher  validator "$(printf '%q --model sonnet --permission-mode %s --append-system-prompt-file %q %q' "$claude_exe" "$claude_mode" "$style_file" "$val_boot")")"
  l_scout="$(write_launcher scout    "$(printf '%q --add-dir %q --model %s %s -i %q' "$agy_exe" "$workspace" "$agy_model_scout" "$exec_flags" "$scout_boot")")"
  l_mut="$(write_launcher  mutator   "$(printf '%q --add-dir %q --model %s %s -i %q' "$agy_exe" "$workspace" "$agy_model_mut" "$exec_flags" "$mut_boot")")"
  l_bus="$(write_launcher  buswatch  'while true; do clear; printf "== RELAY BUS ==\n\n"; find .relay -type f -name "*.md" -not -path "*/launch/*" -exec ls -lt {} + 2>/dev/null | head -14; sleep 3; done')"

  # opencode fallback launchers - built now, alongside the agy ones, so a mid-run
  # fallback (assert_agent_ready / cmd_restart --provider opencode) never needs to
  # recompute flags or boot text; it just points restart_agents at one of these
  # instead of the agy launcher above. `--mini` is opencode's minimal-chrome
  # interactive mode: plain scrollback text and a one-line footer, not the full
  # panelled TUI - the only mode of opencode's that behaves like agy/claude do in a
  # tiled pane (persistent process, screen-scrapable BUSY_PAT/BOOTED_PAT). `--auto`
  # is opencode's analogue of agy's --dangerously-skip-permissions; omitted in
  # --safe the same way exec_flags is.
  local oc_auto_flag="--auto"
  [ "$safe" -eq 1 ] && oc_auto_flag=""
  local l_exec_oc l_scout_oc l_mut_oc
  l_exec_oc="$(write_launcher  executor-oc "$(printf '%q --mini -m %s %s --prompt %q' "$opencode_exe" "$oc_model_exec" "$oc_auto_flag" "$exec_boot")")"
  l_scout_oc="$(write_launcher scout-oc    "$(printf '%q --mini -m %s %s --prompt %q' "$opencode_exe" "$oc_model_scout" "$oc_auto_flag" "$scout_boot")")"
  l_mut_oc="$(write_launcher   mutator-oc  "$(printf '%q --mini -m %s %s --prompt %q' "$opencode_exe" "$oc_model_mut" "$oc_auto_flag" "$mut_boot")")"

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
  L_EXECUTOR_OC="$l_exec_oc"; L_SCOUT_OC="$l_scout_oc"; L_MUTATOR_OC="$l_mut_oc"
  PROVIDER_EXECUTOR="agy"; PROVIDER_SCOUT="agy"; PROVIDER_MUTATOR="agy"
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
  say "  executor  : agy / $agy_model_exec  -> $EXECUTOR_PANE"
  say "  validator : claude sonnet -> $VALIDATOR_PANE"
  say "  scout     : agy / $agy_model_scout  -> $SCOUT_PANE"
  say "  mutator   : agy / $agy_model_mut  -> $MUTATOR_PANE"
  say "  bus watch : -> $BUS_PANE"
  if [ -n "$l_exec_oc" ] && [ -f "$l_exec_oc" ]; then
    say "  opencode fallback ready (free model, auto-falls-to on agy quota exhaustion): $oc_model_exec"
  fi
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
  printf '        provider: executor=%s scout=%s mutator=%s\n' \
    "${PROVIDER_EXECUTOR:-agy}" "${PROVIDER_SCOUT:-agy}" "${PROVIDER_MUTATOR:-agy}"
  case "agy ${PROVIDER_EXECUTOR:-agy} ${PROVIDER_SCOUT:-agy} ${PROVIDER_MUTATOR:-agy}" in
    *opencode*) printf '\033[33m        NOTE: at least one pane is running on the opencode free-model fallback, not agy.\n                 Switch it back once agy quota resets: relay.sh restart -a <name> --provider agy\033[0m\n' ;;
  esac

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
      case "$f" in
        *"quota likely exhausted"*)
          printf '             or fall it to the free-model fallback: relay.sh restart -a %s --provider opencode\n' "$n" ;;
      esac
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
#
# Third argument, provider_override ("agy" or "opencode"), only makes sense with a
# single-agent $names and only affects executor/scout/mutator - the validator has
# no fallback provider and always relaunches on claude. When omitted, each agent
# keeps whatever provider it was already on (PROVIDER_<NAME>, default agy) - a
# preemptive recycle or a keepalive miss on a pane already running its opencode
# fallback must restart it back into opencode, not silently bounce it to agy.
restart_agents() {
  local names="$1" deep="${2:-0}" provider_override="${3:-}" win="$SESSION:agents" targets="" n launcher old new
  if [ -n "$provider_override" ] && [ "$(printf '%s' "$names" | wc -w)" -gt 1 ]; then
    fail "restart_agents: provider_override requires a single agent, got '$names'"
  fi
  case "$provider_override" in ''|agy|opencode) ;; *) fail "restart_agents: provider must be 'agy' or 'opencode', got '$provider_override'" ;; esac

  for n in $names; do
    local upper; upper="$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')"
    if [ "$n" = "validator" ]; then
      eval "launcher=\${L_VALIDATOR:-}"
    else
      local want_provider
      if [ -n "$provider_override" ]; then want_provider="$provider_override"
      else eval "want_provider=\${PROVIDER_$upper:-agy}"; fi
      if [ "$want_provider" = "opencode" ]; then
        eval "launcher=\${L_${upper}_OC:-}"
        [ -n "$launcher" ] && [ -f "$launcher" ] || fail "No opencode fallback launcher for '$n' - it was not built at 'up' time (opencode missing then?). Run 'down' then 'up' with opencode installed."
      else
        eval "launcher=\${L_$upper:-}"
      fi
      eval "PROVIDER_$upper=\$want_provider"
    fi
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
  local agent="" provider=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--agent) agent="$2"; shift 2 ;;
      --provider) provider="$2"; shift 2 ;;
      --deep) shift ;;
      *) fail "Unknown option for restart: $1" ;;
    esac
  done
  [ -n "$agent" ] || fail "-a <executor|scout|mutator|validator|all> required"
  if [ -n "$provider" ] && [ "$agent" = "all" ]; then
    fail "--provider needs a single -a <executor|scout|mutator>, not 'all'"
  fi
  load_state
  local names="$ALL_AGENTS"
  [ "$agent" != "all" ] && names="$agent"
  restart_agents "$names" 0 "$provider"
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
  local agent="$1" rel="$2" base="$3" phase="${4:-}"
  [ "$phase" = "prebrief" ] && {
    printf 'PRE-BRIEF for: %s . The executor is still working - there is no code to look at yet and that is the point. Follow the pre-brief section of your contract in .relay/scout.md: read ONLY the task file, do not read the diff, the source, the tests or any result file, and do not run the verification commands. From the requirements alone, write your probe files into .relay/probe/%s/ and the expectation table into .relay/probe/%s/PREBRIEF.md , quoting for each requirement the clause its expected value comes from. Do NOT run the probes and do NOT write an evidence file. Say SCOUT PREBRIEF DONE %s when the table is written.' "$rel" "$base" "$base" "$base"
    return
  }
  case "$agent" in
    scout)     printf 'Gather evidence for: %s . Follow your contract in .relay/scout.md - re-run the verification yourself, probe the edge cases the task implies, audit the tests for real assertions, and write the compacted evidence file named in the task. Run the pre-brief probes already in .relay/probe/%s/ first and unmodified, and mark each row of your Probes run table pre or post. Do NOT do mutation testing; the mutator pane owns that. Observations only, no verdict.' "$rel" "$base" ;;
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
  local agent="$1" abs="$2" note="${3:-}" phase="${4:-}" rel base target cleared f msg
  rel="${abs#"$WORKSPACE"/}"
  base="$(basename "$abs" .md)"
  target="$(pane_for "$agent")"
  cleared="$(clear_blocking_prompts "$target")"
  [ -n "$cleared" ] && say "Cleared $cleared in $agent before dispatching"
  f="$(pane_fault "$target")"
  if [ -n "$f" ]; then printf '%s' "$f"; return 1; fi
  msg="$(dispatch_message "$agent" "$rel" "$base" "$phase")"
  [ -n "$note" ] && msg="$msg $note"
  send_line "$target" "$msg"
  say "Dispatched $rel -> $agent${phase:+ ($phase)}"
  return 0
}

cmd_dispatch() {
  local agent="executor" task="" phase=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--agent) agent="$2"; shift 2 ;;
      -T|--task)  task="$2";  shift 2 ;;
      -p|--phase) phase="$2"; shift 2 ;;
      *) fail "Unknown option for dispatch: $1" ;;
    esac
  done
  [ -n "$task" ] || fail "-T <task .md> required"
  load_state
  local abs; abs="$(bus_path "$task")"
  [ -f "$abs" ] || fail "Task file not found: $abs"
  local f
  if ! f="$(do_dispatch "$agent" "$abs" "" "$phase")"; then
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
  printf '\033[36m[auto]\033[0m %s\n' "$*" >&2   # stderr: see the note on say()
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
# --- pipelining -------------------------------------------------------------
#
# The executor and the validator never want the same thing at the same time: by the
# time the validator is grading task N, the executor has been idle since N's result
# landed and stays idle for the whole grade. Starting it on N+1 there costs nothing
# and takes a whole executor phase - the longest one in the cycle - off the wall clock
# for every task after the first.
#
# It is opt-in because it trades a real guarantee away. Serially, exactly one task's
# changes are in the tree at any moment; pipelined, the validator may be grading N
# while N+1's edits are landing around it. The scope guard below is what keeps that
# tolerable, and the validator is told about it in its dispatch note.

# The paths named on the "In:" line(s) of a task's Scope section. Empty output means
# "could not tell", which the caller must treat as "do not pipeline" - an unparseable
# scope is the case where overlap is most likely, not least.
task_scope_in() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk '
    /^##[[:space:]]/          { inscope = ($0 ~ /^##[[:space:]]*Scope/) ; next }
    inscope && /^[[:space:]]*[-*][[:space:]]*[Ii]n:/ {
      sub(/^[[:space:]]*[-*][[:space:]]*[Ii]n:[[:space:]]*/, "")
      gsub(/[,;]+/, " ")
      gsub(/[`"'"'"']/, "")
      print
    }
  ' "$f" | tr ' ' '\n' | sed 's,^\./,,; s,/*$,,' | grep -v '^$' | sort -u || true
  # `|| true` and the bare return are load-bearing under `set -euo pipefail`: a task
  # with no Scope section makes grep exit 1, which pipefail turns into a failing
  # pipeline, which errexit turns into a dead run - for the entirely normal case this
  # function exists to report. Empty output IS the answer here.
  return 0
}

# Conservative: any shared path, or either path containing the other as a directory
# prefix, counts as an overlap. So does an unparseable scope on either side.
scopes_intersect() {
  local a b pa pb hit=0
  a="$(task_scope_in "$1")"; b="$(task_scope_in "$2")"
  [ -n "$(printf '%s' "$a" | tr -d '[:space:]')" ] || return 0
  [ -n "$(printf '%s' "$b" | tr -d '[:space:]')" ] || return 0
  # Globbing off for the split: a scope of `*` or `src/*` would otherwise expand
  # against the current directory and the wildcard - the very entry that means "all
  # of it, do not pipeline" - would vanish before it could be matched.
  set -f
  for pa in $a; do
    case "$pa" in .|..|'*'|'**'|*'*'*) hit=1; break ;; esac
    for pb in $b; do
      case "$pb" in .|..|'*'|'**'|*'*'*) hit=1; break ;; esac
      [ "$pa" = "$pb" ] && { hit=1; break; }
      case "$pa" in "$pb"/*) hit=1; break ;; esac
      case "$pb" in "$pa"/*) hit=1; break ;; esac
    done
    [ "$hit" -eq 1 ] && break
  done
  set +f
  [ "$hit" -eq 1 ] && return 0
  return 1
}

# The second pending task, or nothing. Same ordering pending_tasks uses, so this is
# genuinely the one the next cycle will pick up.
next_pending_task() {
  pending_tasks | sed -n 2p
}

get_verdict() {
  local r="$1" head
  [ -f "$r" ] || { printf 'MISSING'; return; }
  head="$(head -n 12 "$r")"
  printf '%s' "$head" | grep -qE 'VERDICT:[[:space:]]*PASS-WITH-CONCERNS' && { printf 'PASS-WITH-CONCERNS'; return; }
  printf '%s' "$head" | grep -qE 'VERDICT:[[:space:]]*FAIL'               && { printf 'FAIL'; return; }
  printf '%s' "$head" | grep -qE 'VERDICT:[[:space:]]*PASS'               && { printf 'PASS'; return; }
  printf 'UNPARSED'
}

# The executor's own escalation path: COMPLETE | PARTIAL | BLOCKED, one word on
# the first non-blank line after the "## Status" heading (see executor.md). A
# BLOCKED result carries a specific question for a human, not a bug to scout,
# mutate, or grade - see the call site in cmd_autopilot for why that matters.
get_exec_status() {
  local r="$1"
  [ -f "$r" ] || { printf 'MISSING'; return; }
  awk '
    found && NF { print; exit }
    /^## Status/ { found=1 }
  ' "$r" | tr -d '[:space:]'
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

# Restart budgets and the orphan record live in files rather than shell variables,
# because the code that writes them does not run in this shell. invoke_phase and
# wait_artifact are both called as `r="$(...)"`, and a command substitution is a
# SUBSHELL: every variable they assign is discarded when the substitution ends.
#
# Two things were silently broken by that. `budget_dec` decremented a copy, so the
# "restart budget spent - giving up on that lane" branch could never fire and a
# permanently broken agent was restarted up to four times per phase, forever, instead
# of four times per run. And ORPHANED was appended in the subshell, so the "work left
# in flight" warning - the whole point of recording that an interrupted agent is still
# writing - was always empty. The PowerShell port has neither bug: its functions share
# one scope and $script: state. Files are the smallest thing that closes the gap here.
budget_file() { printf '%s/.relay/health/.budget-%s' "$WORKSPACE" "$1"; }
budget_set()  {
  mkdir -p "$WORKSPACE/.relay/health" 2>/dev/null || true
  printf '%s' "$2" > "$(budget_file "$1")"
}
budget_left() {
  local f v; f="$(budget_file "$1")"; v=""
  [ -f "$f" ] && v="$(cat "$f" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}
budget_dec()  { local l; l="$(budget_left "$1")"; [ "$l" -gt 0 ] && budget_set "$1" "$(( l - 1 ))"; return 0; }

orphan_file()   { printf '%s/.relay/health/.orphaned' "$WORKSPACE"; }
orphan_record() { mkdir -p "$WORKSPACE/.relay/health" 2>/dev/null || true; printf '%s\n' "$1" >> "$(orphan_file)"; }
orphan_all()    { [ -f "$(orphan_file)" ] && cat "$(orphan_file)" 2>/dev/null || true; }

assert_agent_ready() {
  local n="$1" trouble left provider_arg=""
  trouble="$(agent_trouble "$n")"
  [ -z "$trouble" ] && return 0
  left="$(budget_left "$n")"
  if [ "$left" -le 0 ]; then
    run_log "$n is broken ($trouble) and its restart budget is spent - giving up on that lane"
    return 1
  fi
  budget_dec "$n"

  # Quota exhaustion (heuristic - see pane_fault) is the one fault this relay can
  # route around instead of just retrying: fall the pane to its opencode free-model
  # launcher instead of restarting the same agy that just ran out. Only for
  # executor/scout/mutator, only from agy (an opencode pane erroring falls through
  # to the plain restart below, which stays on opencode via PROVIDER_<NAME>), only
  # if a fallback launcher actually got built at 'up' time, and only if the user
  # has not opted out with RELAY_NO_OPENCODE_FALLBACK.
  case "$n:$trouble" in
    executor:*"quota likely exhausted"*|scout:*"quota likely exhausted"*|mutator:*"quota likely exhausted"*)
      if [ -z "${RELAY_NO_OPENCODE_FALLBACK:-}" ]; then
        local upper; upper="$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')"
        local cur_provider oc_launcher
        eval "cur_provider=\${PROVIDER_$upper:-agy}"
        eval "oc_launcher=\${L_${upper}_OC:-}"
        if [ "$cur_provider" = "agy" ] && [ -n "$oc_launcher" ] && [ -f "$oc_launcher" ]; then
          provider_arg="opencode"
          run_log "$n trouble: $trouble - falling back to opencode free model instead of retrying agy"
        fi
      fi
      ;;
  esac

  [ -z "$provider_arg" ] && run_log "$n trouble: $trouble - restarting ($left restart(s) were left)"
  restart_agents "$n" 0 "$provider_arg" || true
  if [ -n "$(printf '%s' "$RESTART_BAD" | tr -d ' ')" ]; then
    run_log "$n is STILL unhealthy after a restart"; return 1
  fi
  if [ -n "$provider_arg" ]; then
    run_log "$n restarted on opencode (free model, degraded vs agy) and responding"
  else
    run_log "$n restarted and responding"
  fi
  return 0
}

# Has anything at all been written in the workspace since the marker was last
# touched? This is the only honest answer to "is it still working?" - a wedged agy
# pane keeps drawing its spinner, so pane_busy answers "yes" while nothing is being
# produced. Observed 2026-08-30 on the PowerShell port: an executor sat busy from
# 15:39 to 18:00, wrote zero files, and the timeout branch DOUBLED its own wait on
# the strength of that spinner. Two stalls that day cost 4h15m and produced nothing.
#
# Excluded on purpose:
#   .git            index/lock churn happens without an agent doing anything
#   .relay/logs     autopilot writes its OWN log there, so including it would make
#                   every stall look like progress - the bug this check exists to catch
#   .relay/health   keepalive nonce files, written by the panes that are NOT working
#   .relay/mutants  the mutation lane runs in parallel; its writes say nothing about
#                   the agent actually being waited on
# Heavy vendor trees are skipped for speed, not correctness.
#
# `find -newer <marker>` rather than a newest-mtime scan: BSD find on macOS has no
# -printf, and this needs no sort - the first hit is the whole answer.
progress_marker() { printf '%s/.relay/health/.progress-mark' "$WORKSPACE"; }

progress_seen() {
  local m; m="$(progress_marker)"
  [ -f "$m" ] || return 0
  [ -n "$(find "$WORKSPACE" \
      \( -path "$WORKSPACE/.git" \
      -o -path "$WORKSPACE/.relay/logs" \
      -o -path "$WORKSPACE/.relay/health" \
      -o -path "$WORKSPACE/.relay/mutants" \
      -o -name node_modules -o -name .venv -o -name venv \) -prune \
      -o -type f -newer "$m" -print 2>/dev/null | head -1)" ]
}

# Block until an artifact lands, watching the working agent for faults and
# keeping the other agy panes warm.
# Prints ok|stopped|timeout|stalled|fault:<reason>.
wait_artifact() {
  local path="$1" timeout="$2" agent="$3" idle="$4" stall_min="${5:-10}"
  local deadline last_touch last_health last_probe last_progress now trouble ia
  deadline=$(( $(date +%s) + timeout ))
  last_touch="$(date +%s)"; last_health="$last_touch"
  last_probe="$last_touch"; last_progress="$last_touch"
  mkdir -p "$WORKSPACE/.relay/health" 2>/dev/null || true
  : > "$(progress_marker)" 2>/dev/null || true
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
      orphan_record "- $agent was mid-task on \`$leaf\` - check whether it landed, and whether it also wrote new task files"
      printf 'stopped'; return 0
    fi

    now="$(date +%s)"
    # Throttled: the process walk is a full ps parse, too expensive every poll.
    if [ $(( now - last_health )) -ge 30 ]; then
      last_health="$now"
      trouble="$(agent_trouble "$agent")"
      if [ -n "$trouble" ]; then printf 'fault:%s' "$trouble"; return 0; fi
    fi
    # Busy is not progress. Ask the filesystem, not the screen.
    if [ "$stall_min" -gt 0 ] && [ $(( now - last_probe )) -ge 60 ]; then
      last_probe="$now"
      if progress_seen; then
        last_progress="$now"
        : > "$(progress_marker)" 2>/dev/null || true
      elif [ $(( now - last_progress )) -ge $(( stall_min * 60 )) ]; then
        run_log "$agent has written nothing for ${stall_min}m - stalled, not slow"
        printf 'stalled'; return 0
      fi
    fi

    if [ $(( now - last_touch )) -ge 720 ]; then
      last_touch="$now"
      for ia in $idle; do keepalive "$ia"; done
      # keepalive writes health nonce files; do not let that read as progress.
      : > "$(progress_marker)" 2>/dev/null || true
    fi
    sleep 5
  done
  printf 'timeout'
}

# One dispatch-and-wait phase, with the retry that used to require a human.
invoke_phase() {
  local agent="$1" task="$2" artifact="$3" timeout="$4" idle="$5" note="${6:-}"
  local attempt r r2 stall=10
  # Filesystem progress is a valid liveness signal only for a seat that writes as it
  # works. The agy panes do - source edits, probe files, snapshots - so ten minutes of
  # nothing means wedged. The validator does not: its contract is judgment, it is told
  # explicitly not to redo the scout's shell work, and its whole output is one file
  # written at the end. Twelve quiet minutes there is a pane reading, and restarting it
  # would burn the only quota this relay spends and start the grade over from zero.
  # That seat stays covered by the fault check and the timeout, as it was before.
  [ "$agent" = "validator" ] && stall=0
  for attempt in 1 2; do
    assert_agent_ready "$agent" || { printf 'agent-down'; return 0; }
    if ! do_dispatch "$agent" "$task" "$note" >/dev/null; then
      run_log "$agent refused dispatch"
      assert_agent_ready "$agent" || { printf 'agent-down'; return 0; }
      continue
    fi
    r="$(wait_artifact "$artifact" "$timeout" "$agent" "$idle" "$stall")"
    case "$r" in
      ok)      printf 'ok'; return 0 ;;
      stopped) printf 'stopped'; return 0 ;;
    esac
    run_log "$agent attempt ${attempt}: $r"

    # A stalled pane is wedged, not thinking. It still answers a liveness probe and
    # still looks busy, so assert_agent_ready below will not touch it - restart it
    # here, or attempt 2 re-dispatches into the same wedge and burns the timeout again.
    if [ "$r" = "stalled" ]; then
      local left; left="$(budget_left "$agent")"
      if [ "$left" -le 0 ]; then
        run_log "$agent stalled and its restart budget is spent - giving up on that lane"
        printf 'agent-down'; return 0
      fi
      budget_dec "$agent"
      run_log "restarting stalled $agent ($left restart(s) were left)"
      restart_agents "$agent" || true
      if [ -n "$(printf '%s' "$RESTART_BAD" | tr -d ' ')" ]; then
        run_log "$agent did not come back cleanly after a stall"
        printf 'agent-down'; return 0
      fi
      continue
    fi

    # A timeout on an agent visibly still working is a bad guess at how long the
    # work takes, not a failure. Extend once rather than restarting the pane and
    # throwing away everything it has done. The stall check above is what makes
    # this safe: reaching here means files were still being written.
    if [ "$r" = "timeout" ] && pane_busy "$(pane_for "$agent")"; then
      run_log "$agent is still working - extending the wait once"
      r2="$(wait_artifact "$artifact" "$timeout" "$agent" "$idle" "$stall")"
      case "$r2" in
        ok)      printf 'ok'; return 0 ;;
        stopped) printf 'stopped'; return 0 ;;
        stalled) continue ;;
      esac
      run_log "$agent after extension: $r2"
    fi
    assert_agent_ready "$agent" || { printf 'agent-down'; return 0; }
  done
  printf 'failed'
}

# A phase whose dispatch already went out - the pipelined executor. Waits for the
# artifact without dispatching again, because a second dispatch into a pane that is
# mid-turn is swallowed and the wait then times out against an agent doing the work
# correctly. Anything other than a clean landing falls back to a fresh invoke_phase,
# which re-dispatches, so a prefetch that went wrong costs a retry rather than the task.
await_phase() {
  local agent="$1" task="$2" artifact="$3" timeout="$4" idle="$5" r stall=10
  [ "$agent" = "validator" ] && stall=0
  r="$(wait_artifact "$artifact" "$timeout" "$agent" "$idle" "$stall")"
  case "$r" in
    ok)      printf 'ok'; return 0 ;;
    stopped) printf 'stopped'; return 0 ;;
  esac
  run_log "prefetched $agent did not land ($r) - falling back to a fresh dispatch"
  invoke_phase "$agent" "$task" "$artifact" "$timeout" "$idle"
}

# The validator names its follow-up on a NEXT-TASK: line in the report header, which
# is both faster and less ambiguous than watching the tasks directory: a scan cannot
# tell the validator's follow-up apart from a task a human dropped in mid-run, and it
# spends its full settle window on every FAIL that legitimately has no follow-up.
# Returns the relative path, or fails if there is no usable line.
next_task_from_report() {
  local r="$1" line rel i=0
  [ -f "$r" ] || return 1
  line="$(head -n 8 "$r" | tr -d '\r' | sed -n 's/^[[:space:]]*NEXT-TASK:[[:space:]]*//p' | head -1)"
  rel="$(printf '%s' "$line" | sed 's/[[:space:]]*$//')"
  [ -n "$rel" ] || return 1
  case "$rel" in none|None|NONE|-|n/a|N/A) return 1 ;; esac
  # The charter has it write the task before the report, so the file should already
  # be there; allow a few seconds anyway rather than falling back over a flush lag.
  while [ "$i" -lt 4 ]; do
    [ -f "$(bus_path "$rel")" ] && { printf '%s' "$rel"; return 0; }
    i=$(( i + 1 )); sleep 2
  done
  run_log "report names NEXT-TASK: $rel but no such file exists - falling back to a directory scan"
  return 1
}

# Fallback for a report with no NEXT-TASK: line. The validator writes its report and
# its follow-up task file as separate actions, and the report - which every wait keys
# on - can land first. Never conclude "no follow-up was written" from a scan taken the
# moment a report appears: give the writer a settle window and re-scan.
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
  local budget_min=480 max_cycles=24 max_fails=3 drain_min=20 no_mutation=0 no_prebrief=0
  local pipeline=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --pipeline)           pipeline=1;      shift ;;
      --budget-min)         budget_min="$2"; shift 2 ;;
      --max-cycles)         max_cycles="$2"; shift 2 ;;
      --max-fails)          max_fails="$2";  shift 2 ;;
      --mutation-drain-min) drain_min="$2";  shift 2 ;;
      --no-mutation)        no_mutation=1;   shift ;;
      --no-prebrief)        no_prebrief=1;   shift ;;
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

  budget_set executor 4; budget_set scout 4; budget_set mutator 3; budget_set validator 2
  rm -f "$(orphan_file)"

  # The scout pane is idle for the whole executor phase - the longest phase in the
  # cycle - and the one thing it can usefully do without the code is decide what
  # correct means. So it does that there: probes derived from the task file alone,
  # written before any implementation exists to copy an expected value from. Buys
  # back the probe-design time AND closes the failure recorded in all four of the
  # first cycles, where a probe written after reading the code asserted what the code
  # did. See the pre-brief section of the scout charter.
  local prebrief_on=1
  [ "$no_prebrief" -eq 1 ] && { prebrief_on=0; run_log "spec-first pre-brief disabled by --no-prebrief"; }

  # PREFETCHED holds the base name of a task the executor was started on early, while
  # the validator was still grading the one before it. At most one is ever outstanding.
  local PREFETCHED=""
  [ "$pipeline" -eq 1 ] && run_log "pipelining ON - the executor starts the next task while the validator grades this one"

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

      send_line "$(pane_for validator)" "Mutation sweep. These mutation reports have not been folded into any verdict yet:$list . Read each one. For every surviving mutant, decide whether it is a real gap in the tests or noise. Write a short summary to .relay/reports/$sweep_name.md , first line VERDICT: PASS or VERDICT: FAIL - PASS if nothing is worth acting on - and second line NEXT-TASK: followed by the path of the first task file you wrote, or none. For each real gap that IS worth closing, also write a new task file to .relay/tasks/ using the standard task format (Objective, Scope, Requirements, Verification, Artifacts), starting at id $next_id and incrementing. Write the task files before the summary. Write no task files if nothing warrants one."

      local sr; sr="$(wait_artifact "$sweep_path" 1800 validator "scout executor" 0)"
      load_state   # keepalive may have recycled an idle agy pane during that wait
      run_log "mutation sweep: $sr"

      # Mark the inputs reviewed ONLY if the sweep actually produced its summary. This
      # used to run unconditionally, so a sweep that timed out or was stopped still
      # recorded every report it had been handed as handled - and the seen file is
      # persisted, so those findings were skipped by every future run. Silent, and
      # permanent. Observed 2026-08-30 on the PowerShell port: a declined sweep timed out
      # at 30m and buried three reports, which turned out to hold three real test gaps.
      if [ "$sr" = "ok" ]; then
        for m in $outstanding; do basename "$m" .md >> "$seen_file"; done
      else
        run_log "sweep did not complete ($sr) - leaving those report(s) unreviewed for the next run"
      fi
      summary="$summary
| mutation sweep | - | $sr |"

      if [ "$sr" = "ok" ]; then
        local newt; newt="$(next_task_from_report "$sweep_path" || true)"
        if [ -n "$newt" ]; then
          run_log "sweep named its follow-up: $newt"
        else
          newt="$(wait_for_new_tasks "$tasks_before" 45)"
        fi
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
    for a in executor scout mutator; do
      # A prefetched executor is mid-task even between turns, and recycle_if_old only
      # checks pane_busy - which reads false in the gaps. Restarting there throws away
      # a task's work with nothing to show that it happened.
      [ "$a" = "executor" ] && [ -n "$PREFETCHED" ] && continue
      [ "$a" = "scout" ] && [ -n "$PREFETCHED" ] && continue
      recycle_if_old "$a" 3
    done

    local result_p evidence_p report_p mutation_p
    result_p="$(bus_artifact results  "$base")"
    evidence_p="$(bus_artifact evidence "$base")"
    report_p="$(bus_artifact reports  "$base")"
    mutation_p="$(bus_artifact mutation "$base")"

    # Phases whose artifact is already on the bus are skipped, which makes a run
    # resumable. Without this the executor is dispatched, the stale result file is
    # seen instantly, and the cycle sails on to scout a result never regenerated -
    # looking exactly like a fast success.
    local prebrief_p="$WORKSPACE/.relay/probe/$base/PREBRIEF.md"
    local was_prefetched=0
    [ -n "$PREFETCHED" ] && [ "$PREFETCHED" = "$base" ] && { was_prefetched=1; PREFETCHED=""; }

    local r
    if [ -f "$result_p" ]; then
      if [ "$was_prefetched" -eq 1 ]; then
        run_log "$base was prefetched during the previous grade and is already done"
      else
        run_log "$base already has a result - skipping the executor (resuming)"
      fi
    elif [ "$was_prefetched" -eq 1 ]; then
      # Dispatched a cycle early; the pane is still on it. Wait, do not dispatch again.
      run_log "$base was prefetched and is still running - waiting rather than re-dispatching"
      r="$(await_phase executor "$task" "$result_p" 1800 "scout mutator")"
      load_state
      [ "$r" = "stopped" ] && { stop_reason="stopped by .relay/STOP"; break; }
      if [ "$r" != "ok" ]; then
        run_log "executor did not produce a result for $base ($r) - stopping"
        summary="$summary
| $base | executor $r | run halted |"
        stop_reason="executor could not complete $base"; break
      fi
    else
      # A prefetch for a DIFFERENT task may still be in flight. By construction that
      # should not happen - a validator follow-up always takes the next free id, so it
      # sorts after anything already prefetched - but a task dropped in by hand with a
      # lower id would do it, and dispatching into a busy agy pane loses the line
      # silently and then times out against an agent that was working correctly.
      if [ -n "$PREFETCHED" ]; then
        run_log "executor is still on the prefetched $PREFETCHED - waiting before dispatching $base"
        local pfd=$(( $(date +%s) + 1800 ))
        while [ "$(date +%s)" -lt "$pfd" ] &&
              [ ! -f "$(bus_artifact results "$PREFETCHED")" ] &&
              pane_busy "$(pane_for executor)"; do
          stop_requested && break
          sleep 10
        done
      fi

      # Dispatched first and never waited on: the executor phase is the budget it
      # runs inside. If it does not finish in time the scout simply probes the old
      # way, which its charter covers.
      if [ "$prebrief_on" -eq 1 ] && [ ! -f "$prebrief_p" ]; then
        mkdir -p "$WORKSPACE/.relay/probe/$base" 2>/dev/null || true
        if assert_agent_ready scout; then
          do_dispatch scout "$task" "" prebrief >/dev/null ||
            run_log "scout refused the pre-brief - continuing without one"
        fi
      fi
      r="$(invoke_phase executor "$task" "$result_p" 1800 "scout mutator")"
      load_state   # a restart inside that subshell renumbered panes on disk only
      [ "$r" = "stopped" ] && { stop_reason="stopped by .relay/STOP"; break; }
      if [ "$r" != "ok" ]; then
        run_log "executor did not produce a result for $base ($r) - stopping"
        summary="$summary
| $base | executor $r | run halted |"
        stop_reason="executor could not complete $base"; break
      fi
    fi

    # BLOCKED is the executor's designed escalation for a task it found genuinely
    # ambiguous (executor.md: "write status BLOCKED with the specific question
    # rather than guessing"). Nothing downstream can answer that question - the
    # scout only observes, the mutator only mutates, the validator only grades -
    # so running it through them anyway just spends a full cycle (and, with
    # prefetch on, a second task's worth of wall clock) to arrive at the same
    # FAIL this line reaches immediately, without ever surfacing the question.
    # Stop here and hand it to the human who can actually answer it. This also
    # covers the resumed and prefetched-result paths above, since all three
    # converge on the same result_p before this point.
    local exec_status; exec_status="$(get_exec_status "$result_p")"
    if [ "$exec_status" = "BLOCKED" ]; then
      run_log "$base : executor reported BLOCKED - stopping instead of running it through scout/mutation/validation"
      summary="$summary
| $base | BLOCKED | executor's question is in $result_p |"
      stop_reason="$base : executor is BLOCKED and needs a human answer - see $result_p"; break
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
      # One pane does one thing at a time, and a line typed into a busy agy pane is
      # swallowed. If the pre-brief is still running, wait for it - briefly - rather
      # than dispatching the evidence pass into a pane that will never read it.
      if [ "$prebrief_on" -eq 1 ] && [ ! -f "$prebrief_p" ] && pane_busy "$(pane_for scout)"; then
        run_log "waiting up to 5m for the scout's pre-brief to land before the evidence pass"
        local pdl=$(( $(date +%s) + 300 ))
        while [ "$(date +%s)" -lt "$pdl" ] && [ ! -f "$prebrief_p" ] &&
              pane_busy "$(pane_for scout)"; do
          stop_requested && break
          sleep 5
        done
      fi
      if [ "$prebrief_on" -eq 1 ] && [ ! -f "$prebrief_p" ]; then
        run_log "no pre-brief for $base - the scout will probe post-hoc"
      fi
      r="$(invoke_phase scout "$task" "$evidence_p" 1200 "mutator")"
      load_state
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

    # --- prefetch: start the next task while the validator grades this one -----
    #
    # This is the one moment in the cycle when the executor and the scout are both
    # idle and will stay idle for a long time. Dispatching here and never waiting
    # takes a whole executor phase off the wall clock for every task after the first.
    # The dispatch is fire-and-forget; the next cycle picks the result up through the
    # same artifact-exists check that makes an interrupted run resumable.
    local pipe_note=""
    if [ "$pipeline" -eq 1 ] && [ -z "$PREFETCHED" ]; then
      local nxt nbase
      nxt="$(next_pending_task)"
      if [ -z "$nxt" ]; then
        :   # nothing queued behind this one
      elif scopes_intersect "$task" "$nxt"; then
        run_log "not prefetching $(basename "$nxt" .md) - its scope overlaps $base (or one of them does not state a parseable scope)"
      else
        nbase="$(basename "$nxt" .md)"
        if assert_agent_ready executor; then
          if do_dispatch executor "$nxt" >/dev/null; then
            PREFETCHED="$nbase"
            run_log "prefetching $nbase on the executor while the validator grades $base"
            pipe_note="Note: pipelining is on, so the executor is concurrently working on a LATER task ($nbase) in this same tree. Its scope does not overlap this one. Grade from the diff the scout captured, not from a fresh git diff, and treat changes to files outside this task's Scope as not yours to judge."
            if [ "$prebrief_on" -eq 1 ] && [ ! -f "$WORKSPACE/.relay/probe/$nbase/PREBRIEF.md" ]; then
              mkdir -p "$WORKSPACE/.relay/probe/$nbase" 2>/dev/null || true
              assert_agent_ready scout &&
                { do_dispatch scout "$nxt" "" prebrief >/dev/null ||
                  run_log "scout refused the prefetched pre-brief"; }
            fi
          else
            run_log "executor refused the prefetch - $nbase will run in its own cycle"
          fi
        fi
      fi
    fi

    [ -n "$pipe_note" ] && note="$note $pipe_note"
    # Idle-pane keepalive must skip anything the prefetch put to work. keepalive
    # restarts a pane that does not answer, and an executor mid-task between turns
    # can miss a probe - which would kill the prefetch to prove it was alive.
    local val_idle="scout mutator executor"
    [ -n "$PREFETCHED" ] && val_idle="mutator"
    r="$(invoke_phase validator "$task" "$report_p" 1800 "$val_idle" "$note")"
    load_state
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
      local newt2; newt2="$(next_task_from_report "$report_p" || true)"
      if [ -n "$newt2" ]; then
        run_log "validator named its follow-up: $newt2"
      else
        newt2="$(wait_for_new_tasks "$tasks_before2" 45)"
      fi
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
  # A prefetched executor keeps working after this loop exits, exactly like an agent
  # interrupted mid-wait, and its result lands with nothing watching for it.
  if [ -n "$PREFETCHED" ] && [ ! -f "$(bus_artifact results "$PREFETCHED")" ]; then
    orphan_record "- executor was prefetched onto \`$PREFETCHED\` and is STILL WORKING - its result will land after this run exits"
  fi

  local elapsed=$(( ( $(date +%s) - start_ts ) / 60 ))
  ORPHANED="$(orphan_all)"
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
