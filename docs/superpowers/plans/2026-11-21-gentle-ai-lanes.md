# gentle-ai Lanes Implementation Plan

> **For agentic workers:** execute task by task in order; steps use checkbox (`- [ ]`)
> syntax for tracking. (The superpowers `subagent-driven-development` / `executing-plans`
> skills are retired by Task 15 of this very plan — use them only for Tasks 0–14, or run
> the plan inline.)

**Goal:** Replace the relay's fixed execute→scout→validate cycle with `relay/lanes.sh`, a
delegation backend that a gentle-ai (ODD) Claude orchestrator calls only for a named
reason, plus an autopilot that drains an ODD feature document unattended.

**Architecture:** Each lane is one headless agent turn (`agy -p`, `opencode run`, or
`claude -p`) run inside a tmux window for visibility, with completion detected by an exit
file and an expected output file — no screen-scraping of idle prompts. Pure helpers
(doc parsing, scopes, worktree state) live in `relay/lanes/lib.sh`; the agent runner in
`relay/lanes/exec.sh`; the lane commands in `relay/lanes/flow.sh`; the unattended loop in
`relay/lanes/autopilot.sh`. Existing charters are reused with a lane-mode addendum.

**Tech Stack:** bash (WSL, GNU coreutils/sed/awk), tmux, git, `agy`, `opencode`, `claude`,
optional `relay_jev.py` / `relay_cite.py` / REA. Spec:
`docs/superpowers/specs/2026-11-21-gentle-ai-lanes-design.md`.

**Repo:** `~/projects/medina-agentic-relay-setup`, branch `design/gentle-ai-lanes`
(created from `origin/master` e22f9c3). `relay/relay.sh`, `relay/relay.ps1` and their
tests are **not modified** by any task.

---

## File map

| File | Responsibility |
|---|---|
| `relay/lanes.sh` | CLI entry: `explore write prebrief verify autopilot doctor status down` |
| `relay/lanes/lib.sh` | Pure helpers: ODD rows/specs, doc edits, scopes, worktree state, run dirs |
| `relay/lanes/exec.sh` | One headless agent turn in a tmux window: provider choice, agy→opencode fallback, retry, timeout, classification; Jev/cite/REA probes |
| `relay/lanes/flow.sh` | Lane commands: prompts, writer + scope enforcement, prebrief sandbox, verify chain, mutate |
| `relay/lanes/autopilot.sh` | Unattended drain of `odd/tasks/<feature>.md` |
| `relay/charters/lane-mode.md` | Addendum overriding bus paths for executor/scout/validator/mutator charters |
| `relay/charters/lane-explore.md` | Read-only explorer charter |
| `relay/charters/lane-inline.md` | Headless Claude writer charter (autopilot inline rows) |
| `relay/install-lanes.sh` | Back up + install lanes, charters and commands into `~/.claude` |
| `commands/lane.md`, `commands/implement.md`, `commands/relay-auto.md` | Slash commands |
| `tests/lanes/*` | assert helpers, stub agent, unit + integration tests, ODD fixture |

---

### Task 0: Spike — confirm headless agent behavior (needs the user's approval to run)

The whole design rests on `agy -p`, `opencode run` and `claude -p` working as one-shot
headless turns that can write files. The auto-mode classifier blocked running agy with
`--dangerously-skip-permissions` during planning, so this spike must be run by (or
approved by) the user.

**Files:**
- Create: `docs/lanes-spike.md`

- [ ] **Step 1: Run the three probes in a throwaway repo**

```bash
d="$(mktemp -d)"; cd "$d" && git init -q
P='Write the single word LANEOK into the file ok.txt in the current directory, then reply DONE.'
time timeout 180 agy -p "$P" --model gemini-3.8-flash-medium --dangerously-skip-permissions --add-dir "$d" > agy.log 2>&1; echo "agy exit=$?"; cat ok.txt; rm -f ok.txt
time timeout 180 agy -p "$P" --model gemini-3.8-flash-medium --dangerously-skip-permissions --add-dir "$d" --sandbox > agy-sb.log 2>&1; echo "agy --sandbox exit=$?"; cat ok.txt; rm -f ok.txt
time timeout 240 opencode run -m opencode/big-pickle "$P" > oc.log 2>&1; echo "opencode exit=$?"; cat ok.txt; rm -f ok.txt
time timeout 180 claude -p --model claude-sonnet-5-5 --permission-mode acceptEdits "$P" > cl.log 2>&1; echo "claude exit=$?"; cat ok.txt
```

Expected: each prints `exit=0` and `LANEOK`. Record for each: exit code, wall time,
whether `ok.txt` was written, any trust/permission prompt text in the log, and whether
opencode asked for permission (it has no `--auto` in `run` mode).

- [ ] **Step 2: Write `docs/lanes-spike.md` with the results table and the decision**

Decision rule:
- All four write `ok.txt` → proceed with the plan as written.
- `opencode run` blocks on permissions → add the flag it needs to the `opencode)` line of
  `lane_cmdline` in Task 6 and note it in the spike doc.
- `agy --sandbox` cannot write inside its own cwd → drop `--sandbox` from the `prebrief`
  role in `lane_cmdline` (Task 6); the temp-dir isolation still holds.
- `agy -p` cannot write files at all → **stop and return to brainstorming**: the lanes
  would need interactive `-i` panes, which changes Tasks 6–7.

- [ ] **Step 3: Commit**

```bash
git add docs/lanes-spike.md
git commit -m "docs: headless agent spike results for lanes"
```

---

### Task 1: Test scaffolding

**Files:**
- Create: `tests/lanes/assert.sh`, `tests/lanes/run_all.sh`, `tests/lanes/stub_agent.sh`,
  `tests/lanes/fixtures/odd/tasks/demo.md`

- [ ] **Step 1: Write `tests/lanes/assert.sh`**

```bash
# shellcheck shell=bash
# Minimal assertions for the lanes tests. Each test file sources this, calls t_*,
# and ends with t_done, which exits non-zero when anything failed.
T_FAILS=0; T_COUNT=0
t_ok()   { T_COUNT=$((T_COUNT + 1)); printf '  ok   %s\n' "$1"; }
t_bad()  { T_COUNT=$((T_COUNT + 1)); T_FAILS=$((T_FAILS + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
t_eq()   { if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "expected [$3] got [$2]"; fi; }
t_has()  { case "$2" in *"$3"*) t_ok "$1" ;; *) t_bad "$1" "[$3] not in [$2]" ;; esac; }
t_hasnt(){ case "$2" in *"$3"*) t_bad "$1" "[$3] unexpectedly in [$2]" ;; *) t_ok "$1" ;; esac; }
t_file() { if [ -f "$2" ]; then t_ok "$1"; else t_bad "$1" "missing file $2"; fi; }
t_nofile(){ if [ -e "$2" ]; then t_bad "$1" "unexpected file $2"; else t_ok "$1"; fi; }
t_true() { if eval "$2"; then t_ok "$1"; else t_bad "$1" "false: $2"; fi; }
t_done() { printf '%s: %d checks, %d failed\n' "$(basename "$0")" "$T_COUNT" "$T_FAILS"; [ "$T_FAILS" -eq 0 ]; }

# A throwaway git repo with one commit; prints its path.
t_repo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email lanes@test; git -C "$d" config user.name lanes-test
  mkdir -p "$d/src/a" "$d/src/b" "$d/odd/tasks"
  printf 'a\n' > "$d/src/a/one.txt"; printf 'b\n' > "$d/src/b/two.txt"; printf 'r\n' > "$d/README.md"
  git -C "$d" add -A; git -C "$d" commit -qm init
  printf '%s' "$d"
}
```

- [ ] **Step 2: Write `tests/lanes/stub_agent.sh`** (installed under the names `agy`,
  `opencode`, `claude` by the tests)

