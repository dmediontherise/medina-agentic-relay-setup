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
