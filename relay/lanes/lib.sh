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

# <doc> [S-id...] -> those ## Specs bullets verbatim, with continuation lines. No ids
# means every spec: a row that names none is graded against all of them.
lane_spec_text() {
  local doc="$1" want="*"; shift
  [ $# -gt 0 ] && want=" $* "
  WANT="$want" awk '
    /^##[[:space:]]/ { sp = ($0 ~ /^##[[:space:]]*Specs/); cur = 0; next }
    !sp { next }
    /^- (\*\*)?S[0-9]+/ {
      id = $2; gsub(/[^A-Za-z0-9]/, "", id)
      cur = (ENVIRON["WANT"] == "*" || index(ENVIRON["WANT"], " " id " ") > 0)
    }
    cur { print }' "$doc"
}

# <doc> -> everything before the first ## heading (title, Objective, Runner, Branch...)
lane_doc_header() { sed -n '1,/^## /p' "$1" | sed '$d'; }

# <doc> -> the first backticked command after "Runner:" in the header, or nothing
lane_doc_runner() { lane_doc_header "$1" | sed -nE 's/.*Runner:[^`]*`([^`]+)`.*/\1/p' | head -n 1; }

# <row> <mark> [commit] -> the row with its checkbox mark set and, when given, commit: set
lane_row_with() {
  local row="$1" mark="$2" commit="${3:-}"
  row="- [$mark]${row:5}"
  if [ -n "$commit" ]; then
    if printf '%s' "$row" | grep -q 'commit:'; then
      row="$(printf '%s' "$row" | sed -E "s/commit:[^;)]*/commit: $commit/")"
    elif [ "${row%)}" != "$row" ]; then
      row="${row%)}; commit: $commit)"
    else
      row="$row (commit: $commit)"
    fi
  fi
  printf '%s' "$row"
}

# <doc> <id> <new-line>: replace that Tasks row in place
lane_doc_replace_row() {
  local tmp="$1.lanes.tmp"
  NEWROW="$3" awk -v id="$2" '
    /^##[[:space:]]/ { t = ($0 ~ /^##[[:space:]]*Tasks/) }
    t && !done && /^- \[.\] / { r = substr($0, 7); split(r, w, " ")
      if (w[1] == id) { print ENVIRON["NEWROW"]; done = 1; next } }
    { print }' "$1" > "$tmp" && mv "$tmp" "$1"
}

# <doc> <id> <new-line>: insert a Tasks row directly after row <id>
lane_doc_insert_after() {
  local tmp="$1.lanes.tmp"
  NEWROW="$3" awk -v id="$2" '
    { print }
    /^##[[:space:]]/ { t = ($0 ~ /^##[[:space:]]*Tasks/); next }
    t && !done && /^- \[.\] / { r = substr($0, 7); split(r, w, " ")
      if (w[1] == id) { print ENVIRON["NEWROW"]; done = 1 } }' "$1" > "$tmp" && mv "$tmp" "$1"
}

# <doc> <text>: append "- L<n> <text>" to ## Log (ODD keeps Log last, so append = end of file)
lane_doc_log() {
  local doc="$1" n
  n="$(sed -nE 's/^(- )?(\*\*)?L([0-9]+).*/\3/p' "$doc" | sort -n | tail -n 1)"
  n=$(( ${n:-0} + 1 ))
  grep -q '^## Log' "$doc" || printf '\n## Log\n\n' >> "$doc"
  printf -- '- L%s %s\n' "$n" "$2" >> "$doc"
}