```bash
#!/usr/bin/env bash
# Stand-in for agy / opencode / claude in the lanes tests. Finds the dispatch argument
# (the one containing "RELAY LANE DISPATCH"), reads ROLE / TASK / IN SCOPE / OUTPUT from
# it, and behaves according to env:
#   STUB_<role>=ok|quota|hang|nooutput|stray|commit|limit   (default ok)
#   STUB_VERDICTS="FAIL PASS ..."   validator verdicts, consumed one per call
#   STUB_STATE=<dir>                counters + call log (calls.log)
#   STUB_SLEEP=<secs>               work time per call (default 0)
name="$(basename "$0")"
prompt=""
for a in "$@"; do case "$a" in *"RELAY LANE DISPATCH"*) prompt="$a" ;; esac; done
field() { printf '%s\n' "$prompt" | sed -n "s/^$1: //p" | head -1; }
role="$(field ROLE)"; task="$(field TASK)"; out="$(field OUTPUT)"; scope="$(field 'IN SCOPE')"
state="${STUB_STATE:-/tmp}"; mkdir -p "$state"
mode_var="STUB_${role}"; mode="${!mode_var:-ok}"
printf '%s %s %s start %s cwd=%s\n' "$name" "$role" "$task" "$(date +%s%N)" "$PWD" >> "$state/calls.log"

if [ "$mode" = quota ] && [ "$name" = agy ]; then
  echo "⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 3h."; exit 1
fi
if [ "$mode" = limit ] && [ "$name" = claude ]; then
  echo "Claude usage limit reached. /rate-limit-options"; exit 1
fi
[ "$mode" = hang ] && exec sleep 600
sleep "${STUB_SLEEP:-0}"

first_scope="${scope%% *}"
case "$role" in
  write|inline)
    if [ -n "$first_scope" ]; then mkdir -p "$first_scope"; printf '%s\n' "$task" >> "$first_scope/$task.txt"; fi
    [ "$mode" = stray ] && printf 'oops\n' > stray.txt
    [ "$mode" = commit ] && { git add -A; git commit -qm "stub commit" >/dev/null 2>&1; }
    body="## Changed
- $first_scope/$task.txt
CHECKS: PASS" ;;
  prebrief) body="# Pre-brief: $task
| R1 | \"clause\" | expected | probe | (Written: pre)" ;;
  evidence) body="# Evidence: $task
| Probe | Case | Written | Outcome |" ;;
  validator)
    n="$(cat "$state/vcount" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$state/vcount"
    v="$(printf '%s\n' ${STUB_VERDICTS:-PASS} | sed -n "${n}p")"; v="${v:-PASS}"
    body="VERDICT: $v" ;;
  *) body="stub $role output" ;;
esac
[ "$mode" = nooutput ] || { [ -n "$out" ] && printf '%s\n' "$body" > "$out"; }
printf '%s %s %s end %s\n' "$name" "$role" "$task" "$(date +%s%N)" >> "$state/calls.log"
echo DONE
```

- [ ] **Step 3: Write the ODD fixture `tests/lanes/fixtures/odd/tasks/demo.md`**

```markdown
# demo — lanes fixture

Objective: exercise every route the lanes autopilot handles.
Runner: `test -d src`

## Specs

- **S1** User (verbatim): "a must hold a marker per task"
  Derived: one file per task under src/a.
- **S2** User (verbatim): "b must hold a marker per task"
- S3 High-risk data rule (verbatim): "c is data; verify it independently"

## Tasks

- [ ] T1 S1 Marker in a (route: write; risk: low; In: src/a; commit: pending)
- [ ] T2 S2 Marker in b (route: write; risk: low; In: src/b; commit: pending)
- [ ] T3 S3 Data marker in c (route: inline; risk: high(data); In: src/c; after: T1; commit: pending)

## Log

- L1 User request (verbatim): "build the demo"
```

- [ ] **Step 4: Write `tests/lanes/run_all.sh`**

```bash
#!/usr/bin/env bash
# Runs every tests/lanes/test_*.sh; exits non-zero if any file fails.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$here"/test_*.sh; do
  printf '== %s\n' "$(basename "$t")"
  bash "$t" || rc=1
done
exit $rc
```

- [ ] **Step 5: Make executable and commit**

```bash
chmod +x tests/lanes/run_all.sh tests/lanes/stub_agent.sh
git add tests/lanes
git commit -m "test(lanes): assertion helpers, stub agent and ODD fixture"
```

---

### Task 2: ODD row parsing (`lib.sh`)

**Files:**
- Create: `relay/lanes/lib.sh`
- Test: `tests/lanes/test_lib_rows.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_lib_rows.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/../../relay/lanes/lib.sh"
doc="$here/fixtures/odd/tasks/demo.md"

row="$(lane_row "$doc" T3)"
t_has  "lane_row finds T3"            "$row" "Data marker in c"
t_eq   "lane_row misses unknown id"   "$(lane_row "$doc" T9)" ""
t_eq   "lane_row_id"                  "$(lane_row_id "$row")" "T3"
t_eq   "lane_row_mark pending"        "$(lane_row_mark "$row")" " "
t_eq   "route"                        "$(lane_row_route "$row")" "inline"
t_eq   "risk kv keeps parens"         "$(lane_row_kv "$row" risk)" "high(data)"
t_true "risk high"                    'lane_row_risk_high "$row"'
t_true "T1 not high"                  '! lane_row_risk_high "$(lane_row "$doc" T1)"'
t_eq   "In"                           "$(lane_row_in "$row")" "src/c"
t_eq   "after"                        "$(lane_row_after "$row")" "T1"
t_eq   "specs"                        "$(lane_row_specs "$row")" "S3"
t_eq   "title"                        "$(lane_row_title "$row")" "Data marker in c"
t_eq   "pending ids"                  "$(lane_pending_ids "$doc" | tr '\n' ' ')" "T1 T2 T3 "
t_eq   "route of ODD-style value"     "$(lane_row_route '- [ ] A1 S8/S9 x (route: inline, test-first; commit: e98)')" "inline"
t_eq   "specs from S8/S9"             "$(lane_row_specs '- [ ] A1 S8/S9 x (route: inline)' | tr '\n' ' ')" "S8 S9 "
t_eq   "In: is case-insensitive"      "$(lane_row_in '- [ ] A S1 x (route: write; in: `src/x`, src/y)')" "src/x src/y"
t_eq   "no parenthetical -> no route" "$(lane_row_route '- [ ] A S1 just text')" ""
t_done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/lanes/test_lib_rows.sh`
Expected: error `relay/lanes/lib.sh: No such file or directory`.

- [ ] **Step 3: Write `relay/lanes/lib.sh` (rows part)**

```bash
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/lanes/test_lib_rows.sh`
Expected: `test_lib_rows.sh: 17 checks, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add relay/lanes/lib.sh tests/lanes/test_lib_rows.sh
git commit -m "feat(lanes): parse ODD task rows"
```

---

### Task 3: Spec extraction and doc edits (`lib.sh`)

**Files:**
- Modify: `relay/lanes/lib.sh` (append)
- Test: `tests/lanes/test_lib_doc.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_lib_doc.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/../../relay/lanes/lib.sh"
src="$here/fixtures/odd/tasks/demo.md"
doc="$(mktemp)"; cp "$src" "$doc"

s1="$(lane_spec_text "$doc" S1)"
t_has   "S1 bullet verbatim"          "$s1" 'a must hold a marker per task'
t_has   "S1 continuation line"        "$s1" 'Derived: one file per task'
t_hasnt "S1 excludes S2"              "$s1" 'b must hold'
t_has   "plain '- S3' bullet"         "$(lane_spec_text "$doc" S3)" 'c is data'
t_has   "no ids -> all specs"         "$(lane_spec_text "$doc")" 'b must hold'
t_eq    "runner from header"          "$(lane_doc_runner "$doc")" 'test -d src'
t_has   "header excerpt"              "$(lane_doc_header "$doc")" 'Objective: exercise'
t_hasnt "header stops at ##"          "$(lane_doc_header "$doc")" '## Specs'

row="$(lane_row "$doc" T1)"
t_eq "row_with x + commit" "$(lane_row_with "$row" x abc123)" \
  '- [x] T1 S1 Marker in a (route: write; risk: low; In: src/a; commit: abc123)'
t_eq "row_with adds commit key" "$(lane_row_with '- [ ] Z S1 t (route: write)' x f00)" \
  '- [x] Z S1 t (route: write; commit: f00)'
t_eq "row_with no parenthetical" "$(lane_row_with '- [ ] Z S1 t' '!' f00)" '- [!] Z S1 t (commit: f00)'
t_eq "row_with mark only" "$(lane_row_with "$row" '~')" \
  '- [~] T1 S1 Marker in a (route: write; risk: low; In: src/a; commit: pending)'

lane_doc_replace_row "$doc" T1 "$(lane_row_with "$row" x abc123)"
t_eq "replace_row wrote it" "$(lane_row_mark "$(lane_row "$doc" T1)")" "x"
t_eq "pending after replace" "$(lane_pending_ids "$doc" | tr '\n' ' ')" "T2 T3 "

lane_doc_insert_after "$doc" T2 '- [ ] T2.f1 S2 Fix T2 (route: write; risk: low; In: src/b)'
t_eq "insert_after order" "$(lane_pending_ids "$doc" | tr '\n' ' ')" "T2 T2.f1 T3 "

lane_doc_log "$doc" "autopilot: hello"
t_eq "log numbering continues" "$(tail -n 1 "$doc")" "- L2 autopilot: hello"
t_done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/lanes/test_lib_doc.sh`
Expected: FAIL / `lane_spec_text: command not found`.

