# Relay → gentle-ai lanes: design

Date: 2026-11-21 · Status: approved in brainstorming, pending spec review
Reference: https://github.com/Gentleman-Programming/gentle-ai (read at 6f7c44d)

## Goal

Make the relay follow gentle-ai's orchestration philosophy so multi-agent work is faster
on small tasks and at least as accurate on risky ones. Gentle-ai's ODD workflow and Engram
memory run in the Claude Code session; the relay is reduced to a **delegation backend**
that starts psmux lanes only when gentle-ai's routing names a reason.

## Decisions (from brainstorming)

| # | Decision |
|---|---|
| D1 | Adopt gentle-ai + Engram, adapt the relay into a lane backend (not reimplement, not retire) |
| D2 | WSL first. `relay.ps1` is frozen at current behavior; port after the design holds |
| D3 | The Claude Code orchestrator is the ODD parent and writes small work inline |
| D4 | Autopilot survives; its queue is the ODD feature doc's `## Tasks` rows |
| D5 | Build a new `relay/lanes.sh`; `relay.sh` stays installed and untouched as fallback |
| D6 | Retire superpowers `using-superpowers`, `brainstorming`, `writing-plans`, `executing-plans`, `subagent-driven-development` at gentle-ai install time; keep `systematic-debugging`, `verification-before-completion`, `test-driven-development` |
| D7 | Unattended `inline` rows run in headless `claude -p`, not on agy |

## 1. Architecture

```
You ──► Claude Code (Opus) = gentle-ai ODD parent + Engram
          │  small/understood → inline, test-first, commit
          │  large → odd/tasks/<feature>.md  (verbatim S# specs, ## Tasks, ## Log)
          │
          └─ named reason → lanes.sh <lane> --doc odd/tasks/<feature>.md --task <ID>
               explore : 1 agy pane, read-only, returns path:line map
               write   : 1 agy pane per disjoint unit (parallel when scopes are disjoint)
               verify  : high-risk only → scout pre-brief (from S# alone, before code)
                         → scout evidence → Sonnet validator verdict
               mutate  : optional add-on to verify; never on the critical path
          gentle-ai RDD review (native, risk-tiered) runs separately, after
```

Lane reasons are gentle-ai's four delegation triggers: exploration beyond the inline
budget, parallel writers on disjoint surfaces, the long-session context backstop, and an
independent verifier for a high-risk change (data, security, shared contracts,
concurrency, delivery, or no regression test). None holds by default; file count never
decides.

## 2. Components

**Lifted into `lanes.sh` from `relay.sh`:** psmux pane lifecycle, folder-trust handling,
`RELAY_REPAINT_SETTLE` (2.5s), `probe_budget`, `pane_fault`, agy→opencode `big-pickle`
fallback (and its `RELAY_OPENCODE_MODEL*` knobs), `RELAY_AGY_MODEL*` knobs, scope-disjointness
guard (from `--pipeline`), `.relay/STOP`, `health`, `status`, `down`, `RELAY_JEV=1` gates
(`relay_jev.py`), `relay_cite.py`, `RELAY_REA=1`.

**Cut from the new path:** four fixed panes on `up`; the per-task execute→scout→validate
cycle as default; the relay task-file format; `--pipeline` prefetch; idle keepalive and
preemptive recycler (lanes are short-lived, torn down on completion); executor charter as
default writer; mutator as an always-on lane.

**New:**
- `relay/lanes.sh` — subcommands `explore | write | verify | mutate | autopilot | doctor |
  health | status | down`.
- Charters `relay/charters/lane-{explore,write,verify-scout,verify-validator}.md`; the
  existing `mutator.md` and `rea.md` are reused. Charters point at the feature doc's `S#`
  by reference and never restate the spec.
- Commands: `/lane` (replaces `/relay-up` + `/relay-task`); `/implement` and
  `/relay-auto` become "drain `odd/tasks/<feature>.md`". Old commands stay for `relay.sh`.
- gentle-ai + Engram installed in WSL for agents `claude-code`, `antigravity`, `opencode`,
  after backing up `~/.claude`, `~/.gemini/config`, `~/.config/opencode`.

