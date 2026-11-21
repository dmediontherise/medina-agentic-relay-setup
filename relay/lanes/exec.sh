# shellcheck shell=bash
# Runs one headless agent turn per lane step, inside a tmux window so a human can watch,
# and classifies how it ended. Completion is an exit-code file plus the step's expected
# output file - never the look of an idle prompt, which is what made relay.sh need its
# probe/keepalive/recycle machinery.
#
# Roles: explore write prebrief evidence mutate  -> agy, falling back to opencode
#        validator inline                         -> claude (never falls back)

LANES_SESSION="${RELAY_LANES_SESSION:-lanes}"
LANES_STATE="${RELAY_LANES_STATE:-$HOME/.cache/relay-lanes}"

# Same alternations relay.sh's pane_fault uses. "quota reached" is agy's real message
# (confirmed 2026-09-07); the rest is defensive.
QUOTA_PAT='quota reached|RESOURCE_EXHAUSTED|429 Too Many Requests|exceeded your current quota|Quota exceeded|rate limit exceeded'
CLAUDE_LIMIT_PAT='/rate-limit-options|usage limit reached|Claude usage limit'
AUTH_PAT='Agent execution terminated due to error|UNAUTHENTICATED|invalid authentication credentials|Please run /login|Invalid API key|not authenticated'

lane_bin() {
  local p
  p="$(command -v "$1" 2>/dev/null || true)"
  if [ -z "$p" ]; then
    case "$1" in
      agy|claude) [ -x "$HOME/.local/bin/$1" ] && p="$HOME/.local/bin/$1" ;;
      opencode)   [ -x "$HOME/.opencode/bin/opencode" ] && p="$HOME/.opencode/bin/opencode" ;;
    esac
  fi
  printf '%s' "${p:-$1}"
}

# <provider> <role> -> model. Reuses relay.sh's knobs: write = executor seat, every
# read-only scouting role = scout seat, mutate = mutator seat.
lane_model_for() {
  local agy="${RELAY_AGY_MODEL:-gemini-3.8-flash-medium}" oc="${RELAY_OPENCODE_MODEL:-opencode/big-pickle}"
  case "$1:$2" in
    claude:validator) printf '%s' "${RELAY_VALIDATOR_MODEL:-claude-sonnet-5-5}" ;;
    claude:*)         printf '%s' "${RELAY_INLINE_MODEL:-claude-opus-5-5}" ;;
    agy:write)        printf '%s' "${RELAY_AGY_MODEL_EXECUTOR:-$agy}" ;;
    agy:mutate)       printf '%s' "${RELAY_AGY_MODEL_MUTATOR:-$agy}" ;;
    agy:*)            printf '%s' "${RELAY_AGY_MODEL_SCOUT:-$agy}" ;;
    opencode:write)   printf '%s' "${RELAY_OPENCODE_MODEL_EXECUTOR:-$oc}" ;;
    opencode:mutate)  printf '%s' "${RELAY_OPENCODE_MODEL_MUTATOR:-$oc}" ;;
    opencode:*)       printf '%s' "${RELAY_OPENCODE_MODEL_SCOUT:-$oc}" ;;
  esac
}

# <provider> <model> <dir> <prompt> <role> -> one shell-quoted command line
lane_cmdline() {
  local provider="$1" model="$2" dir="$3" prompt="$4" role="$5" perm extra=""
  case "$provider" in
    agy)
      perm="--dangerously-skip-permissions"
      [ "${RELAY_LANES_SAFE:-0}" = "1" ] && perm="--mode accept-edits"
      [ "$role" = prebrief ] && extra=" --sandbox"
      printf '%q -p %q --model %q %s --add-dir %q%s' "$(lane_bin agy)" "$prompt" "$model" "$perm" "$dir" "$extra" ;;
    opencode)
      printf '%q run -m %q %q' "$(lane_bin opencode)" "$model" "$prompt" ;;
    claude)
      perm="acceptEdits"
      [ "$role" = inline ] && [ "${RELAY_LANES_SAFE:-0}" != "1" ] && perm="bypassPermissions"
      printf '%q -p --model %q --permission-mode %s %q' "$(lane_bin claude)" "$model" "$perm" "$prompt" ;;
  esac
}

