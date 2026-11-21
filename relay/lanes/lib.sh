# shellcheck shell=bash
# Pure helpers for lanes.sh: ODD feature-doc rows and specs, doc edits, scopes, worktree
# state and run directories. No tmux and no agents in here, so every function is
# unit-testable from tests/lanes/.
#
# An ODD Tasks row, as gentle-ai's orchestrator writes it, with the relay's optional keys:
#   - [ ] T3 S2/S4 Parse durations (route: write; risk: high(data); In: src/d; after: T1; commit: pending)
# Marks: [ ] pending, [x] done, [~] superseded by a follow-up row, [!] blocked.

lanes_say()  { printf '\033[36m[lanes]\033[0m %s\n' "$*" >&2; }
lanes_warn() { printf '\033[33m[lanes] WARNING:\033[0m %s\n' "$*" >&2; }
lanes_fail() { printf '\033[31m[lanes] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# <doc> <id> -> the row line from ## Tasks, or nothing
lane_row() {
  awk -v id="$2" '
    /^##[[:space:]]/ { t = ($0 ~ /^##[[:space:]]*Tasks/); next }
    t && /^- \[.\] / { r = substr($0, 7); split(r, w, " "); if (w[1] == id) { print; exit } }
  ' "$1"
}

lane_row_id()   { printf '%s\n' "${1:6}" | awk '{ print $1 }'; }
lane_row_mark() { printf '%s' "${1:3:1}"; }

# <row> <key> -> value of "key: value" inside the row's key/value parenthetical. The group
# is found by its first key, not by the last "(", because values such as high(data) carry
# their own parentheses.
lane_row_kv() {
  printf '%s\n' "$1" | awk -v k="$2" '{
    if (!match($0, /\((route|risk|[Ii]n|after|commit):/)) exit
    s = substr($0, RSTART + 1); sub(/\)[[:space:]]*$/, "", s)
    n = split(s, seg, ";")
    for (i = 1; i <= n; i++) {
      t = seg[i]; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (tolower(substr(t, 1, length(k) + 1)) == tolower(k) ":") {
        t = substr(t, length(k) + 2); gsub(/^[ \t]+/, "", t); print t; exit
      }
    }
  }'
}

lane_row_route() { lane_row_kv "$1" route | awk -F'[ ,]' '{ print $1 }'; }
lane_row_risk_high() { case "$(lane_row_kv "$1" risk)" in high*) return 0 ;; esac; return 1; }
lane_row_after() { lane_row_kv "$1" after | tr ',' ' ' | xargs; }
# In: entries, space-separated, with backticks/quotes and commas removed
lane_row_in() { lane_row_kv "$1" in | tr -d '`"'"'" | tr ',;' '  ' | xargs; }

# The S# refs in the row's second word (S8/S9, S2,S4, S1), one per line
lane_row_specs() {
  printf '%s\n' "${1:6}" | awk '{ print $2 }' | grep -oE 'S[0-9]+' || true
}

# The words between the S# word and the key/value parenthetical
lane_row_title() {
  printf '%s\n' "$1" | awk '{
    s = substr($0, 7)
    if (match(s, /\((route|risk|[Ii]n|after|commit):/)) s = substr(s, 1, RSTART - 1)
    n = split(s, w, " "); t = ""
    for (i = 3; i <= n; i++) t = t (t == "" ? "" : " ") w[i]
    print t
  }'
}

# <doc> -> ids of pending ([ ]) rows, in document order
lane_pending_ids() {
  awk '/^##[[:space:]]/ { t = ($0 ~ /^##[[:space:]]*Tasks/); next }
       t && /^- \[ \] / { r = substr($0, 7); split(r, w, " "); print w[1] }' "$1"
}