- [ ] **Step 3: Append to `relay/lanes/lib.sh`**

```bash
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
```

- [ ] **Step 4: Run both lib tests**

Run: `bash tests/lanes/test_lib_doc.sh && bash tests/lanes/test_lib_rows.sh`
Expected: `0 failed` on both.

- [ ] **Step 5: Commit**

```bash
git add relay/lanes/lib.sh tests/lanes/test_lib_doc.sh
git commit -m "feat(lanes): extract ODD specs verbatim and edit task rows"
```

---

### Task 4: Scopes and worktree state (`lib.sh`)

**Files:**
- Modify: `relay/lanes/lib.sh` (append)
- Test: `tests/lanes/test_lib_scope.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_lib_scope.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/../../relay/lanes/lib.sh"

t_true "disjoint"          '! lane_scopes_overlap "src/a" "src/b"'
t_true "same path"         'lane_scopes_overlap "src/a" "src/a"'
t_true "parent/child"      'lane_scopes_overlap "src" "src/a/x.sh"'
t_true "wildcard overlaps" 'lane_scopes_overlap "src/*" "docs"'
t_true "empty overlaps"    'lane_scopes_overlap "" "docs"'
t_true "in scope: dir"     'lane_path_in_scope "src/a/x.txt" "src/a"'
t_true "in scope: glob"    'lane_path_in_scope "src/a/x.sh" "src/*/x.sh"'
t_true "out of scope"      '! lane_path_in_scope "src/ab/x.txt" "src/a"'
t_true "dot = everything"  'lane_path_in_scope "any/thing" "."'

ws="$(t_repo)"
printf 'dirty\n' >> "$ws/src/b/two.txt"            # dirty before the lane
snaps="$(mktemp -d)"
lane_tree_state "$ws" > "$snaps/pre"
printf 'lane\n' >> "$ws/src/a/one.txt"              # lane edits tracked file in scope
mkdir -p "$ws/src/a/new"; printf 'n\n' > "$ws/src/a/new/f.txt"   # lane adds file in scope
printf 'stray\n' > "$ws/stray.txt"                 # lane adds file out of scope
printf 'more\n' >> "$ws/src/b/two.txt"             # lane edits an already-dirty file out of scope
rm "$ws/README.md"                                 # lane deletes tracked file out of scope
lane_tree_state "$ws" > "$snaps/post"

changed="$(lane_tree_delta "$snaps/pre" "$snaps/post" | tr '\n' ' ')"
t_eq "delta" "$changed" "README.md src/a/new/f.txt src/a/one.txt src/b/two.txt stray.txt "
bad="$(lane_tree_delta "$snaps/pre" "$snaps/post" | lane_out_of_scope "src/a" | tr '\n' ' ')"
t_eq "out of scope" "$bad" "README.md src/b/two.txt stray.txt "

for p in $bad; do lane_revert_path "$ws" "$p" "$snaps/pre"; done
t_nofile "stray removed"                 "$ws/stray.txt"
t_file   "deleted tracked file restored" "$ws/README.md"
t_eq     "dirty file back to pre-lane"   "$(cat "$ws/src/b/two.txt")" "$(printf 'b\ndirty')"
t_eq     "in-scope edit kept"            "$(tail -n 1 "$ws/src/a/one.txt")" "lane"

printf 'u\n' > "$ws/src/a/untracked.txt"
d="$(lane_diff "$ws")"
t_has   "diff shows tracked edit"   "$d" "+lane"
t_has   "diff shows untracked file" "$d" "untracked.txt"
t_hasnt "diff hides .relay"         "$d" ".relay"

lane_init_ws "$ws"
t_true "relay ignored by git" 'grep -qxF ".relay/" "$ws/.git/info/exclude"'
lane_init_ws "$ws"
t_eq "exclude written once" "$(grep -cxF '.relay/' "$ws/.git/info/exclude")" "1"
r="$(lane_new_run "$ws" demo T1 write)"
t_true "run dir made"       '[ -d "$r" ]'
t_eq   "latest link"        "$(readlink "$ws/.relay/runs/demo/T1/latest-write")" "$(basename "$r")"
t_done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/lanes/test_lib_scope.sh`
Expected: FAIL / `lane_scopes_overlap: command not found`.

- [ ] **Step 3: Append to `relay/lanes/lib.sh`**

```bash
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
# <ws>: make .relay/runs and keep .relay/ out of git without touching .gitignore
lane_init_ws() {
  local ws="$1" ex
  mkdir -p "$ws/.relay/runs"
  ex="$(git -C "$ws" rev-parse --git-path info/exclude 2>/dev/null || true)"
  [ -n "$ex" ] || return 0
  case "$ex" in /*) ;; *) ex="$ws/$ex" ;; esac
  mkdir -p "$(dirname "$ex")"
  grep -qxF '.relay/' "$ex" 2>/dev/null || printf '.relay/\n' >> "$ex"
}

# <ws> <feature> <id> <lane> -> new run dir; .relay/runs/<feature>/<id>/latest-<lane> points at it
lane_new_run() {
  local d="$1/.relay/runs/$2/$3" r
  r="$d/$4-$(date +%Y%m%dT%H%M%S)-$RANDOM"
  mkdir -p "$r"
  ln -sfn "$(basename "$r")" "$d/latest-$4"
  printf '%s' "$r"
}
```

- [ ] **Step 4: Run all lib tests**

Run: `for t in tests/lanes/test_lib_*.sh; do bash "$t"; done`
Expected: every file reports `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add relay/lanes/lib.sh tests/lanes/test_lib_scope.sh
git commit -m "feat(lanes): scope checks and revertable worktree snapshots"
```

---

### Task 5: Agent runner basics (`exec.sh`, pure parts)

**Files:**
- Create: `relay/lanes/exec.sh`
- Test: `tests/lanes/test_exec_pure.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_exec_pure.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RELAY_HOME; RELAY_HOME="$(cd "$here/../../relay" && pwd)"
unset RELAY_AGY_MODEL RELAY_AGY_MODEL_EXECUTOR RELAY_AGY_MODEL_SCOUT RELAY_AGY_MODEL_MUTATOR RELAY_OPENCODE_MODEL RELAY_LANES_SAFE
tmp="$(mktemp -d)"; export RELAY_LANES_STATE="$tmp/state"
. "$here/assert.sh"; . "$here/../../relay/lanes/lib.sh"; . "$here/../../relay/lanes/exec.sh"

printf 'working...\n⚠ Individual quota reached. Please upgrade. Resets in 3h.\n' > "$tmp/q.log"
printf 'Claude usage limit reached\n' > "$tmp/l.log"
printf 'all good\n' > "$tmp/ok.log"
t_eq "agy quota"        "$(lane_classify_log "$tmp/q.log" agy)" "quota"
t_eq "claude limit"     "$(lane_classify_log "$tmp/l.log" claude)" "limit"
t_eq "clean log"        "$(lane_classify_log "$tmp/ok.log" agy)" ""
t_eq "quota ignored for claude" "$(lane_classify_log "$tmp/q.log" claude)" ""

t_eq "write model"      "$(RELAY_AGY_MODEL_EXECUTOR=m-x lane_model_for agy write)" "m-x"
t_eq "scout default"    "$(lane_model_for agy evidence)" "gemini-3.8-flash-medium"
t_eq "opencode default" "$(lane_model_for opencode write)" "opencode/big-pickle"
t_eq "validator model"  "$(lane_model_for claude validator)" "claude-sonnet-5-5"
t_eq "inline model"     "$(lane_model_for claude inline)" "claude-opus-5-5"

c="$(lane_cmdline agy m /w 'hi there' prebrief)"
t_has "agy print mode"  "$c" " -p hi\\ there"
t_has "agy sandbox for prebrief" "$c" "--sandbox"
t_hasnt "no sandbox for write" "$(lane_cmdline agy m /w hi write)" "--sandbox"
t_has "claude validator acceptEdits" "$(lane_cmdline claude m /w hi validator)" "--permission-mode acceptEdits"
t_has "claude inline bypass" "$(lane_cmdline claude m /w hi inline)" "--permission-mode bypassPermissions"
t_has "safe mode inline" "$(RELAY_LANES_SAFE=1 lane_cmdline claude m /w hi inline)" "--permission-mode acceptEdits"
t_has "opencode run" "$(lane_cmdline opencode m /w hi write)" " run -m m hi"

t_true "not cooling"    '! lane_agy_cooling'
lane_mark_agy_quota
t_true "cooling after quota" 'lane_agy_cooling'
t_true "cooldown expires" '! RELAY_QUOTA_COOLDOWN=0 lane_agy_cooling_check_at "$(( $(date +%s) + 1 ))"'
t_done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/lanes/test_exec_pure.sh`
Expected: `relay/lanes/exec.sh: No such file or directory`.

