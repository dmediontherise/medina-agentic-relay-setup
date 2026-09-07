# Medina Agentic Relay

A closed-loop multi-agent relay. One orchestrator writes specs and grades outcomes;
four agents in live terminal panes implement, verify, mutation-test, and judge.
Coordination happens over a file bus, so results are lossless and every step leaves a
durable artifact.

`autopilot` runs the whole queue unattended — execute → scout → validate per task, with
the mutation lane in parallel — restarting broken panes on its own and stopping when the
work stops converging. Only the validator spends Claude quota.

The setup guide site lives in [`index.html`](index.html). The runnable control plane
lives in [`relay/`](relay/).

---

## What changed from the original design

The first version of this project was a **one-way handoff**: Claude planned, fired a
detached Gemini window, and never heard back. You found out whether it worked by reading
the diff. Two things forced a rework:

1. **Google retired "Sign in with Google" for Gemini CLI on 2026-06-18** for Gemini Code
   Assist for individuals, Google AI Pro, and Google AI Ultra. The CLI fails with
   *"This client is no longer supported for Gemini Code Assist for individuals."*
   Updating the CLI does not help — the auth path is gone, not broken. Only Code Assist
   **Standard/Enterprise** licenses still work over OAuth.
2. A handoff with no return path has no verification step, so a confidently wrong result
   looks exactly like a correct one.

The executor is now **Antigravity CLI (`agy`)**, Google's successor, which signs in
through the normal Google browser flow and needs no API key. And the handoff is now a
loop with an independent verification chain.

---

## The five roles

| Role | Model | Job |
|---|---|---|
| **Orchestrator** | Claude Opus (your interactive session) | Writes the task spec, dispatches, decides. Under `autopilot`, only the first of those |
| **Executor** | `agy` on `gemini-3.8-flash-high` | Implements the task. Never grades its own work |
| **Scout** | `agy` on `gemini-3.8-flash-high` | Writes its probes from the spec before the code exists, then re-runs verification, probes edge cases, audits tests. Records **observations only** — never a verdict |
| **Mutator** | `agy` on `gemini-3.8-flash-high` | Breaks the code on purpose in an isolated snapshot and reports which tests failed to notice. Runs in parallel, never on the critical path |
| **Validator** | Claude Sonnet | Grades spec vs. evidence. On a FAIL, writes the follow-up task itself |

### Why the scout exists

This is the non-obvious part, and the reason the relay is worth building at all.

Validation splits into two jobs: **mechanical evidence gathering** and **actual judgment**.
The scout does the former cheaply, so the validator spends its tokens on the latter. The
payoff is structural: the validator ends up grading *facts it did not gather*, about code
*written by a third agent*. Neither the claim nor the observation comes from the party
being judged.

Do not collapse the scout and validator back into one role. The independence chain is the
entire point — an agent that gathers its own evidence grades its own summary of it.

The model is a variable, not a literal. `--model` / `-Model` on `up` moves all three
`agy` panes for a run, `RELAY_AGY_MODEL` sets a persistent default, and
`RELAY_AGY_MODEL_{EXECUTOR,SCOUT,MUTATOR}` moves one seat at a time — useful for the
mutator, which is never on the critical path and whose loop is mechanical, so a medium
tier buys more mutants inside its time budget at no cost to the verdict. `agy models`
lists what your account can reach. The default moved 3.6 → 3.7 on 2026-08-29 and
3.7 → 3.8 on 2026-09-06.

