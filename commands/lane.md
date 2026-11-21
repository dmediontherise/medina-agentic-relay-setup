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