- [ ] **Step 3: Write `relay/lanes/exec.sh` (pure part)**

```bash
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
```

- [ ] **Step 4: Run the test**

Run: `bash tests/lanes/test_exec_pure.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add relay/lanes/exec.sh tests/lanes/test_exec_pure.sh
git commit -m "feat(lanes): agent command lines, fault classification, quota cooldown"
```

---

### Task 6: Agent runner in tmux (`lane_exec`)

**Files:**
- Modify: `relay/lanes/exec.sh` (append)
- Create: `tests/lanes/env.sh` (shared stub setup)
- Test: `tests/lanes/test_exec_run.sh`

- [ ] **Step 1: Write `tests/lanes/env.sh`**

```bash
# shellcheck shell=bash
# Shared setup for tests that run lanes against stub agents in a private tmux session.
LANES_TEST_BIN="$(mktemp -d)"
for n in agy opencode claude; do ln -s "$here/stub_agent.sh" "$LANES_TEST_BIN/$n"; done
export PATH="$LANES_TEST_BIN:$PATH"
export STUB_STATE; STUB_STATE="$(mktemp -d)"
export RELAY_HOME; RELAY_HOME="$(cd "$here/../../relay" && pwd)"
export RELAY_LANES_SESSION="lanestest$$"
export RELAY_LANES_STATE="$STUB_STATE/lanes-state"
export RELAY_LANE_TIMEOUT=8 RELAY_LANE_POLL=0.2 RELAY_LANE_LINGER=0 RELAY_JEV=0 RELAY_CITE=0 RELAY_REA=0
lanes_test_cleanup() { tmux kill-session -t "$RELAY_LANES_SESSION" 2>/dev/null || true; rm -rf "$LANES_TEST_BIN"; }
trap lanes_test_cleanup EXIT
```

- [ ] **Step 2: Write the failing test `tests/lanes/test_exec_run.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
. "$RELAY_HOME/lanes/lib.sh"; . "$RELAY_HOME/lanes/exec.sh"
ws="$(t_repo)"; run="$ws/.relay/runs/x"; mkdir -p "$run"
P() { printf 'RELAY LANE DISPATCH\nROLE: %s\nTASK: T1\nOUTPUT: %s\n' "$1" "$2"; }

st="$(lane_exec "$run" s1 explore "$ws" "$(P explore "$run/map.md")" "$run/map.md")"
t_eq   "ok run"              "$st" "ok"
t_file "output written"      "$run/map.md"
t_has  "step json"           "$(cat "$run/s1.json")" '"status": "ok"'
t_has  "agy used"            "$(cat "$STUB_STATE/calls.log")" "agy explore T1 start"

: > "$STUB_STATE/calls.log"
st="$(STUB_explore=quota lane_exec "$run" s2 explore "$ws" "$(P explore "$run/m2.md")" "$run/m2.md")"
t_eq  "quota falls back"     "$st" "ok"
t_has "opencode took over"   "$(cat "$STUB_STATE/calls.log")" "opencode explore T1 end"
t_has "json records route"   "$(cat "$run/s2.json")" 'agy:failed opencode:ok'

: > "$STUB_STATE/calls.log"
lane_exec "$run" s3 explore "$ws" "$(P explore "$run/m3.md")" "$run/m3.md" >/dev/null
t_hasnt "cooldown skips agy" "$(cat "$STUB_STATE/calls.log")" "agy explore"
rm -f "$RELAY_LANES_STATE/agy-quota-at"

: > "$STUB_STATE/calls.log"
st="$(STUB_explore=nooutput lane_exec "$run" s4 explore "$ws" "$(P explore "$run/m4.md")" "$run/m4.md")"
t_eq "no output -> failed after retry" "$st" "failed"
t_eq "exactly two attempts" "$(grep -c 'explore T1 start' "$STUB_STATE/calls.log")" "2"
t_has "both tries recorded" "$(cat "$run/s4.json")" 'agy:failed agy:failed'

st="$(STUB_explore=hang RELAY_LANE_TIMEOUT=2 lane_exec "$run" s5 explore "$ws" "$(P explore "$run/m5.md")" "$run/m5.md")"
t_eq "hang -> stalled" "$st" "stalled"

st="$(STUB_validator=limit lane_exec "$run" s6 validator "$ws" "$(P validator "$run/v.md")" "$run/v.md")"
t_eq "claude limit, no fallback" "$st" "limit"
t_done
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash tests/lanes/test_exec_run.sh`
Expected: FAIL / `lane_exec: command not found`.

- [ ] **Step 4: Append to `relay/lanes/exec.sh`**

```bash
lane_tmux_ready() {
  tmux has-session -t "$LANES_SESSION" 2>/dev/null || tmux new-session -d -s "$LANES_SESSION" -n home bash
}

# <run> <tag> <provider> <model> <cwd> <prompt> <role> -> exited | timeout
# Writes <run>/<tag>.sh (runner), <tag>.log (tee'd output), <tag>.exit (exit code).
lane_run_once() {
  local run="$1" tag="$2" provider="$3" model="$4" cwd="$5" prompt="$6" role="$7"
  local runner="$run/$tag.sh" log="$run/$tag.log" code="$run/$tag.exit" win deadline
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export PATH=%q\n' "$(lane_path)"
    # tmux starts the window from the tmux SERVER's environment, not ours, so pass
    # through what agents and the test stubs need explicitly.
    env | grep -E '^(STUB_[A-Za-z_]+|RELAY_[A-Z_]+|ANTHROPIC_[A-Z_]+|CLAUDE_[A-Z_]+|GEMINI_[A-Z_]+|GOOGLE_[A-Z_]+|OPENCODE_[A-Z_]+)=' |
      while IFS='=' read -r k v; do printf 'export %s=%q\n' "$k" "$v"; done || true
    printf 'cd %q || { echo 1 > %q; exit 1; }\n' "$cwd" "$code"
    printf '%s < /dev/null 2>&1 | tee %q\n' "$(lane_cmdline "$provider" "$model" "$cwd" "$prompt" "$role")" "$log"
    printf 'echo "${PIPESTATUS[0]}" > %q\n' "$code"
  } > "$runner"
  chmod +x "$runner"
  lane_tmux_ready
  win="$(tmux new-window -d -P -F '#{window_id}' -t "$LANES_SESSION:" -n "$(basename "$(dirname "$run")")-$tag" \
         "bash $(printf '%q' "$runner"); sleep ${RELAY_LANE_LINGER:-5}")"
  deadline=$(( $(date +%s) + ${RELAY_LANE_TIMEOUT:-1800} ))
  while [ ! -f "$code" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      tmux kill-window -t "$win" 2>/dev/null || true; printf 'timeout'; return 0
    fi
    # agy can sit on its quota banner instead of exiting; end the turn so the caller
    # classifies it and falls back.
    if [ "$provider" = agy ] && [ -f "$log" ] && tail -n 40 "$log" | grep -qiE "$QUOTA_PAT"; then
      tmux kill-window -t "$win" 2>/dev/null || true; printf 'exited'; return 0
    fi
    sleep "${RELAY_LANE_POLL:-3}"
  done
  printf 'exited'
}

# <run> <step> <role> <cwd> <prompt> <expect-file>
#   -> ok | failed | stalled | limit | auth     (also writes <run>/<step>.json)
# One retry for a turn that ends without its output or times out. An agy quota fault
# moves to opencode without spending the retry. Claude roles never fall back.
lane_exec() {
  local run="$1" step="$2" role="$3" cwd="$4" prompt="$5" expect="$6"
  local provider model st fault n=0 attempt=1 tries="" t0
  t0="$(date +%s)"
  case "$role" in
    validator|inline) provider=claude ;;
    *) provider=agy; lane_agy_cooling && provider=opencode ;;
  esac
  while :; do
    n=$((n + 1))
    model="$(lane_model_for "$provider" "$role")"
    rm -f "$expect"
    st="$(lane_run_once "$run" "$step-$n" "$provider" "$model" "$cwd" "$prompt" "$role")"
    if [ "$st" = exited ] && [ -s "$expect" ]; then tries="$tries $provider:ok"; st=ok; break; fi
    [ "$st" = exited ] && st=failed
    tries="$tries $provider:$st"
    fault="$(lane_classify_log "$run/$step-$n.log" "$provider")"
    if [ "$fault" = quota ] && [ "$provider" = agy ] && [ "${RELAY_NO_OPENCODE_FALLBACK:-0}" != "1" ]; then
      lane_mark_agy_quota
      lanes_warn "agy quota exhausted - $step moves to opencode"
      provider=opencode; continue
    fi
    if [ "$fault" = limit ] || [ "$fault" = auth ]; then st="$fault"; break; fi
    if [ "$attempt" -ge 2 ]; then [ "$st" = timeout ] && st=stalled; break; fi
    attempt=$((attempt + 1))
  done
  printf '{"step": "%s", "role": "%s", "status": "%s", "tries": "%s", "seconds": %s}\n' \
    "$step" "$role" "$st" "${tries# }" "$(( $(date +%s) - t0 ))" > "$run/$step.json"
  printf '%s' "$st"
}
```

