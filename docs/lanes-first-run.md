# Lanes: first real run vs `relay.sh` (2026-11-21)

This is a sanity check, not a benchmark: one feature, one run each (n=1), on one WSL2
machine. Its main value was the four real bugs it found. The bugs are listed at the end,
and all four are fixed on this branch.

## The task

`wc.py` is a 41-line `wc` clone with two unittest tests. The request, verbatim:

> Add a --json flag to wc.py that prints the counts as JSON instead of the table: one
> object per file with keys file, lines, words, chars, plus a total object when there is
> more than one file. Also, a missing or unreadable file must no longer crash: print
> 'wc.py: <path>: <reason>' to stderr, keep counting the other files, and exit 1 at the
> end. Scripts depend on the exit code, so that part is the risky one.

A fresh headless Claude Code session, with gentle-ai loaded, turned the request into the
ODD document `odd/tasks/wc-json.md` in **22 s**. It wrote specs S1–S4 quoting the request,
four assumptions (A1–A4), and two rows:

- **T1** S1,S2: `route: write; risk: low; In: wc.py tests/test_json.py`
- **T2** S3,S4: `route: inline; risk: high(contracts); In: wc.py tests/test_errors.py; after: T1`

The `relay.sh` side got the same specs and assumptions, rewritten as two old-format task
files (`001-json-output.md` and `002-file-errors.md`). Both runs started from the same
base commit. The mutation lane was off in both (`--no-mutation`); lanes runs it only on
request.

## Results

| | lanes (`lanes.sh autopilot`) | `relay.sh autopilot` |
|---|---|---|
| Boot | none (one tmux window per turn) | 36 s (`up`, four panes) |
| Wall time, as measured | 464 s autopilot (T1 done, T2 blocked by bug 2) + 120 s re-running `verify` by hand after the fix = **584 s** | 36 s + 498 s = **534 s** |
| Wall time with bugs 2–3 fixed (estimate) | ≈ 470 s: the blocked run's own steps, with a 21 s validator turn in place of the 15 s failed one | 534 s |
| agy turns | 3: T1 writer (211 s), T2 prebrief (96 s), T2 evidence (142 s, 99 s on the re-run) | 6: an executor, a prebrief and a scout per task |
| Claude turns | 2 that counted: T2 inline worker (Opus, 42 s) and T2 validator (Sonnet, 21 s). Plus 5 failed validator attempts caused by bugs 2–3 | 2: one Sonnet validator per task |
| Verdicts | T1: no verdict, proved by `Runner:` (low risk). T2: PASS-WITH-CONCERNS | 001: PASS-WITH-CONCERNS, 002: PASS-WITH-CONCERNS |
| Outcome | Both rows committed by autopilot or by hand (`1c9ded3` T1, `171454f` T2), and the doc's `## Log` updated | Queue drained. Changes left uncommitted, which is how `relay.sh` works |
| Behaviour check | `unittest` OK, missing file → stderr message and `rc=1`, `--json` output correct | the same three checks, all correct |
| Tests added | 110 + 94 lines | 143 + 129 lines |

## Reading it

- **Speed was about the same.** The lanes saving is that the low-risk row skips the
  scout and the validator. On a task this small, the agy writer turn takes most of the
  time either way. The spec predicts a larger gap for features with more low-risk rows,
  which this run did not test.
- **Lanes spent half the agy turns** (3 against 6), because only the high-risk row was
  verified. T1 was proved by the doc's `Runner:` command alone, which is the trade-off the
  design makes on purpose.
- **Lanes spent more Opus.** Its inline row ran on Opus. `relay.sh` spends Claude only on
  Sonnet grading.
- **Both verified the risky contract (exit code) independently.** In lanes, the
  pre-brief was written in a sandbox that held only the specs, and its probes passed
  against the candidate.

## Bugs this run found (all fixed on this branch)

1. **lanes: gentle-ai's `.atl/` cache.** gentle-ai's prompt hook writes `.atl/` into
   any repo a Claude session runs in. Autopilot then saw a dirty tree, and an inline
   lane's run would have been flagged as out of scope. Fixed by adding `.atl/` to
   `.git/info/exclude` alongside `.relay/` (`52fd551`).
2. **lanes: headless Claude could not read the charters.** `claude -p --permission-mode
   acceptEdits` cannot answer a permission prompt, and the charters live outside the
   workspace. The validator was denied, and it rightly refused to grade. Fixed by passing
   `--add-dir <charters>` (`8e57ee1`).
3. **lanes: `--add-dir` swallowed the prompt.** `--add-dir` takes several values, so the
   prompt was read as one of them. Fixed by putting `--` before the prompt, and checked
   against the real CLI (`a5e8aec`). The stub-agent tests could not catch bugs 2–3,
   because the stubs ignore the command-line arguments.
4. **`relay.sh` and `relay.ps1`: the validator pane quit on fresh folders.** Claude
   Code's trust dialog now asks "Is this a project you created or one you trust?", which
   the old pattern missed, and the menu defaults to "No, exit". Also, a detached
   `relay.sh up` got tmux's 80×24 window, so each pane was about 40×7 and the question
   scrolled off-screen. Fixed by matching the new wording and the menu's own "No, exit"
   line, and by creating the session at 220×60 (`RELAY_TMUX_COLS` / `RELAY_TMUX_ROWS`)
   (`56dbdb2`, `1ff210d`). This had nothing to do with lanes: any fresh project would have
   hit it.

Raw material, kept outside the repo: `~/projects/lanes-first-run/`, with `base/`, `lanes/`
(including `.relay/runs/`), `relay/` (including `.relay/` reports), and the two failed
`relay.sh` attempts `relay-attempt1/` and `relay-attempt2/`.
