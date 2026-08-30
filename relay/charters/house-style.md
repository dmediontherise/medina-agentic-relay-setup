# Relay House Style

Standing law for every pane. It governs **how you write**, not what you decide — your role
charter governs that. Where the two touch, the charter wins on substance and this file
wins on form.

## Purpose

One pane's output is the next pane's entire view of reality, and one of those panes costs
money. Every line you write is read by an agent whose budget you are spending. Write for
that reader.

## Positive patterns

- **Cite, do not restate.** The task file is on disk and every pane has it. Name the
  requirement number; do not quote it back.
- **One claim, one source you can point at.** A `file:line`, a command, or a probe. A
  sentence describing what code does is weaker than the two-token citation that proves it.
- **Length tracks the change, not the effort.** A three-line diff does not earn a
  hundred-line artifact. A subtle one earns more than a large mechanical one.
- **Lead with what changes a decision.** Verdict first, table before prose, the
  disqualifying defect above the four small ones.
- **Contradict upstream directly, by line.** "Evidence R2 says X; `content.js:294` does Y"
  beats any amount of hedging around it.
- **Say the thing you could not establish.** `none` and `partial` are answers. Silence
  reads as coverage.

## Negative patterns

The bus is currently clean of these — 9,500 lines of artifacts with no measurable filler
(2026-08-30). This list exists to keep it that way, not to fix a present problem.

- No preamble. Do not open by restating the task or announcing what you are about to do.
- No summary section that repeats the sections above it.
- No pasted passing output. One result line per green command. Failing output is verbatim.
- No praise, agreement, or hedging without a stated reason.
- No decorative headings, emoji, or motivational framing.
- No filler: "load-bearing", "worth noting", "it is important to", "comprehensive",
  "robust", "seamless", and "ensure" where "make" or "check" is meant.
- Never describe work you did not do, or cite a file you did not write.

## Reference codes

When an artifact carries three or more items of one kind, code them, and keep the codes
stable for the rest of the run so any pane can cite `D2` instead of restating it.

`R1..` requirements (from the task file — never renumber them) · `F1..` findings ·
`D1..` defects · `C1..` concerns · `Q1..` open questions · `M1..` surviving mutants

A code that means one thing in the evidence file means the same thing in the report, in
the follow-up task, and in an escalation. Do not invent codes for an artifact with fewer
than three items of a kind.

## Aliases

These expand only as a standalone token in a message to you. Inside a longer word or a
file path they are not aliases.

- `scr` — Simplify and compress your last artifact. Same facts, fewer lines.
- `foc` — What is the one thing here that changes the verdict? Answer only that.
- `evd` — Restate your last claim as a command I can run or a `file:line` I can open.
- `thin` — Your evidence is thin on the requirement named next. Establish it or mark it
  `none`.

## Two examples, both from this relay's own traffic

**Reporting a green command.**

Do: `| `python -m pytest -q` | 0 | 265 passed |`

Not: three sentences about having comprehensively verified the changes, followed by eighty
lines of pytest output.

**Grading a requirement you did not establish by execution.**

Do: `| R5 | README prose; no assertion exists to name | README.md:14 | partial |`

Not: `| R5 | The implementation appears correct based on my reading | direct |`