- [ ] **Step 5: Run the exec tests**

Run: `bash tests/lanes/test_exec_run.sh && bash tests/lanes/test_exec_pure.sh`
Expected: `0 failed` on both.

- [ ] **Step 6: Commit**

```bash
git add relay/lanes/exec.sh tests/lanes/env.sh tests/lanes/test_exec_run.sh
git commit -m "feat(lanes): headless agent turns in tmux with fallback, retry and timeout"
```

---

### Task 7: Lane charters

**Files:**
- Create: `relay/charters/lane-mode.md`, `relay/charters/lane-explore.md`, `relay/charters/lane-inline.md`

No automated test (content). Task 9/10 integration tests assert the prompts reference them.

- [ ] **Step 1: Write `relay/charters/lane-mode.md`**

```markdown
# Lane mode — addendum to your role charter

You were started by `lanes.sh` for **one bounded turn**, not as a long-lived relay pane.
Your role charter (executor.md, scout.md, validator.md or mutator.md) still governs *how*
you work. This addendum overrides only *where things are* and *when you stop*.

## What changes

- **Inputs come from the dispatch, not the bus.** The dispatch names `SPECS` (a verbatim
  excerpt of the ODD feature document: header, your task row, and its `S#` specs),
  `FEATURE DOC` (the full document, read-only), and, depending on role, `PREBRIEF`,
  `EVIDENCE`, `DIFF`, `RESULT`, `SNAPSHOT`. Where your charter says `.relay/tasks/NNN`,
  read `SPECS`; `.relay/results/NNN` → `RESULT`; `.relay/evidence/NNN` → `EVIDENCE`.
- **Output goes to `OUTPUT`.** Wherever your charter names a `.relay/...` output path,
  write to the `OUTPUT` path instead. The lane is judged by that file existing.
- **Requirements are the `S#` specs.** Wherever your charter says "requirement R<n>", use
  the spec ids (`S1`, `S2`, ...) from `SPECS`.
- **Never edit `odd/tasks/*.md`.** The orchestrator (or autopilot) is its only writer.
- **Never commit, push or branch.** Leave changes in the working tree.
- **No liveness probes, no watchdog duty, no waiting for further files.** Finish the
  turn, make sure `OUTPUT` exists, and exit.

## Per role

- **write** (executor.md): stay inside `IN SCOPE`; any change outside it is reverted
  automatically and recorded as a scope violation. `OUTPUT` is your result file: start it
  with `## Changed` listing every file you touched (one `- path` per line), then the
  checks you ran with their exit codes, and end with exactly one line
  `CHECKS: PASS`, `CHECKS: FAIL` or `CHECKS: NONE <why no runnable check exists>`.
- **prebrief** (scout.md, pre-brief section): you are in a directory that contains only
  `specs.md` and your charters. There is no code and you must not look for any. Write the
  pre-brief table, deriving every expected value from a quoted clause of `SPECS`; a spec
  you cannot turn into an expected value goes under "Cannot derive an expectation".
- **evidence** (scout.md): start from `PREBRIEF`, run its probes against the candidate,
  then gather evidence as your charter says. `DIFF` is the candidate (it is uncommitted);
  `RESULT`, when given, is the writer's claim. Evidence format unchanged, `Written`
  column included. No verdict.
- **validator** (validator.md): grade `DIFF` against `SPECS` using `PREBRIEF` and
  `EVIDENCE`. Keep the verdict format: the first line of `OUTPUT` is
  `VERDICT: PASS`, `VERDICT: PASS-WITH-CONCERNS` or `VERDICT: FAIL`. On a FAIL, do **not**
  write a task file: add a `## Follow-up` section stating exactly what the fix must
  achieve, by spec id. The autopilot turns it into a follow-up row.
- **mutate** (mutator.md): `SNAPSHOT` is your isolated copy (the charter's
  `.relay/mutants/<task-id>/`). Never touch the workspace outside it.
```

- [ ] **Step 2: Write `relay/charters/lane-explore.md`**

```markdown
# Explore lane — read-only map

You were sent because understanding this task needs more than a few lookups. Your output
replaces the orchestrator's own exploration, so it must be precise, short and evidenced.

- **Read-only.** Do not create, edit, delete or format any file except `OUTPUT`. Do not
  run anything that writes (builds that write artifacts, installs, formatters, git
  commands other than read-only ones).
- Answer `QUESTION` (or, when absent, "what must change to satisfy `SPECS`, and where").
- `OUTPUT` format:

      # Map: <task id>
      ## Answer
      <3-8 sentences>
      ## Evidence
      | Claim | path:line |
      ## Where a change would go
      - path:line — what and why
      ## Unknowns
      - what you could not establish, and what would establish it

- Every claim carries a `path:line`. No `path:line`, no claim.
- Stop when the question is answered. Under 150 lines.
```

- [ ] **Step 3: Write `relay/charters/lane-inline.md`**

```markdown
# Inline lane — headless ODD worker

You are Claude, running headless for an unattended ODD autopilot. You implement exactly
one task row of an ODD feature document, the way the interactive orchestrator would have
done it inline.

- Read `SPECS` first; consult `FEATURE DOC` only for context. The `S#` text is
  authoritative and verbatim; do not reinterpret it.
- **Test-first** when a relevant runnable test and a clear expected outcome exist: write
  one failing test per spec this task covers, see it fail, implement, see it pass. Add one
  test per existing command or option you touched proving its old behavior holds. Nothing
  else. Without a meaningful runnable test, say why under CHECKS.
- Stay inside `IN SCOPE`. Changes outside it are reverted automatically.
- **Do not commit, push or branch, and never edit `odd/tasks/*.md`.** The autopilot
  commits and updates the document from your `OUTPUT` and its own checks.
- No questions to a human: none is present. If a genuine decision blocks you (scope,
  destructive or irreversible impact, security exposure), do no partial work on that
  point and say so in `OUTPUT` under `## Needs a decision`.
- `OUTPUT` format: `## Changed` (one `- path` per line), `## Checks` (command, exit
  code, result line), optional `## Needs a decision`, and a final line
  `CHECKS: PASS`, `CHECKS: FAIL` or `CHECKS: NONE <why>`.
```

- [ ] **Step 4: Commit**

```bash
git add relay/charters/lane-mode.md relay/charters/lane-explore.md relay/charters/lane-inline.md
git commit -m "feat(lanes): lane-mode addendum, explore and inline charters"
```

---

### Task 8: Lane commands — explore and write (`flow.sh`, `lanes.sh`)

**Files:**
- Create: `relay/lanes/flow.sh`, `relay/lanes.sh`
- Test: `tests/lanes/test_flow_write.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_flow_write.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
L="$RELAY_HOME/lanes.sh"
ws="$(t_repo)"; cp "$here/fixtures/odd/tasks/demo.md" "$ws/odd/tasks/demo.md"
git -C "$ws" add -A; git -C "$ws" commit -qm doc

out="$(bash "$L" explore -w "$ws" --doc odd/tasks/demo.md --task T1 --question "where is a?")"
t_has "explore reports ok" "$out" "LANE explore ok"
run="${out##* }"
t_file "map written" "$run/map.md"
t_has  "specs excerpt has S1" "$(cat "$run/specs.md")" "a must hold a marker"
t_hasnt "specs excerpt omits S2" "$(cat "$run/specs.md")" "b must hold"
t_has  "dispatch names explore charter" "$(cat "$run"/explore-1.sh)" "lane-explore.md"