# --- scopes -------------------------------------------------------------------
# Ported from relay.sh scopes_intersect, taking In: lists directly. Conservative: a shared
# path, either containing the other, a wildcard, or an empty list all count as overlap.
lane_scopes_overlap() {
  local a="$1" b="$2" pa pb hit=0
  [ -n "$(printf '%s' "$a" | tr -d '[:space:]')" ] || return 0
  [ -n "$(printf '%s' "$b" | tr -d '[:space:]')" ] || return 0
  set -f
  for pa in $a; do
    pa="${pa#./}"; pa="${pa%/}"
    case "$pa" in .|..|'*'|'**'|*'*'*) hit=1; break ;; esac
    for pb in $b; do
      pb="${pb#./}"; pb="${pb%/}"
      case "$pb" in .|..|'*'|'**'|*'*'*) hit=1; break ;; esac
      [ "$pa" = "$pb" ] && { hit=1; break; }
      case "$pa" in "$pb"/*) hit=1; break ;; esac
      case "$pb" in "$pa"/*) hit=1; break ;; esac
    done
    [ "$hit" -eq 1 ] && break
  done
  set +f
  [ "$hit" -eq 1 ]
}

# <path> <in-list> -> 0 when path is an entry, under an entry, or matches an entry's glob
lane_path_in_scope() {
  local p="$1" e
  set -f
  for e in $2; do
    e="${e#./}"; e="${e%/}"
    [ "$e" = "." ] && { set +f; return 0; }
    # shellcheck disable=SC2254  # unquoted on purpose: In: entries may be globs
    case "$p" in $e|$e/*) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

# stdin: paths; <in-list> -> the paths that are out of scope
lane_out_of_scope() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    lane_path_in_scope "$p" "$1" || printf '%s\n' "$p"
  done
}

# --- worktree state -----------------------------------------------------------
# <ws> -> "hash<TAB>path" for every path that differs from HEAD or is untracked, outside
# .relay/ and odd/. Content is stored with `hash-object -w`, so a later revert can put a
# file back exactly as it was before the lane, even if it was already dirty then.
lane_tree_state() {
  local ws="$1" p
  { git -C "$ws" diff --no-renames --name-only HEAD -- . ':(exclude).relay' ':(exclude)odd'
    git -C "$ws" ls-files --others --exclude-standard -- . ':(exclude).relay' ':(exclude)odd'
  } | sort -u | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$ws/$p" ]; then
      printf '%s\t%s\n' "$(git -C "$ws" hash-object -w -- "$p")" "$p"
    else
      printf 'deleted\t%s\n' "$p"
    fi
  done
}

# <pre> <post> -> paths whose state changed between the two snapshots, sorted
lane_tree_delta() {
  awk -F'\t' 'NR == FNR { pre[$2] = $1; next } { post[$2] = $1 }
    END { for (p in pre) if (!(p in post) || post[p] != pre[p]) print p
          for (p in post) if (!(p in pre)) print p }' "$1" "$2" | sort -u
}

# <ws> <path> <pre>: put one path back to its pre-lane state
lane_revert_path() {
  local ws="$1" p="$2" h
  h="$(awk -F'\t' -v p="$p" '$2 == p { print $1; exit }' "$3")"
  if [ -n "$h" ] && [ "$h" != deleted ]; then
    mkdir -p "$(dirname "$ws/$p")"; git -C "$ws" cat-file blob "$h" > "$ws/$p"
  elif [ "$h" = deleted ]; then
    rm -f "$ws/$p"
  elif git -C "$ws" cat-file -e "HEAD:$p" 2>/dev/null; then
    git -C "$ws" checkout -q HEAD -- "$p"
  else
    rm -f "$ws/$p"
  fi
}

# <ws> -> unified diff of the candidate against HEAD, untracked files included
lane_diff() {
  local ws="$1" f
  git -C "$ws" diff --no-renames HEAD -- . ':(exclude).relay' ':(exclude)odd' || true
  git -C "$ws" ls-files --others --exclude-standard -- . ':(exclude).relay' ':(exclude)odd' |
    while IFS= read -r f; do git -C "$ws" diff --no-index -- /dev/null "$f" || true; done
}

# --- run directories ----------------------------------------------------------
# <ws>: make .relay/runs and keep .relay/ and .atl/ out of git without touching .gitignore
lane_init_ws() {
  local ws="$1" ex
  mkdir -p "$ws/.relay/runs"
  ex="$(git -C "$ws" rev-parse --git-path info/exclude 2>/dev/null || true)"
  [ -n "$ex" ] || return 0
  case "$ex" in /*) ;; *) ex="$ws/$ex" ;; esac
  mkdir -p "$(dirname "$ex")"
  # .atl/ is gentle-ai's skill-registry cache: its UserPromptSubmit hook writes it into
  # any repo a Claude session (an inline lane included) runs in. Not project content.
  local p
  for p in .relay/ .atl/; do
    grep -qxF "$p" "$ex" 2>/dev/null || printf '%s\n' "$p" >> "$ex"
  done
}

# <ws> <feature> <id> <lane> -> new run dir; .relay/runs/<feature>/<id>/latest-<lane> points at it
lane_new_run() {
  local d="$1/.relay/runs/$2/$3" r
  r="$d/$4-$(date +%Y%m%dT%H%M%S)-$RANDOM"
  mkdir -p "$r"
  ln -sfn "$(basename "$r")" "$d/latest-$4"
  printf '%s' "$r"
}