**Tasks row format** (in the ODD feature doc, which ODD owns; the relay only adds fields):
`- [ ] T3 | S2,S4 | route: inline|explore|write|verify | risk: low|high(<item>) | In: <paths> | commit: <sha>`

## 3. Data flow

Lane run directory, one per invocation:
```
.relay/runs/<feature>/<task>-<lane>-<ts>/
  dispatch.md   charter + pointer to odd/tasks/<feature>.md#S<n>
  prebrief.md   scout probes from S# alone, rows tagged Written: pre      (verify)
  evidence.md   scout observations, Written: pre|post, never a verdict    (verify)
  verdict.md    PASS | PASS-WITH-CONCERNS | FAIL (+ follow-up row on FAIL) (verify)
  map.md        path:line map                                              (explore)
  result.md     what changed; edits stay in the work tree, within In:     (write)
  mutation.md   optional                                                   (mutate)
  lane.json     pane, provider (agy|opencode), timings, exit state
```

**Single writer:** only Claude edits `odd/tasks/*.md` (check off rows with observed proof
+ commit sha, append evidence links to `## Log`, insert validator follow-up rows). Lanes
never write the doc.

**Interactive:** Claude runs a lane, ends its turn while it runs (gentle-ai work
continuity), resumes on completion.

**Autopilot:** walks unchecked rows in order. `inline` rows → headless `claude -p` with the
doc pointer and ODD rules. Lane rows → `lanes.sh`. Rows with disjoint `In:` and no
dependency run write lanes in parallel. After each row a short headless Claude step
performs the single-writer doc update. Stops on `.relay/STOP`, on the same row failing
twice in a row, or on a genuine human decision (logged as "Needs your decision" in
`## Log`); independent rows keep running.

**Engram:** durable decisions/discoveries. The relay persists only run mechanics in
`lane.json`.

## 4. Error handling

| Failure | Handling |
|---|---|
| agy quota exhausted | `pane_fault` match on `quota reached` → restart pane on opencode. Checked at every lane start and stall check (not only under autopilot, unlike `relay.sh`) |
| Lane stall/hang | `probe_budget` ceilings; one retry on a fresh pane; then `lane.json` exit `stalled`, treated as a failed check, never a pass |
| Claude limit / `claude -p` failure (autopilot) | Stop that row, log "Needs your decision: Claude limit", continue independent lane rows; never auto-downgrade to agy |
| Write lane edits outside `In:` | Post-lane `git diff --name-only` vs `In:`; out-of-scope paths reverted; unparseable scope → row failed |
| Validator FAIL | Insert follow-up row; same row failing twice in a row → stop that row |
| Feature doc vs Engram drift | Claude reconciles before resuming; missing memory reported, not treated as success |
| Jev / REA unavailable | Existing conservative fallbacks, unchanged |
| gentle-ai / engram missing | `lanes.sh doctor` reports it; lanes still run (no hard dependency on the binary) |

## 5. Testing

- **Stub-agent harness** (`tests/lanes_harness.sh`, modeled on `tests/rea_up_harness.sh`):
  fake `agy` / `opencode` binaries with scripted outputs in a throwaway psmux session.
  Cases: verify chain order; pre-brief written before any code exists and without diff
  access; out-of-scope write reverted; quota banner → opencode switch; stall → one retry →
  `stalled`.
- **Autopilot fixture** (`tests/fixtures/odd/tasks/demo.md`): inline, write, parallel-write
  and verify rows run against stubs (`claude -p` stubbed too); asserts the doc is only
  written by the single-writer step and that parallel writes happen only for disjoint
  `In:`.
- **One real run** on a small repo with live agy + Claude, timed against `relay.sh` on the
  same task, to confirm the inline-first speedup.
- `relay.ps1` frozen: existing `tests/ps1_trust_prompt_test.ps1` must keep passing.

## Out of scope

- `relay.ps1` port (after the design holds).
- Changing gentle-ai itself or its RDD review internals.
- Removing `relay.sh` (it stays until `lanes.sh` has run for real for a while).