out="$(bash "$L" write -w "$ws" --doc odd/tasks/demo.md --task T1)"
t_has  "write ok" "$out" "LANE write ok"
t_file "writer output in scope" "$ws/src/a/T1.txt"

out="$(STUB_write=stray bash "$L" write -w "$ws" --doc odd/tasks/demo.md --task T2)"
t_has    "stray -> scope-violation" "$out" "LANE write scope-violation"
t_nofile "stray reverted" "$ws/stray.txt"
t_file   "in-scope work kept" "$ws/src/b/T2.txt"
run="${out##* }"
t_has    "violation recorded" "$(cat "$run/scope-violations.txt")" "stray.txt"

head0="$(git -C "$ws" rev-parse HEAD)"
out="$(STUB_write=commit bash "$L" write -w "$ws" --doc odd/tasks/demo.md --task T2)"
t_eq  "writer commit undone" "$(git -C "$ws" rev-parse HEAD)" "$head0"
t_has "still ok" "$out" "LANE write ok"

out="$(bash "$L" write -w "$ws" --doc odd/tasks/demo.md --task T9 2>&1 || true)"
t_has "unknown task fails" "$out" "no row T9"
t_done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/lanes/test_flow_write.sh`
Expected: `relay/lanes.sh: No such file or directory`.

- [ ] **Step 3: Write `relay/lanes/flow.sh` (explore + write part)**

```bash
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
```

- [ ] **Step 4: Write `relay/lanes.sh`**

```bash
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
```

- [ ] **Step 5: Run the test**

Run: `chmod +x relay/lanes.sh && bash tests/lanes/test_flow_write.sh`
Expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add relay/lanes.sh relay/lanes/flow.sh tests/lanes/test_flow_write.sh
git commit -m "feat(lanes): explore and write lanes with scope enforcement"
```

---

### Task 9: Verify chain — prebrief sandbox, evidence, verdict, mutate (`flow.sh`)

**Files:**
- Modify: `relay/lanes/flow.sh` (append)
- Test: `tests/lanes/test_flow_verify.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_flow_verify.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
L="$RELAY_HOME/lanes.sh"
ws="$(t_repo)"; cp "$here/fixtures/odd/tasks/demo.md" "$ws/odd/tasks/demo.md"
git -C "$ws" add -A; git -C "$ws" commit -qm doc
mkdir -p "$ws/src/c"; printf 'c\n' > "$ws/src/c/data.txt"     # the candidate

out="$(bash "$L" verify -w "$ws" --doc odd/tasks/demo.md --task T3)"
t_has "verify PASS" "$out" "LANE verify PASS"
run="${out##* }"
calls="$(cat "$STUB_STATE/calls.log")"
order="$(grep -oE '(prebrief|evidence|validator) T3 start' "$STUB_STATE/calls.log" | awk '{print $1}' | tr '\n' ' ')"
t_eq  "chain order" "$order" "prebrief evidence validator "
pb_cwd="$(grep 'prebrief T3 start' "$STUB_STATE/calls.log" | sed 's/.*cwd=//')"
t_hasnt "prebrief ran outside the repo" "$pb_cwd" "$ws"
t_has   "validator is claude" "$calls" "claude validator T3"
t_has   "diff captured" "$(cat "$run/diff.patch")" "src/c/data.txt"
t_file  "prebrief copied into verify run" "$run/prebrief.md"
t_has   "validator prompt names evidence" "$(cat "$run"/validator-1.sh)" "EVIDENCE: $run/evidence.md"

rm -f "$STUB_STATE/vcount"
out="$(STUB_VERDICTS="FAIL" bash "$L" verify -w "$ws" --doc odd/tasks/demo.md --task T3)"
t_has "verify FAIL" "$out" "LANE verify FAIL"

out="$(STUB_evidence=nooutput bash "$L" verify -w "$ws" --doc odd/tasks/demo.md --task T3)"
t_has "no evidence is not a pass" "$out" "LANE verify no-evidence"

rm -f "$STUB_STATE/vcount"
out="$(bash "$L" verify -w "$ws" --doc odd/tasks/demo.md --task T3 --mutate)"
sleep 2
t_true "mutation lane ran in background" 'grep -q "mutate T3" "$STUB_STATE/calls.log"'
t_done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/lanes/test_flow_verify.sh`
Expected: FAIL / `cmd_verify: command not found`.

- [ ] **Step 3: Append to `relay/lanes/flow.sh`**

```bash
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
```

- [ ] **Step 4: Run the test**

Run: `bash tests/lanes/test_flow_verify.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add relay/lanes/flow.sh tests/lanes/test_flow_verify.sh
git commit -m "feat(lanes): verify chain with sandboxed prebrief, verdicts and mutation"
```

---

### Task 10: Autopilot (`autopilot.sh`)

**Files:**
- Create: `relay/lanes/autopilot.sh`
- Test: `tests/lanes/test_autopilot.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_autopilot.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
L="$RELAY_HOME/lanes.sh"
fresh() { local w; w="$(t_repo)"; cp "$here/fixtures/odd/tasks/demo.md" "$w/odd/tasks/demo.md"
          git -C "$w" add -A; git -C "$w" commit -qm doc; printf '%s' "$w"; }
mark() { local r; r="$(grep -E "^- \[.\] $2 " "$1/odd/tasks/demo.md")"; printf '%s' "${r:3:1}"; }

# 1. happy path: T1+T2 parallel low-risk writes, T3 high-risk inline + verify
ws="$(fresh)"
rc=0; STUB_SLEEP=1 bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || rc=$?
t_eq "drained exit 0" "$rc" "0"
t_eq "T1 done" "$(mark "$ws" T1)" "x"; t_eq "T2 done" "$(mark "$ws" T2)" "x"; t_eq "T3 done" "$(mark "$ws" T3)" "x"
t_eq "3 task commits + doc commit" "$(git -C "$ws" rev-list --count HEAD)" "6"
t_has "T1 commit recorded" "$(grep -E '^- \[x\] T1 ' "$ws/odd/tasks/demo.md")" "commit: $(git -C "$ws" log --format=%h --grep 'T1' -1)"
t_true "tree clean after run" '[ -z "$(git -C "$ws" status --porcelain)" ]'
t_has "log says drained" "$(cat "$ws/odd/tasks/demo.md")" "autopilot: queue drained"
s1="$(grep 'agy write T1 start' "$STUB_STATE/calls.log" | awk '{print $5}')"
e2="$(grep 'agy write T2 end' "$STUB_STATE/calls.log" | awk '{print $5}')"
s2="$(grep 'agy write T2 start' "$STUB_STATE/calls.log" | awk '{print $5}')"
e1="$(grep 'agy write T1 end' "$STUB_STATE/calls.log" | awk '{print $5}')"
t_true "T1 and T2 overlapped (parallel)" '[ "$s1" -lt "$e2" ] && [ "$s2" -lt "$e1" ]'
t_true "T3 inline went to claude" 'grep -q "claude inline T3" "$STUB_STATE/calls.log"'

# 2. FAIL then PASS: follow-up row, root closed by follow-up's commit
: > "$STUB_STATE/calls.log"; rm -f "$STUB_STATE/vcount"
ws="$(fresh)"
STUB_VERDICTS="FAIL PASS" bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || true
t_eq "T3 closed" "$(mark "$ws" T3)" "x"
t_eq "T3.f1 closed" "$(mark "$ws" T3.f1)" "x"

# 3. FAIL twice: blocked, needs a decision, exit 4
rm -f "$STUB_STATE/vcount"
ws="$(fresh)"
rc=0; STUB_VERDICTS="FAIL FAIL" bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || rc=$?
t_eq "T3 blocked" "$(mark "$ws" T3)" "!"
t_eq "T3.f1 blocked" "$(mark "$ws" T3.f1)" "!"
t_has "needs decision logged" "$(cat "$ws/odd/tasks/demo.md")" "Needs your decision: T3.f1 failed twice"
t_eq "T1 still done" "$(mark "$ws" T1)" "x"

# 4. Claude limit: inline row blocked, independent write rows still run
rm -f "$STUB_STATE/vcount"
ws="$(fresh)"
STUB_inline=limit bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || true
t_eq "T3 blocked on limit" "$(mark "$ws" T3)" "!"
t_has "limit logged" "$(cat "$ws/odd/tasks/demo.md")" "Needs your decision: Claude limit"
t_eq "T2 done anyway" "$(mark "$ws" T2)" "x"

# 5. dirty tree refused; STOP honoured
ws="$(fresh)"; printf 'x\n' >> "$ws/README.md"
out="$(bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md 2>&1 || true)"
t_has "dirty tree refused" "$out" "clean tree"
ws="$(fresh)"; mkdir -p "$ws/.relay"; touch "$ws/.relay/STOP"
bash "$L" autopilot -w "$ws" --doc odd/tasks/demo.md >/dev/null 2>&1 || true
t_eq "STOP: nothing ran" "$(mark "$ws" T1)" " "
t_done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/lanes/test_autopilot.sh`
Expected: FAIL / `cmd_autopilot: command not found`.