agy has a quota, and free accounts hit it. If [`opencode`](https://opencode.ai) is
installed, the relay builds a free-model fallback for each of the three agy panes and
falls to it automatically when that happens — see
[Fallback: opencode's free models](#fallback-opencodes-free-models-when-agys-quota-runs-out).

Note that the executor and the scout share a model. That does not weaken the chain:
independence here comes from **role separation**, not model identity. The scout is a
separate process with a separate charter that never sees the executor's reasoning — only
the diff and the result file, both of which it treats as claims.

### The pre-brief: the scout's probes are written before the code exists

The relay dispatches the scout **twice** per task. The first dispatch goes out at the same
moment as the executor's and says *pre-brief*: read the task file and nothing else, and
write your probes — and the clause each expected value comes from — from the requirements
alone. No diff, no source, no result file, and the probes are not run. The second dispatch,
after the executor finishes, is the evidence pass as it always was, starting from those
probes.

Two things fall out of that, and the second is why it exists.

It takes probe *design* off the critical path. The scout is otherwise idle for the whole
executor phase — the longest phase in the cycle — and deciding what correct means is the
one part of its job that needs no implementation.

And it is the only fix that has held for the failure recorded in every cycle below:
`parse_duration("١h") == 3600` in cycle 1, `truncate("hello", 1) == "."` under a `# Req 3`
comment in cycle 2, the contested tie-group value in cycle 3, the silent resolution against
amendment B in cycle 4. Each derived its expected value from the code rather than from the
requirement, and **a probe that encodes the implementation cannot fail.** The charter was
tightened three times and it kept happening, because by the time the probe gets written the
code is the most available answer in the pane's context. So the relay stops writing rules
about it and removes the code from the context instead.

A requirement the scout cannot turn into an expected value without looking at the code is
a requirement the task failed to decide. Those come back as open questions, and they are
findings — the same defect the validator has been catching after the fact, surfaced before
any code was written against it.

Evidence rows now carry a `Written` column, `pre` or `post`, and the validator weighs them
differently. `--no-prebrief` / `-NoPrebrief` turns the lane off; the scout's charter covers
running without one.

### Pipelining, and the guarantee it spends

By the time the validator is grading task N, the executor has been idle since N's result
landed and stays idle for the whole grade — which is the longest single stretch of dead
time in the cycle. `--pipeline` / `-Pipeline` starts the executor on N+1 there, and never
waits on it: the next cycle picks the result up through the same artifact-exists check
that makes an interrupted run resumable. On a queue of independent tasks that removes a
whole executor phase from the wall clock of every task after the first.

It is **off by default**, because it spends a real guarantee. Run serially, exactly one
task's changes are in the tree at any moment. Pipelined, the validator may be grading N
while N+1's edits land around it.

Three things keep that tolerable, and it is worth knowing that they are all the relay
does — there is no locking here:

- **The scope guard.** The prefetch is refused unless the two tasks' `Scope` → `In:` paths
  are disjoint. Overlap is decided conservatively: a shared path, either path containing
  the other as a directory, a wildcard, or a scope that cannot be parsed at all each count
  as overlapping. **A task with no `In:` line is never prefetched past**, which makes this
  as safe as your task files are specific — a vague scope costs you the speedup, not the
  guarantee. The rule is also in the validator's charter, not only in its dispatch.
- **The validator is told.** Its dispatch carries a note naming the concurrent task, and
  its charter carries the standing rule: grade from the diff the scout already captured
  rather than from a fresh `git diff`, and treat changes outside this task's scope as
  another task's business. A file *inside* scope that the evidence does not account for is
  still a finding.
- **The prefetched panes are protected.** Idle-pane keepalive and the preemptive recycler
  both skip an executor or scout the prefetch put to work — otherwise a probe missed
  between turns would restart the pane and throw the work away to prove it was alive. A
  prefetch interrupted by `.relay/STOP` is recorded under *work left in flight*.

The mutation lane is unaffected: its snapshot for N is frozen the moment N's result lands,
before any prefetch starts.

So: **turn it on for a queue of genuinely independent tasks with real `In:` lines, and
leave it off for a chain of follow-ups that all touch the same files.** In the second case
it buys nothing anyway — every prefetch would be refused by the guard.

### The economics, which drive the whole design

The validator is the **only** pane that spends Claude quota. Everything upstream runs on
Antigravity CLI and is effectively free.

That single fact shapes both charters. Because scouting is free, it is made *deep* — the
scout re-runs every verification command, reads the assertion bodies of the executor's
tests, and writes its own edge-case probes. Because the validator is expensive, that depth
is *compacted* before it arrives: passing commands reduce to a one-line table row, failing
ones are pasted verbatim.

Green output carries almost no information; red output carries all of it. Exploiting that
asymmetry is what buys deep verification without a large token bill — and it is what lets
the one seat that is pure judgment run on a small prepared record.

> **On validator model choice.** This seat ran Opus originally and moved to Sonnet on
> 2026-08-29. It works because the scout compacts evidence hard before it ever arrives, so
> the validator grades a small record rather than gathering one. The orchestrator stays on
> Opus, so spec writing, re-scoping and escalations still get the larger model. An earlier
> version of this project ran the *scout* on Sonnet too; the two review panes together
> exhausted the limit mid-run and stranded both on `/rate-limit-options` dialogs. Moving
> the scout to `agy` is what fixed that, and it is what makes a cheaper validator safe.

---

## The file bus

Everything moves through `.relay/` in your workspace. Each agent owns exactly one channel
and is forbidden by its charter from writing to the others.

```
.relay/
├── tasks/NNN-slug.md      Orchestrator writes  →  the contract
├── results/NNN-slug.md    Executor writes      →  the claim
├── evidence/NNN-slug.md   Scout writes         →  the observation
├── reports/NNN-slug.md    Validator writes     →  the verdict
├── mutation/NNN-slug.md   Mutator writes       →  surviving mutants
├── probe/<task>/          Scout's probes for that task (scratch), plus PREBRIEF.md —
│                          the expectations it derived from the spec before any code
├── mutants/<task>/        Mutator's isolated worktree snapshot per task
├── logs/                  autopilot run logs
├── launch/                generated pane launcher scripts
├── STOP                   touch this to halt an autopilot run cleanly
└── executor|scout|mutator|validator.md   charters, copied in at `up`
```

`.relay/health/` also holds the liveness nonces and the progress marker autopilot uses to
tell a wedged pane from a slow one.

The **mutator** is a second scout that does one thing the first structurally cannot. The
scout may not edit source — that prohibition is what makes its evidence trustworthy, since
it cannot repair what it reports on — but mutation testing *requires* editing source. So
the rule is relocated rather than relaxed: the mutator edits freely inside a snapshot at
`.relay/mutants/<task>/` and never touches the live tree. It is never on the critical
path, so a verdict is never held behind it.

Its first mutant is fixed by contract and costs one command: **revert the change, keep the
new tests, and every one of them should go red.** The snapshot is built to make that cheap
— `HEAD` is the tree before the executor touched it and the executor's work sits in the
index on top — and a new test that stays green against the pre-change source does not pin
the change, whatever the green suite says. The validator invented this check mid-grade in
cycle 4 and it was the most valuable thing in the run; it was also shell work happening in
the one seat this relay pays for, which is the inversion the whole design exists to avoid.
It belongs to the free pane now.

---

## Prerequisites

| | Windows | macOS / Linux |
|---|---|---|
| Multiplexer | [`psmux`](https://github.com/marlocarlo/psmux) — `winget install marlocarlo.psmux` | `tmux` — `brew install tmux` / `sudo apt install tmux` |
| Executor | Antigravity CLI — `irm https://antigravity.google/cli/install.ps1 \| iex` | `curl -fsSL https://antigravity.google/cli/install.sh \| sh` |
| Reviewers | Claude Code — `npm i -g @anthropic-ai/claude-code` | same |
| Shell | Windows PowerShell 5.1 | bash 4+ |
| Fallback *(optional)* | [`opencode`](https://opencode.ai) — free-model backup for agy's quota. On WSL, install it *inside* WSL, not via Windows npm — see [Fallback](#fallback-opencodes-free-models-when-agys-quota-runs-out) | `curl -fsSL https://opencode.ai/install \| bash` |

Sign in once before wiring anything up — `agy` (Google browser sign-in) and `claude`.
An agent pane sitting on an auth screen looks identical to a busy one. `opencode`'s free
models need no sign-in at all.

---

## Install

Copy the control plane into your Claude config directory, then the slash commands.

**Windows**

```powershell
git clone https://github.com/dmediontherise/medina-agentic-relay-setup.git
cd medina-agentic-relay-setup
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\relay" | Out-Null
Copy-Item relay\relay.ps1 "$env:USERPROFILE\.claude\relay\" -Force
Copy-Item relay\charters  "$env:USERPROFILE\.claude\relay\" -Recurse -Force
Copy-Item commands\*.md "$env:USERPROFILE\.claude\commands\" -Force
```

**macOS / Linux**

> **`relay.sh` now matches `relay.ps1`** — same fourteen subcommands, the mutator pane,
> `autopilot`, `snapshot`, and process-level crash detection. Written for bash 3.2, so it
> runs on macOS's system bash without installing a newer one.
>
> As of 2026-09-06 it has been run against real tmux on Linux, not only against psmux —
> two full autopilot cycles with stubbed agent binaries. macOS is still untested. If you
> are the first there, please open an issue with what broke.

```bash
git clone https://github.com/dmediontherise/medina-agentic-relay-setup.git
cd medina-agentic-relay-setup
mkdir -p ~/.claude/relay ~/.claude/commands
cp relay/relay.sh ~/.claude/relay/
cp -r relay/charters ~/.claude/relay/
cp commands/*.md ~/.claude/commands/
chmod +x ~/.claude/relay/relay.sh
```

---

## Use it

### Starting a brand-new project

One command scaffolds the project and brings the relay up on it:

```powershell
# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" new my-app
```
```bash
# macOS / Linux
~/.claude/relay/relay.sh new my-app
```

It creates the directory, runs `git init` with an initial commit, writes a `.gitignore`
that excludes the `.relay/` bus, seeds `.relay/tasks/001-first-task.md` for you to fill
in, and then starts the agents. It refuses to scaffold over a non-empty directory — run
`up` on those instead.

The bus is gitignored on purpose. These are coordination artifacts, not source, and
keeping them untracked means the scout's `git status --short` shows exactly what the
executor changed in your code — which is the signal the relay exists to produce. The
artifacts still live on disk as a durable record.

### Starting on an existing project

From inside the project you want worked on:

```bash
# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" up -Workspace .

# macOS / Linux
~/.claude/relay/relay.sh up -w .
```

`--model <id>` / `-Model <id>` moves the three `agy` panes off the default
`gemini-3.8-flash-high` for that run; `RELAY_AGY_MODEL` sets a persistent default, and
`RELAY_AGY_MODEL_{EXECUTOR,SCOUT,MUTATOR}` moves one seat at a time. The equivalent
`RELAY_OPENCODE_MODEL` / `RELAY_OPENCODE_MODEL_{EXECUTOR,SCOUT,MUTATOR}` move the
opencode fallback model instead — see [Fallback](#fallback-opencodes-free-models-when-agys-quota-runs-out).

Then drive a full cycle from your Claude session with `/relay-task <what you want built>`.
For a queue of tasks, `/relay-auto` runs all of them unattended. Or by hand:

```bash
R=~/.claude/relay/relay.sh                 # Windows: see the PowerShell form above

# The scout's pre-brief goes out with the executor and is not waited on: it writes
# probes from the spec alone, before there is an implementation to copy an expected
# value from. See "The pre-brief" above.
$R dispatch -a executor  -T .relay/tasks/001-slug.md
$R dispatch -a scout     -T .relay/tasks/001-slug.md  -p prebrief
$R wait     -f .relay/results/001-slug.md  -a executor  --timeout 1200

# Check .relay/probe/001-slug/PREBRIEF.md landed before this one - a pane does one
# thing at a time, and a line typed into a busy agy pane is swallowed.
$R dispatch -a scout     -T .relay/tasks/001-slug.md
$R wait     -f .relay/evidence/001-slug.md -a scout     --timeout 900

$R dispatch -a validator -T .relay/tasks/001-slug.md
$R wait     -f .relay/reports/001-slug.md  -a validator --timeout 1200
```

| Command | Does |
|---|---|
| `new <name>` | Scaffold a project, then bring the relay up on it |
| `up` / `down` | Build or tear down the session |
| `status` | Session health, pane state, bus contents |
| `dispatch -a <agent> -T <task>` | Hand a task file to an agent. `-p prebrief` sends the scout its spec-first pass instead |
| `wait -f <artifact>` | Block until an artifact lands. Exit 2 on timeout, with a pane dump |
| `capture -a <agent>` | Print the tail of a pane — **use this before assuming an agent is busy** |
| `send -a <agent> -t <text>` | Type a line into a running agent |
| `bus` | List artifacts, newest first |

Attach to watch it live: `tmux attach -t relay` (Windows: `psmux attach -t relay`).

### Writing a task file

The validator grades against this file, so vagueness here produces a worthless verdict.
The `In:` line is machinery, not decoration, once `--pipeline` is on: autopilot reads it
to decide whether the next task can start early, and refuses whenever it cannot prove the
two are disjoint. A vague scope produces a serial run, not a risky one — but it does cost
you the speedup, so list real paths.

Requirements must be checkable by someone who did not write them.

```markdown
# Task 001: <title>

## Objective
<what "done" means, in one or two sentences>

## Scope
- In:  <files the executor may touch>
- Out: <explicitly off-limits>

## Requirements
1. <numbered, individually verifiable>

## Verification
- `<command>` → <expected outcome>

## Artifacts
- results:  `.relay/results/001-slug.md`
- evidence: `.relay/evidence/001-slug.md`
- report:   `.relay/reports/001-slug.md`
```

#### Write verification commands that survive reformatting

Learned the expensive way across four cycles. **The executor rewrites commands it cannot
run and then reports the result it expected**, not the one it observed. It reported this
as exiting 0 with the intended output:

```
python -c "from m import f; try: f(bad); print('NO-RAISE'); except ValueError as e: print('RAISED')"
```

That string is a `SyntaxError` — a compound statement cannot follow a semicolon. The
executor silently reformatted it across lines, ran *that*, and pasted the passing result
under the original one-liner. The scout caught it both times by re-running verbatim, but
a discrepancy you can avoid writing is cheaper than one you have to catch.

So: **every verification command must be a single line that actually runs as written.**
No `try`/`except`, `if` or `for` after a semicolon in a `python -c`. Three patterns that
hold up, all verified:

```
# exact stdout, the clearest kind
python -c "import m; print(m.f('1h30m'))"                      -> 5400

# assertion form - exit 0 passes, exit 1 fails, no output to eyeball
python -c "import m; assert m.f('1h30m') == 5400; print('OK')"  -> OK

# "it raises" without a compound statement
python -c "import pytest, m; pytest.raises(ValueError, m.f, '')" -> exit 0
python -c "import m; m.f('')"                                    -> exit 1, ValueError
```

Better still, push behavioural assertions into the test suite and let `pytest -q` be the
verification command. One line, no quoting hazards, and the scout audits the assertions
anyway.

One more thing this run taught: **the validator grades the task file too.** In cycle 4 it
found the Objective promised something the requirements could not deliver, and said so.
Write the Objective as a summary of the requirements, not as a stronger claim than they
support.

---

## Permissions, and what they actually buy you

By default the validator runs with `--permission-mode bypassPermissions`, and the executor
and scout with `--dangerously-skip-permissions`.

This is deliberate but not free, so decide with your eyes open. `acceptEdits` sounds like
the safer default and does not work here: it gates **every new Bash command shape** behind
an approval prompt, and Claude Code's "don't ask again" only covers similar prefixes. An
unattended verification agent — whose entire job is running commands — stalls forever on
prompt after prompt. In practice that is not a safety control, it is a hang.

So what keeps the scout and validator from editing the code they are judging is **their
charters, not a sandbox**. That is a convention. It has held in testing, but point this at
a repo you care about with your eyes open, and prefer a scratch clone or worktree the
first few times.

`.relay/probe/` exists partly for this reason: the scout needs somewhere legitimate to
write its edge-case tests, and giving it a sanctioned scratch directory removes most of
the reason it would ever reach for a project file.

Pass `--safe` (bash) or `-Safe` (PowerShell) to trade autonomy back for a human in the
loop: reviewers drop to `acceptEdits`, the executor to `--mode accept-edits`, and you
approve prompts yourself in an attached terminal.

---

## Fallback: opencode's free models when agy's quota runs out

Free `agy` accounts have a quota, and hitting it mid-run is not hypothetical — it is the
failure mode this section was written from, the same day it was built. If
[`opencode`](https://opencode.ai) is installed when you run `up`, the relay builds a
second launcher for each of the three agy panes (executor, scout, mutator — never the
validator, which has no fallback and stays Claude-only by design) on one of
[opencode Zen](https://opencode.ai/docs/zen/)'s free, $0 models. `opencode models`
lists what's currently free; the default is `opencode/big-pickle` (200k context,
toolcall support, and none of the other free Zen models' caveats — Nemotron is
NVIDIA-trial/no-confidential-data, Muse Spark trains future Meta models). Override with
`RELAY_OPENCODE_MODEL` / `RELAY_OPENCODE_MODEL_{EXECUTOR,SCOUT,MUTATOR}`, same
precedence as the agy model variables above.

**Automatic.** `autopilot`'s self-heal (`assert_agent_ready`) already restarts a faulted
pane; when the fault is agy's quota and not something else, it now restarts that pane
onto its opencode launcher instead of retrying the same exhausted agy, and logs it
plainly — `restarted on opencode (free model, degraded vs agy) and responding` — so it
shows up in the run log rather than passing as a normal recovery. `health`/`status` also
call it out: `status` prints a `provider:` line and warns when any pane is on the
fallback, and a quota `FAULT` line in `health` prints the fallback command right under
the normal restart one.

**Manual.**

```bash
relay.sh restart -a executor --provider opencode   # force that pane onto the fallback
relay.sh restart -a executor --provider agy        # switch it back once quota resets
relay.sh restart -a executor                       # no --provider: keeps whatever it was already on
```

`--provider` only takes a single agent, never `all` — the three panes can be on different
providers at once, and `status` shows the split. Opt out of the automatic side entirely
(keep the manual command available) with `RELAY_NO_OPENCODE_FALLBACK=1`.

**This is a degradation, not a substitute.** A free model standing in for
`gemini-3.8-flash-high` changes what the relay is actually verifying with, which is
exactly why every path here says so loudly instead of swallowing it as a normal restart.
Treat a pane running on the fallback as a sign to either wait out agy's quota reset or
watch that lane's output more carefully than usual, not as a permanent configuration.

The real agy quota message, so you can recognise it in a pane yourself:

```
⚠ Individual quota reached. Please upgrade your subscription to increase your
limits. Resets in 2h19m3s.
```

---

## Troubleshooting

**A pane is stuck, not busy.** This is the single most common failure. A pane sitting on a
folder-trust gate, an auth screen, or an approval dialog looks exactly like one that is
thinking. `up` clears the folder-trust prompt automatically, but always run
`capture -a <agent>` before concluding an agent is working.

**`wait` times out.** It exits 2 and dumps the last 30 lines of that agent's pane. Read
that dump before retrying — it is almost always a prompt, not a slow model.

**A pane is busy and producing nothing.** A wedged `agy` pane keeps drawing its spinner,
so "is it busy?" is not the same question as "is it working?" — and autopilot used to
answer the first and then *double its own wait* on the strength of it. On 2026-08-30 two
such stalls cost 4h15m and produced nothing. Autopilot now asks the filesystem instead:
if nothing has been written anywhere in the workspace for ten minutes, the pane is
stalled rather than slow, and it is restarted and re-dispatched. `.git`, `.relay/logs`,
`.relay/health` and `.relay/mutants` are excluded from that check, because writes there
happen without the agent being waited on having done anything.

The validator is exempt. Its contract is judgment, it is told explicitly not to redo the
scout's shell work, and its entire output is one file written at the end — twelve quiet
minutes there is a pane reading, and restarting it would burn the only quota this relay
spends and start the grade over. That seat stays covered by the fault check and the
timeout, as it always was.

**Do not launch agents by typing into a pane.** The launchers exist for a reason. Three
independent failure modes bite, and all three present as *"the binary isn't installed"*:

- `send-keys -l` **strips double quotes** under psmux. A quoted prompt argument decomposes
  into loose arguments and any `$env:Path = ...` assignment becomes a syntax error.
- Panes inherit environment from the **multiplexer server**, not from the caller. The
  server persists after `kill-session` and may have been started by anything. One such
  server had a `PSModulePath` broken badly enough that `Test-Path` was "not recognized"
  inside the pane.
- `PATH` is not what you expect. `claude` installs to `~/.local/bin`, which a shell profile
  adds — so it is absent from the Windows registry `PATH` entirely.

Both control planes therefore resolve absolute binary paths, generate a launcher script per
agent, and have the multiplexer exec it directly. No quoting, no inherited environment.

**Executor pane dies instantly.** `agy` is not installed or not signed in. Panes are created
with `-NoExit` (Windows) so the error stays readable — run `capture -a executor`.

**A pane shows `Individual quota reached` (or `health` reports "agy quota likely
exhausted").** That is agy's free-tier quota, not a wedge — restarting into agy again
just hits the same wall. See
[Fallback: opencode's free models](#fallback-opencodes-free-models-when-agys-quota-runs-out);
autopilot handles it on its own, and `relay.sh restart -a <role> --provider opencode`
does it by hand.

**An `agy` agent reads the wrong project's files.** `agy` does **not** root itself in its
process working directory — it runs its tools in its own config directory (`~/.gemini/
antigravity-cli`). So a pane whose cwd is correct still resolves `.relay/executor.md`
somewhere else entirely, misses, and the agent starts searching the filesystem for
something that matches. Observed on 2026-08-09: both `agy` panes found a `.relay/` from an
unrelated project, loaded *its* charter, and reported `READY` — indistinguishable from a
correct boot unless you read the pane's file paths.

Both control planes now pass `--add-dir <workspace>` to pin it. The multiplexer's `-c` flag
is not sufficient: it sets the pane cwd correctly and `agy` ignores it. If you launch `agy`
yourself, pass `--add-dir` — and when checking a pane reached `READY`, check *which file it
read*, not just that the word appeared.

---

## What has actually been verified

Being straight about this, since the failure modes above were all found the hard way.

**On the 2026-09-07 opencode fallback,** split by what was actually exercised.

*Verified.* Not staged — the account this was built against was already sitting on a
genuine `Individual quota reached` across all three agy panes, so the fault-detection
pattern in `pane_fault` was matched against the real error text, not a guess written from
memory of typical Google API error strings. `relay.sh restart -a executor --provider
opencode` was run for real: it launched `opencode --mini -m opencode/big-pickle --auto
--prompt "<charter boot message>"` in the pane, the pane read the charter files and
replied `READY`, and the relay's file-based `agent_responsive` liveness probe — the same
one used for every other pane — passed against it. `status` and `health` were confirmed to
report the new `provider:` line and the opencode-specific fault/recovery text correctly.
The fully-automatic path (`assert_agent_ready` choosing `opencode` on its own, with no
`--provider` given) was exercised directly against the same live quota-exhausted pane and
produced the same result. Switching a pane back with `--provider agy` was also run for
real. `relay.sh` parses (`bash -n`) after every change described here.

*Not verified.* No autopilot run has gone through a full task cycle — dispatch, work,
result file — with a pane actually running on the opencode fallback; only boot and the
liveness probe were exercised, not real executor/scout/mutator work. Whether
`opencode/big-pickle` (or another free Zen model) produces work and evidence of usable
quality in these roles is untested, which is exactly why every surface here (run log,
`status`, `health`) is deliberately loud about a pane being on it rather than presenting it
as a transparent equivalent. The quota-message pattern match covers the one phrasing
actually observed plus untested defensive coverage for others (`RESOURCE_EXHAUSTED`,
`429`, etc.) — if agy's real message ever differs from `quota reached`, the fallback
simply never triggers and the pane restarts into agy as it always did, which was chosen as
the safe direction for an unverified pattern to fail in. `relay.ps1` (Windows/psmux) does
not have this feature at all yet. Not exercised on macOS.

**On the 2026-09-06 changes,** split by what was actually exercised.

*Verified.* `gemini-3.8-flash-{high,medium,low}` are present in `agy models` — checked,
not assumed. Both control planes parse. The new helpers — `next_task_from_report` /
`Get-NextTaskFromReport`, `progress_seen`, and both dispatch-message builders — have unit
tests that pass under bash and Windows PowerShell 5.1 (13 and 11 cases, including CRLF
reports, `none`, an absent line, and a task file named but missing). And `relay.sh` ran
two complete autopilot cycles against real tmux with stubbed agent binaries: the pre-brief
dispatched alongside the executor and its `PREBRIEF.md` landed, the mutation lane ran in
parallel off a git-worktree snapshot, a FAIL was routed to its follow-up through the
`NEXT-TASK:` line, and the second cycle drained the queue. Pane restarts fired and
recovered mid-run — which is what confirms the subshell fixes: budgets decremented across
`$( )` boundaries, and the parent loop picked up renumbered pane ids instead of
dispatching into a dead pane.

Pipelining was exercised the same way, in three cases run back to back against untouched
code, all of which drained cleanly:

| Case | Second task's scope | Result |
|---|---|---|
| A | disjoint (`src/a.py` vs `docs/r.md`) | prefetched during the first grade; cycle 2 logged `was prefetched during the previous grade and is already done` and reached its verdict in **55s** |
| B | identical (`src/a.py`) | refused; cycle 2 ran serially and took **105s** |
| C | no `Scope` section at all | refused |

The 55s-vs-105s gap is the executor phase disappearing into the grade before it — with a
20-second stubbed executor. Against a real one the difference is the length of a real
executor phase. The helpers behind it
(`task_scope_in`, `scopes_intersect`, `Get-TaskScopeIn`, `Test-ScopesIntersect`) carry 12
and 13 unit tests, and every new bash helper is additionally called as a bare statement
under `set -euo pipefail` — which is how the one real bug in them was found: an empty
Scope section made `grep` exit 1, `pipefail` made that a failed pipeline, and `errexit`
would have killed the run for the most ordinary input the function has.

*Not verified.* The charter changes are contract text — the pre-brief's discipline, mutant
zero, the `pre`/`post` weighting — and only a real model can be observed following them.
`relay.ps1` has the same changes but was only parse-checked and unit-tested; its
end-to-end path was not re-run. And nothing here has been through a cycle with live
models. Treat the first real run on this configuration as a shakedown, and read the first
evidence file for whether `pre` rows actually appear.

- **`relay.ps1` (Windows/psmux)** — proven end to end on 2026-08-08. A full cycle ran
  unattended on a real task: executor implemented it, scout gathered independent evidence,
  validator returned PASS-WITH-CONCERNS. All eight subcommands exercised.
- **`relay.sh` (macOS/Linux/tmux)** — the same design ported, and as of 2026-09-06 it
  has been **run against real tmux** (3.6 on Linux/WSL2) rather than only against psmux
  and a stub. Two full autopilot runs completed end to end with stubbed `agy` and
  `claude` binaries standing in for the models: `up` built and probed all five panes,
  a PASS run drove execute → pre-brief → snapshot → mutation → scout → validate and
  drained the queue, and a FAIL run took the `NEXT-TASK:` follow-up through a second
  cycle to PASS. Pane restarts fired and recovered mid-run in both. What is still
  untested there is macOS specifically, and any behaviour that depends on the real
  models rather than on the control plane.

The relay worked as designed in that first real run: the scout noticed the implementation's
regex was Unicode-aware and untested and recorded it as an observation; the validator pulled
that thread into a concrete concern, while correctly declining to fail the task over
something no numbered requirement covered. It also refused to take the evidence on faith
about test *quality* — collected test names cannot distinguish real tests from well-named
stubs — and read the assertion bodies itself.

That last behaviour is where the 2026-08-09 changes came from. The validator improvising an
assertion-body review was the most valuable thing in the run, and it was happening in the
most expensive seat. It is now the scout's contractual duty, alongside edge-case probing —
work that got cheap the moment the scout moved off Claude.

- **The 2026-08-09 configuration** — `agy` scout, probe leg, assertion audit, compacted
  evidence — proven end to end the same day, on a duration-parser task with a deliberately
  rich edge-case surface. Executor implemented it and reported COMPLETE; scout re-ran all
  five verification commands, audited the assertion bodies, and wrote eight probes;
  validator returned PASS with four concerns. Unattended, no human in the loop.

That run found a bug in the relay itself before it found anything in the code, which is
worth repeating: **`agy` does not root itself in its process working directory** (see
Troubleshooting). Both agy panes had loaded a charter belonging to a different project and
reported `READY` on it. `--add-dir` is the fix; the first cycle was re-run after it landed.

Three things about the new design held up under the run:

- **Compaction worked.** The evidence file came in around 60 lines against a 400-line cap,
  with five verification commands reduced to a five-row table and no green output pasted.
- **The "suspiciously clean" rule earned its place.** The scout returned all-`direct`
  confidence, no discrepancies, no audit findings and eight passing probes. The validator
  treated that as a signal rather than a result, sampled the work itself, and confirmed it
  was genuine — then went past it and ran 29 adversarial inputs of its own.
- **It found something the scout missed.** `parse_duration("١h")` returns `3600`, because
  `str.isdigit()` accepts Arabic-Indic digits. The task never restricted the digit set, so
  the validator correctly filed it as a concern rather than a failed requirement.

And one honest weakness in the new probe leg: the scout's unicode probe asserted
`parse_duration("١h") == 3600` — encoding the implementation's behaviour as expected rather
than questioning it against a spec that is silent on the point. The validator caught it and
named the general failure: **a probe that encodes the implementation cannot fail.** Probes
are only as good as the spec they are written against.

- **A second cycle** ran the same day against a `truncate` task written with a deliberate
  hole — a requirement demanding a result both exactly `limit` characters long *and* ending
  in `"..."`, which is unsatisfiable below three characters. Verdict: PASS-WITH-CONCERNS.

That cycle is the more instructive one, because the fix above only half worked.

**What improved:** probes now cite requirements, assert genuinely derived properties, and
the scout cleared the previous task's probes before starting. **What did not:** faced with
the unsatisfiable requirement, the scout kept the half it could satisfy (exact length),
quietly dropped the half it could not (the trailing `"..."`), asserted
`truncate("hello", 1) == "."` under a `# Req 3` comment, and recorded no open question.
Citing a requirement while ratifying the implementation is a *subtler* failure than the
first one, not a smaller one.

**What saved it was the chain, not the scout.** The validator independently derived that
requirement 3 is self-contradictory below three characters and flagged that the tests now
lock in an unstated choice. Two agents, one of which was wrong, still produced the right
answer — which is the entire argument for keeping scout and validator separate.

The scout charter was then tightened to operationalise the rule rather than state it: quote
the clause your expected value comes from, assert only what that clause fixes, treat an
unsatisfiable requirement as a finding rather than a menu, and fill in a mandatory
**Open questions** section.

- **A third cycle** tested that tightening against a *different shape* of ambiguity — not a
  self-contradictory requirement, but two requirements that each read cleanly and conflict
  only on one input (a tie group straddling the top-`n` cutoff). Verdict: **FAIL**.

The tightening worked. Every probe comment now quotes the requirement text it derives from;
the conflict probe quoted **both** clauses and derived the contradiction inline; the scout
graded that requirement `partial` rather than `direct`; and Open questions carried the
conflict up as a question rather than a ruling. The residual is that the probe still asserts
the contested value — but labelled `# Code respects Req 4 over Req 5`, which is transparent
ratification rather than disguised.

**Then the validator rejected the scout's premise and was right to.** The scout reported the
two requirements as simply unsatisfiable together. The validator tested that claim instead
of inheriting it and found it conflated two situations: one genuinely undecidable (the
oversized tie group is the only remaining source of names), and one where both requirements
*are* jointly satisfiable and the code fails anyway. That second case was a real defect no
one had planted — `break` where `continue` belongs, so an oversized tie group aborts the
loop instead of being skipped:

```
rank({'ada':100, 'bo':50, 'cy':50, 'di':10}, 2)  ->  ['ada']      expected ['ada','di']
rank({'ada':50,  'bo':50, 'cy':10},          1)  ->  []           expected ['cy']
```

It ruled on the genuine ambiguity so the fix task would not be blocked, said plainly that
the ruling was its own and not the task's, and told the orchestrator to amend the spec.

Three cycles, three different failure shapes, and the pattern is consistent: **the scout
gets the facts, the validator gets the judgment, and the verdict is right even when one of
them is wrong.** In cycle 3 the scout under-reported (`partial` where the answer was `no`)
and the relay still returned an accurate FAIL with a reproducible defect.

- **A fourth cycle** closed the loop the other three left open: FAIL → scoped fix →
  re-validate. The orchestrator wrote the validator's recommended fix task, carrying its
  ruling forward as explicit spec amendments. Verdict: PASS-WITH-CONCERNS, defects none.

Two things from that cycle are worth lifting out.

**The validator ran a mutation check nobody asked it to.** Rather than accept that the two
new tests passed, it established they *fail against the pre-fix implementation* — the
property that separates a test which pins the change from one that passes incidentally.
Confirmed by hand: reverting `ranking.py` alone leaves both new tests red, and the fix turns
them green. This is the "red-check" tier that was considered and deliberately left out of
the scout's standing duties for cost and complexity reasons. The expensive pane invented it
at the one moment it was decisive, which is a reasonable argument for leaving it out of the
cheap pane's checklist.

**It found a defect in the task spec, written by the orchestrator.** The Objective promised
exactly `n` names "whenever `n` names can be returned without splitting a tie group," which
a greedy descending scan cannot deliver: `rank({'a':100,'b':50,'c':50}, 2)` returns `['a']`
though `['b','c']` satisfies the promise. Requirement 1 was mechanical and unambiguous, so
the executor was right to follow it; the Objective was the wrong text. **Grading against
the task file means the task file gets graded too** — worth knowing if you write specs for
this thing, because it will find yours.

The scout, meanwhile, hit that same conflict in a probe and resolved it silently against
amendment B, reporting `Open questions: None`. Defensible answer, but the decision was not
the scout's to make — the same failure mode as cycle 3, smaller, and now visible because
there is a section it should have appeared in.

One last thing, seen in cycles 2 and 3: the executor reported a single-line
`python -c "... try: ... except ..."` as exiting 0 with the expected output. That string is
a `SyntaxError`. **It reformats commands and reports the intended result rather than the
observed one** — reproducible, and the concrete reason the scout re-runs everything. Cycle 4
avoided the construct entirely and had no transcript discrepancy, which suggests writing
verification commands that survive reformatting is the cheaper fix.


---

## Layout

```
relay/
├── relay.ps1              Windows / psmux control plane
├── relay.sh               macOS / Linux / tmux control plane
└── charters/              agent operating contracts
    ├── executor.md
    ├── scout.md
    ├── mutator.md
    └── validator.md
commands/                  Claude Code slash commands
├── relay-new.md           scaffold a project + bring the relay up
├── relay-up.md            bring the relay up on an existing project
├── relay-task.md          run a full cycle, driven step by step
├── relay-auto.md          run the whole queue unattended (autopilot)
├── relay-status.md        health and bus contents
└── relay-down.md          tear it down
index.html                 setup guide site
```