# <log> <provider> -> quota | limit | auth | nothing. Callers only ask after a turn failed:
# a successful log that merely discusses rate limits must not trip this.
lane_classify_log() {
  local log="$1" provider="$2" tail_txt
  [ -f "$log" ] || return 0
  tail_txt="$(tail -n 40 "$log")"
  case "$provider" in
    agy|opencode) printf '%s' "$tail_txt" | grep -qiE "$QUOTA_PAT" && { printf 'quota'; return 0; } ;;
    claude)       printf '%s' "$tail_txt" | grep -qiE "$CLAUDE_LIMIT_PAT" && { printf 'limit'; return 0; } ;;
  esac
  printf '%s' "$tail_txt" | grep -qiE "$AUTH_PAT" && printf 'auth'
  return 0
}

# Once agy reports quota exhaustion, later lanes go straight to opencode for
# RELAY_QUOTA_COOLDOWN seconds instead of rediscovering it one failed turn at a time.
lane_mark_agy_quota() { mkdir -p "$LANES_STATE"; date +%s > "$LANES_STATE/agy-quota-at"; }
lane_agy_cooling_check_at() {
  local at
  at="$(cat "$LANES_STATE/agy-quota-at" 2>/dev/null || true)"
  [ -n "$at" ] && [ "$1" -lt $(( at + ${RELAY_QUOTA_COOLDOWN:-3600} )) ]
}
lane_agy_cooling() { lane_agy_cooling_check_at "$(date +%s)"; }

# --- optional helpers, same contracts and knobs as relay.sh ---------------------
JEV_PY="${RELAY_JEV_PYTHON:-$HOME/Jev-AI-Skill/.venv/bin/python}"
JEV_HELPER="${RELAY_JEV_HELPER:-$RELAY_HOME/relay_jev.py}"
CITE_PY="${RELAY_CITE_PYTHON:-python3}"
CITE_HELPER="${RELAY_CITE_HELPER:-$RELAY_HOME/relay_cite.py}"
lanes_jev_on()  { [ "${RELAY_JEV:-0}" = "1" ] && [ -x "$JEV_PY" ] && [ -f "$JEV_HELPER" ]; }
lanes_jev()     { timeout 90 "$JEV_PY" -I "$JEV_HELPER" "$@" 2>/dev/null | head -n 1 || true; }
lanes_cite_on() { [ "${RELAY_CITE:-1}" != "0" ] && [ -f "$CITE_HELPER" ] && command -v "$CITE_PY" >/dev/null 2>&1; }

# Verbatim from relay.sh resolve_rea_bin.
lane_rea_bin() {
  if [ -n "${RELAY_REA_BIN:-}" ]; then
    printf '%s' "$RELAY_REA_BIN"; [ -x "$RELAY_REA_BIN" ] && return 0 || return 1
  fi
  local bin newest
  bin="$(command -v rea 2>/dev/null || true)"
  if [ -n "$bin" ] && [ -x "$bin" ]; then printf '%s' "$bin"; return 0; fi
  newest="$(ls -d "$HOME"/.nvm/versions/node/*/bin/rea 2>/dev/null | sort -V | tail -1 || true)"
  if [ -n "$newest" ] && [ -x "$newest" ]; then printf '%s' "$newest"; return 0; fi
  return 1
}
lanes_rea_on() {
  [ "${RELAY_REA:-0}" = "1" ] || return 1
  lane_rea_bin >/dev/null 2>&1 && [ -f "$RELAY_HOME/charters/rea.md" ]
}

# PATH for a lane: the caller's PATH first (so tests' stubs win), then the agent install
# dirs; REA's nvm bin goes in front, because /usr/bin's Node is too old for it.
lane_path() {
  local p="$PATH:$HOME/.gemini/antigravity-cli/bin:$HOME/.local/bin:$HOME/.opencode/bin"
  if lanes_rea_on; then p="$(dirname "$(lane_rea_bin)"):$p"; fi
  printf '%s' "$p"
}