- [ ] **Step 3: Write `relay/lanes/autopilot.sh`**

```bash
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
```

- [ ] **Step 4: Run the autopilot test, then the whole suite**

Run: `bash tests/lanes/test_autopilot.sh && bash tests/lanes/run_all.sh`
Expected: `0 failed` everywhere. Scenario 3 expects exit 4 and that is captured by `|| rc=$?`.

- [ ] **Step 5: Commit**

```bash
git add relay/lanes/autopilot.sh tests/lanes/test_autopilot.sh
git commit -m "feat(lanes): unattended autopilot over ODD task rows"
```

---

### Task 11: `doctor`, `status`, `down`

**Files:**
- Modify: `relay/lanes/flow.sh` (append)
- Test: `tests/lanes/test_ops.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_ops.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
L="$RELAY_HOME/lanes.sh"
out="$(bash "$L" doctor 2>&1)"
t_has "doctor lists agy"       "$out" "agy"
t_has "doctor lists gentle-ai" "$out" "gentle-ai"
t_has "doctor lists engram"    "$out" "engram"
t_has "doctor reports quota"   "$out" "agy quota"
ws="$(t_repo)"; cp "$here/fixtures/odd/tasks/demo.md" "$ws/odd/tasks/demo.md"
bash "$L" explore -w "$ws" --doc odd/tasks/demo.md --task T1 >/dev/null
t_has "status shows last step" "$(bash "$L" status -w "$ws" 2>&1)" '"status": "ok"'
bash "$L" down
t_true "down kills session" '! tmux has-session -t "$RELAY_LANES_SESSION" 2>/dev/null'
t_done
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/lanes/test_ops.sh`
Expected: FAIL / `cmd_doctor: command not found`.

- [ ] **Step 3: Append to `relay/lanes/flow.sh`**

```bash
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
```

- [ ] **Step 4: Run the full suite**

Run: `bash tests/lanes/run_all.sh`
Expected: every file `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add relay/lanes/flow.sh tests/lanes/test_ops.sh
git commit -m "feat(lanes): doctor, status and down"
```

---

### Task 12: Slash commands

**Files:**
- Create: `commands/lane.md`
- Modify (rewrite): `commands/implement.md`, `commands/relay-auto.md`
- Delete: `commands/brainstorm.md`, `commands/write-plan.md` (aliases of retired skills)

- [ ] **Step 1: Write `commands/lane.md`**

```markdown
---
description: Run one relay lane (explore, write, prebrief, verify) for a named delegation reason
---

You are the gentle-ai ODD parent. Work inline by default. Use a lane only when one of
these reasons truly holds, and say which in one line before calling it:

| Lane | Reason |
|---|---|
| `explore` | Understanding needs more than ~3 inline calls / ~10k tokens or >5 sequential lookups |
| `write` | Two or more independent units with disjoint `In:` scopes, each several minutes of work; or the long-session context backstop |
| `verify` | The change names a high-risk item: data, security, shared contracts, concurrency, delivery, or no test that would catch a regression |

Never for file count, size alone, or price.

The row must exist in `odd/tasks/<feature>.md` with `route`, `risk` and `In:` in its
parenthetical, e.g. `(route: write; risk: low; In: src/a tests/a; commit: pending)`.

Run (from the workspace):

    ~/.claude/relay/lanes.sh $ARGUMENTS

e.g. `verify --doc odd/tasks/auth.md --task T3`. For a high-risk row, start
`prebrief --task T3` *before* you write the code, in the background, so its probes come
from the specs alone.

The last stdout line is `LANE <lane> <status> <run-dir>`. A launched lane is a wait
event: end your turn while it runs and resume on completion. Then read the run dir's
output (`map.md`, `result.md`, `verdict.md`) yourself — a lane's self-report is not proof.
You are the only writer of the feature doc: check a row off only with observed proof and
record the commit; on `FAIL`, add the follow-up row from `## Follow-up`.
```

- [ ] **Step 2: Rewrite `commands/implement.md`**

```markdown
---
description: Drain an ODD feature document unattended with the lanes autopilot
---

1. Find the feature document: `$ARGUMENTS` if given, else the most recently modified
   `odd/tasks/*.md` with unchecked rows. If there is none, stop and say so — ODD creates
   the document; this command only executes it.
2. Check every pending row has `route` (inline | write | explore), `risk`
   (low | high(<item>)) and `In:` in its parenthetical. Fill in missing ones from the specs
   and say what you added. Confirm the header has a `Runner:` command; without one,
   low-risk rows are committed UNVERIFIED — tell the user.
3. Commit or stash so the tree is clean outside `odd/` and `.relay/`.
4. Run in the background and end your turn:

       ~/.claude/relay/lanes.sh autopilot --doc <doc>

5. On completion (exit 0 drained/stopped, 4 needs a decision), read `## Log`. Reconcile
   the Engram mirror `odd/<feature>/tasks` with the document, then report: rows done with
   commits, follow-ups, blocked rows with the exact decision each needs, and any
   UNVERIFIED rows.

Stop early: `touch .relay/STOP`.
```

- [ ] **Step 3: Rewrite `commands/relay-auto.md`**

```markdown
---
description: Alias for /implement — drain an ODD feature document with the lanes autopilot
---

