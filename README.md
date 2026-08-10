# Medina Agentic Relay

A closed-loop multi-agent relay. One orchestrator writes specs and grades outcomes;
three agents in live terminal panes implement, verify, and judge. Coordination happens
over a file bus, so results are lossless and every step leaves a durable artifact.

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

## The four roles

| Role | Model | Job |
|---|---|---|
| **Orchestrator** | Claude Opus (your interactive session) | Writes the task spec, dispatches, decides |
| **Executor** | `agy` on `gemini-3.6-flash-high` | Implements the task. Never grades its own work |
| **Scout** | `agy` on `gemini-3.6-flash-high` | Re-runs verification, probes edge cases, audits tests. Records **observations only** — never a verdict |
| **Validator** | Claude Opus | Grades spec vs. evidence |

### Why the scout exists

This is the non-obvious part, and the reason the relay is worth building at all.

Validation splits into two jobs: **mechanical evidence gathering** and **actual judgment**.
The scout does the former cheaply, so the validator spends its tokens on the latter. The
payoff is structural: the validator ends up grading *facts it did not gather*, about code
*written by a third agent*. Neither the claim nor the observation comes from the party
being judged.

Do not collapse the scout and validator back into one role. The independence chain is the
entire point — an agent that gathers its own evidence grades its own summary of it.

Note that the executor and the scout share a model. That does not weaken the chain:
independence here comes from **role separation**, not model identity. The scout is a
separate process with a separate charter that never sees the executor's reasoning — only
the diff and the result file, both of which it treats as claims.

### The economics, which drive the whole design

The validator is the **only** pane that spends Claude quota. Everything upstream runs on
Antigravity CLI and is effectively free.

That single fact shapes both charters. Because scouting is free, it is made *deep* — the
scout re-runs every verification command, reads the assertion bodies of the executor's
tests, and writes its own edge-case probes. Because the validator is expensive, that depth
is *compacted* before it arrives: passing commands reduce to a one-line table row, failing
ones are pasted verbatim.

Green output carries almost no information; red output carries all of it. Exploiting that
asymmetry is what buys deep verification without a large token bill — and it is what keeps
Opus affordable in the one seat that is pure judgment.

> **If you hit rate limits**, drop the validator to `sonnet` before changing anything else.
> It is the single lever that matters, and the relay still works. An earlier version of this
> project ran the scout on Sonnet too; the two review panes together exhausted the limit
> mid-run and stranded both on `/rate-limit-options` dialogs. Moving the scout to `agy` is
> what fixed it.

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
├── probe/                 Scout's throwaway edge-case tests (scratch)
├── launch/                generated pane launcher scripts
└── executor|scout|validator.md   charters, copied in at `up`
```

---

## Prerequisites

| | Windows | macOS / Linux |
|---|---|---|
| Multiplexer | [`psmux`](https://github.com/marlocarlo/psmux) — `winget install marlocarlo.psmux` | `tmux` — `brew install tmux` / `sudo apt install tmux` |
| Executor | Antigravity CLI — `irm https://antigravity.google/cli/install.ps1 \| iex` | `curl -fsSL https://antigravity.google/cli/install.sh \| sh` |
| Reviewers | Claude Code — `npm i -g @anthropic-ai/claude-code` | same |
| Shell | Windows PowerShell 5.1 | bash 4+ |

Sign in once before wiring anything up — `agy` (Google browser sign-in) and `claude`.
An agent pane sitting on an auth screen looks identical to a busy one.

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

Then drive a full cycle from your Claude session with `/relay-task <what you want built>`,
or by hand:

```bash
R=~/.claude/relay/relay.sh                 # Windows: see the PowerShell form above

$R dispatch -a executor  -T .relay/tasks/001-slug.md
$R wait     -f .relay/results/001-slug.md  -a executor  --timeout 1200

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
| `dispatch -a <agent> -T <task>` | Hand a task file to an agent |
| `wait -f <artifact>` | Block until an artifact lands. Exit 2 on timeout, with a pane dump |
| `capture -a <agent>` | Print the tail of a pane — **use this before assuming an agent is busy** |
| `send -a <agent> -t <text>` | Type a line into a running agent |
| `bus` | List artifacts, newest first |

Attach to watch it live: `tmux attach -t relay` (Windows: `psmux attach -t relay`).

### Writing a task file

The validator grades against this file, so vagueness here produces a worthless verdict.
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

## Troubleshooting

**A pane is stuck, not busy.** This is the single most common failure. A pane sitting on a
folder-trust gate, an auth screen, or an approval dialog looks exactly like one that is
thinking. `up` clears the folder-trust prompt automatically, but always run
`capture -a <agent>` before concluding an agent is working.

**`wait` times out.** It exits 2 and dumps the last 30 lines of that agent's pane. Read
that dump before retrying — it is almost always a prompt, not a slow model.

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

Being straight about this, since the failure modes above were all found the hard way:

- **`relay.ps1` (Windows/psmux)** — proven end to end on 2026-08-08. A full cycle ran
  unattended on a real task: executor implemented it, scout gathered independent evidence,
  validator returned PASS-WITH-CONCERNS. All eight subcommands exercised.
- **`relay.sh` (macOS/Linux/tmux)** — the same design ported. Syntax-checked, and its
  logic exercised against a stubbed `tmux`: launcher generation, argument escaping,
  workspace-relative path resolution, timeout/exit-code behavior, and every subcommand.
  It has **not yet been run against real tmux on macOS or Linux.** If you are the first to
  do so, please open an issue with what broke.

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

---

## Layout

```
relay/
├── relay.ps1              Windows / psmux control plane
├── relay.sh               macOS / Linux / tmux control plane
└── charters/              agent operating contracts
    ├── executor.md
    ├── scout.md
    └── validator.md
commands/                  Claude Code slash commands
├── relay-new.md           scaffold a project + bring the relay up
├── relay-up.md            bring the relay up on an existing project
├── relay-task.md          run a full cycle
├── relay-status.md        health and bus contents
└── relay-down.md          tear it down
index.html                 setup guide site
```
