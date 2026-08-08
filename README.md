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
| **Scout** | Claude Sonnet | Re-runs verification, records **observations only** — never a verdict |
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

By default the scout and validator run with `--permission-mode bypassPermissions`, and the
executor with `--dangerously-skip-permissions`.

This is deliberate but not free, so decide with your eyes open. `acceptEdits` sounds like
the safer default and does not work here: it gates **every new Bash command shape** behind
an approval prompt, and Claude Code's "don't ask again" only covers similar prefixes. An
unattended verification agent — whose entire job is running commands — stalls forever on
prompt after prompt. In practice that is not a safety control, it is a hang.

So what keeps the scout and validator from editing the code they are judging is **their
charters, not a sandbox**. That is a convention. It has held in testing, but point this at
a repo you care about with your eyes open, and prefer a scratch clone or worktree the
first few times.

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