Follow `/implement` exactly with `$ARGUMENTS`. The legacy four-pane relay autopilot is
still available as `~/.claude/relay/relay.sh autopilot` for task files in the old format.
```

- [ ] **Step 4: Delete the retired aliases and commit**

```bash
git rm -q commands/brainstorm.md commands/write-plan.md
git add commands/lane.md commands/implement.md commands/relay-auto.md
git commit -m "feat(lanes): /lane command; /implement and /relay-auto drive the lanes autopilot"
```

---

### Task 13: Installer

**Files:**
- Create: `relay/install-lanes.sh`
- Test: `tests/lanes/test_install.sh`

- [ ] **Step 1: Write the failing test `tests/lanes/test_install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"
fake="$(mktemp -d)"; mkdir -p "$fake/.claude/relay" "$fake/.claude/commands"
printf 'old\n' > "$fake/.claude/commands/implement.md"
printf 'keep\n' > "$fake/.claude/relay/relay.sh"
HOME="$fake" bash "$here/../../relay/install-lanes.sh" >/dev/null
t_file "lanes installed"   "$fake/.claude/relay/lanes.sh"
t_file "lib installed"     "$fake/.claude/relay/lanes/lib.sh"
t_file "charter installed" "$fake/.claude/relay/charters/lane-mode.md"
t_file "command installed" "$fake/.claude/commands/lane.md"
t_eq   "relay.sh untouched" "$(cat "$fake/.claude/relay/relay.sh")" "keep"
t_true "implement backed up" 'ls "$fake/.claude/commands/" | grep -q "implement.md.bak-.*-pre-lanes"'
t_done
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/lanes/test_install.sh`
Expected: `install-lanes.sh: No such file or directory`.

- [ ] **Step 3: Write `relay/install-lanes.sh`**

```bash
#!/usr/bin/env bash
# Installs lanes into ~/.claude/relay and its commands into ~/.claude/commands. Every file
# it would overwrite is first copied to <file>.bak-<stamp>-pre-lanes, same convention as
# the earlier relay installs. relay.sh, relay.ps1 and the legacy charters are not touched
# except charters this repo also ships (they are backed up first).
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst="$HOME/.claude"; stamp="$(date +%Y%m%d-%H%M%S)"
put() { # <from> <to>
  mkdir -p "$(dirname "$2")"
  if [ -f "$2" ] && ! cmp -s "$1" "$2"; then cp -p "$2" "$2.bak-$stamp-pre-lanes"; fi
  cp -p "$1" "$2"
}
put "$src/relay/lanes.sh" "$dst/relay/lanes.sh"; chmod +x "$dst/relay/lanes.sh"
for f in "$src"/relay/lanes/*.sh; do put "$f" "$dst/relay/lanes/$(basename "$f")"; done
for f in "$src"/relay/charters/*.md; do put "$f" "$dst/relay/charters/$(basename "$f")"; done
for f in relay_jev.py relay_cite.py; do [ -f "$src/relay/$f" ] && put "$src/relay/$f" "$dst/relay/$f"; done
for f in lane implement relay-auto execute-plan; do put "$src/commands/$f.md" "$dst/commands/$f.md"; done
echo "lanes installed to $dst/relay (backups: *.bak-$stamp-pre-lanes)"
```

- [ ] **Step 4: Run the test and the suite**

Run: `bash tests/lanes/test_install.sh && bash tests/lanes/run_all.sh`
Expected: `0 failed` everywhere.

- [ ] **Step 5: Commit**

```bash
chmod +x relay/install-lanes.sh
git add relay/install-lanes.sh tests/lanes/test_install.sh
git commit -m "feat(lanes): installer with pre-lanes backups"
```

---

### Task 14: README and legacy test check

**Files:**
- Modify: `README.md` (insert a section after the intro, before `## The five roles`)

- [ ] **Step 1: Insert this section into `README.md` directly above `## The five roles`**

```markdown
## Lanes: the relay as a gentle-ai backend (WSL)

Since 2026-11 the relay's default mode is **lanes**: your Claude Code session runs
[gentle-ai](https://github.com/Gentleman-Programming/gentle-ai)'s ODD workflow and works
inline by default, and `relay/lanes.sh` starts an agent only for a named reason —
`explore` (read-only map), `write` (an agy writer per independent unit with its own
`In:` scope), `verify` (the scout pre-brief written from the specs alone, scout
evidence, and a Sonnet verdict — for high-risk changes only), or `autopilot`, which
drains an ODD feature document's `## Tasks` unattended. Each lane is one headless turn
in tmux session `lanes`; agy falls back to opencode on quota exhaustion as before.

The four-pane cycle below still works (`relay.sh`) and is the fallback; `relay.ps1`
stays on it until lanes is ported. Design and plan:
`docs/superpowers/specs/2026-11-21-gentle-ai-lanes-design.md`,
`docs/superpowers/plans/2026-11-21-gentle-ai-lanes.md`. Tests: `bash tests/lanes/run_all.sh`.
Install: `bash relay/install-lanes.sh`.
```

- [ ] **Step 2: Confirm legacy relay code and tests are untouched**

Run: `git diff --stat origin/master -- relay/relay.sh relay/relay.ps1 tests/ps1_trust_prompt_test.ps1 tests/rea_up_harness.sh tests/trust_prompt_menu.ps1`
Expected: no output.

Run: `bash tests/rea_up_harness.sh; echo "rc=$?"`
Expected: `rc=0` (as on master).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README section for lanes"
```

---

### Task 15: Install gentle-ai + Engram and retire overlapping superpowers skills (user-approved, machine-level)

This task writes outside the repo (`~/.claude`, `~/.gemini/config`, `~/.config/opencode`).
Run each step only after the user approves it.

- [ ] **Step 1: Back up the configs gentle-ai will touch**

```bash
stamp="$(date +%Y%m%d-%H%M%S)"; b="$HOME/backups/pre-gentle-ai-$stamp"; mkdir -p "$b"
tar -C "$HOME" -czf "$b/claude.tgz" --exclude='.claude/projects' --exclude='.claude/superpowers' .claude
[ -d "$HOME/.gemini/config" ] && tar -C "$HOME" -czf "$b/gemini-config.tgz" .gemini/config
[ -d "$HOME/.config/opencode" ] && tar -C "$HOME" -czf "$b/opencode.tgz" .config/opencode
ls -la "$b"
```

Expected: two or three non-empty `.tgz` files.

- [ ] **Step 2: Download the installer, read it, then run it**

```bash
mkdir -p ~/Downloads/gentle-ai-install && cd ~/Downloads/gentle-ai-install
curl -fsSLo install.sh https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh
less install.sh        # review before running
bash install.sh
exec bash -l; gentle-ai --version
```

- [ ] **Step 3: Dry-run, review, apply, verify**

```bash
gentle-ai install --agents claude-code,antigravity,opencode --preset ecosystem-only --persona neutral --dry-run
# review the plan with the user, then:
gentle-ai install --agents claude-code,antigravity,opencode --preset ecosystem-only --persona neutral
gentle-ai doctor
```

Expected: doctor passes or warns only, and Engram MCP is reachable. `--persona neutral` is
used because a persona change was not requested; the user can choose `gentleman` later.

- [ ] **Step 4: Retire the five superpowers skills (reversible move, not delete)**

```bash
mkdir -p ~/.claude/skills-retired
for s in using-superpowers brainstorming writing-plans executing-plans subagent-driven-development; do
  [ -d ~/.claude/skills/$s ] && mv ~/.claude/skills/$s ~/.claude/skills-retired/
done
rm -f ~/.claude/commands/brainstorm.md ~/.claude/commands/write-plan.md
ls ~/.claude/skills ~/.claude/skills-retired
```

- [ ] **Step 5: Keep `/sync-superpowers` from bringing them back**

In `commands/sync-superpowers.md`, replace the copy block

````markdown
```bash
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/commands"
cp -r "$HOME/.claude/superpowers/skills/." "$HOME/.claude/skills/"
cp "$HOME/.claude/superpowers/commands/"*.md "$HOME/.claude/commands/"
```
````

with

````markdown
```bash
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/commands"
cp -r "$HOME/.claude/superpowers/skills/." "$HOME/.claude/skills/"
cp "$HOME/.claude/superpowers/commands/"*.md "$HOME/.claude/commands/"
# Retired in favour of gentle-ai's ODD workflow (2026-11-21): these five impose a planning
# pipeline that ODD replaces. Moved to ~/.claude/skills-retired, not deleted.
for s in using-superpowers brainstorming writing-plans executing-plans subagent-driven-development; do
  rm -rf "$HOME/.claude/skills/$s"
done
rm -f "$HOME/.claude/commands/brainstorm.md" "$HOME/.claude/commands/write-plan.md"
```
````

Then install it and commit:

```bash
cp commands/sync-superpowers.md ~/.claude/commands/sync-superpowers.md
git add commands/sync-superpowers.md
git commit -m "chore: keep retired superpowers skills out on sync"
```

- [ ] **Step 6: Install lanes**

```bash
bash relay/install-lanes.sh
~/.claude/relay/lanes.sh doctor
```

Expected: `gentle-ai` and `engram` are no longer MISSING.

---

### Task 16: One real run, timed against `relay.sh`

- [ ] **Step 1: Pick a small real task in a scratch repo** (for example "add a
  `--json` flag to a 50-line CLI script") and have a fresh Claude Code session (with
  gentle-ai loaded) create `odd/tasks/<feature>.md` with two rows: one low risk
  (`route: write`), one `risk: high(contracts)` (`route: inline`), and a `Runner:` header.
- [ ] **Step 2: Run `lanes.sh autopilot --doc odd/tasks/<feature>.md`** and record the
  wall time, Claude and agy turns (count `*.json` per provider in `.relay/runs`), and the
  outcome.
- [ ] **Step 3: Run the same two tasks through `relay.sh autopilot`** in a fresh clone
  (as old-format task files) and record the same numbers.
- [ ] **Step 4: Write `docs/lanes-first-run.md`** with both columns. n=1, so present it
  as a sanity check rather than a benchmark. Note any lane that stalled, fell back, or
  needed a decision.
- [ ] **Step 5: Commit**

```bash
git add docs/lanes-first-run.md
git commit -m "docs: first real lanes run vs relay.sh"
```

---

## Self-review notes

- **Spec coverage:** §1 architecture → Tasks 6–10. §2 kept pieces: fallback, models, scope
  guard → Tasks 4–6; Jev/cite/REA → Tasks 5, 8, 9; STOP/health(doctor)/status/down →
  Tasks 10, 11. Cut items are simply not ported. New charters → Task 7; commands → Task 12;
  gentle-ai install + D6 → Task 15. §3 run-dir layout → Tasks 8–9; single writer and
  deterministic updates → Task 10. §4 error table → Tasks 6 (quota, stall, limit), 8
  (writer commits, out of scope), 9 (no evidence), 10 (FAIL twice, Claude limit, doc
  reconcile note), 11 (gentle-ai missing). §5 testing → Tasks 1–11, 14 (ps1 and legacy
  untouched), 16 (real run).
- **Known limit (documented, not hidden):** in a parallel batch, out-of-scope edits are
  checked against the union of the batch's `In:` scopes, so a writer that edits a sibling
  row's scope is not caught by the scope check. The Runner and the follow-up rows remain
  the backstop. Batches contain only low-risk rows.
- **Engram:** autopilot cannot call MCP; it logs that the mirror was not updated, and
  `/implement` step 5 reconciles it, per the spec's drift rule.
