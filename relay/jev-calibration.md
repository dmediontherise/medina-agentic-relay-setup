# Jev gates: what was measured before anything was wired in

Measured 2026-10-11 against every graded cycle on disk in five real project workspaces (a mix of
web apps, data/research pipelines and an HTML slide deck) with Jev model
`jev-1.13.0`. `jev-calibration/eval_verdict.py` re-runs the verdict-recovery measurement
(`python -I relay/jev-calibration/eval_verdict.py <workspace>...` with the Jev venv); re-run it when the Jev model changes,
because every threshold below was chosen from these numbers.

## Rejected: Jev standing in for the validator

The obvious saving, letting Jev pass a task so the Claude validator does not run, was tested
first and does not work. Jev saw the task, the executor's result, the scout's evidence and
the mutation report, and was asked per requirement and overall whether a strict validator
would FAIL it.

| Framing | AUC (FAIL vs pass, 97 tasks: 26 FAIL / 71 pass) |
|---|---|
| per-task p(FAIL), full state | 0.61 |
| lowest per-requirement p(met) | 0.44 (worse than chance) |
| "do the scout's findings report a concrete problem" | 0.62 |
| "is any coverage row weak" | 0.41 |
| 3-way verdict choice | 0.51 |

Validator FAILs scored as low as 0.03. The validator's FAILs come from reading code against
the spec, and that signal is not in the evidence summary Jev can see. A gate built on this
would pass real failures. A "Jev thinks requirement N is weakest, start there" hint was
dropped for the same reason: the per-requirement ranking ran the wrong way.

## Kept

| Gate | Evidence | Rule chosen |
|---|---|---|
| **Verdict recovery**: a report with no `VERDICT:` line | 8 of 71 logged verdicts were `UNPARSED` and counted as passes. Jev recovered FAIL-vs-pass from header-stripped bodies of 115 real reports: 108/115 right. At confidence ≥ 0.9, 56 covered, 1 error. | Re-read for 30s first (one of them was demonstrably a write race). Then accept Jev's FAIL at any confidence, a pass only at ≥ 0.9 and only as PASS-WITH-CONCERNS. Otherwise stop for a human. The stop also applies with Jev off. |
| **BLOCKED answers** | No BLOCKED result exists in history, so this guards a rare case. Synthetic tests: a reversible spec choice was answered (p_ask_owner 0.07), a publish-to-PyPI choice was refused (0.96). | `gate_decide`, confidence ≥ 0.7, once per task, only with a `## Options` list. |
| **Sweep filter** | 70 mutation reports: 10 explicitly empty on a GREEN baseline. Rejected candidates included a RED baseline (032) and survivors written as `###` headings rather than a table (033). | Deterministic, no Jev call. Drop a report only when it says None/Zero survivors, the baseline is GREEN and mutant zero did not survive. |
| **Docs-only mutation skip** | 1 of 116 results was docs-only. HTML-only slide-deck tasks had 3-6 real survivors each. | Deterministic. Skip only `.md/.txt/.rst/.adoc` and images. Anything else is mutated. |

## Where the time actually goes (35 autopilot logs, ~22h active)

Executor 7.6h, scout + validator 6.1h. A large share of the rest is dead time: stalls
(22) and 30-minute `attempt 1: timeout` waits, including single gaps of 142m and 123m. None
of the gates above touch that. The next candidate is a Jev classifier on the working pane's
screen ("working / idle at prompt without the artifact / waiting for input / error"),
which could catch a dead pane in minutes instead of at the 10-minute stall or the
30-minute timeout. It has no historical pane captures to calibrate against, so it shipped in
shadow mode on 2026-10-11: autopilot logs Jev's guess about the waited-on pane every 2 minutes
and the wait's real outcome, and acts on neither. `jev-calibration/eval_pane_shadow.py`
reports, per confidence threshold, how many bad waits Jev flagged and how many minutes early,
against how many successful waits it would have wrongly flagged. Only that table, after
enough real runs, should decide whether a gate ever acts on it.

First look at four live panes from the session that was up on 2026-10-11: two opencode
panes that had printed DONE, an agy pane idle at an empty prompt, and a Claude pane idle
after its last grade all read as `finished-no-artifact` (once the labels said an empty
prompt is not a pending question). All four were right.

The Claude pane is worth a note, because it fooled the person checking Jev's answer before
it fooled Jev. Its input box showed `❯ Grade this task: .relay/tasks/040-…`, which reads as
a dispatch typed but never sent. It was not. It was Claude Code's prompt suggestion: ghost
text drawn **dim** (`ESC[2m`) in an empty input box and cut off with `…`. Sending Ctrl+U
changed nothing, and `tmux capture-pane -e` showed the dim attribute.

That matters when scoring the shadow. The screen it sends Jev is a plain
`tmux capture-pane -p` (`psmux capture-pane -p` on Windows), which drops text attributes, so Jev
cannot tell ghost text from typed text either. An `unsent-input` answer on a Claude pane
may be this case, so check the saved screen against the live pane with `-e` before
counting it as a real stuck dispatch. If it turns out to be common, the fix is to capture
with `-e` and mark dim runs before the screen goes to Jev, not to retune the labels.

## Citation check (code only, no Jev; on by default)

Of 30 validator FAILs across seven workspaces, 7 were a cited source that does not say what
it is cited for, the largest class after weak tests (~10) and plain bugs (~11). A check
on reported numbers versus a re-run, the first idea, covered 2 and would have caught
neither, so it was not built. `relay_cite.py` fetches each source cited in the files a
task changed, and flags a dead link, a deep link that redirects away, a `quote` missing
from the page, or a number in the claim the page does not state. Only citations the task
added count (not already committed, not recorded by an earlier task's check). Robots
blocks, JavaScript-rendered pages and hosts that answer made-up paths are listed as
unverified, never flagged.

`jev-calibration/eval_cite.py` replays every `.relay/mutants/<task>` snapshot in order
(2026-10-11, live pages). Snapshots existed for two of the workspaces with citation
defects (a research slide deck and a sports-model project):

| Set | Result |
|---|---|
| Tasks with a citation defect | 5/5 flagged |
| Other snapshotted tasks that added citations | 1/5 flagged |
| A third workspace with no snapshots (a local-services research dataset): 70 real price quotes vs the same 70 rewritten in the synthesized form its validator caught | 0/70 vs 70/70 |

The hits are the defects the validator wrote down, not near misses: five
figures credited to two government landing pages that do not show them, a methodology
link that redirects to an unrelated news section, a source host with no DNS record, and a
named index credited to a company that does not publish it. One of the five passed with
"Defects: None"; the follow-up task was written because hand-checking then found exactly
what the check flags. The one other flag is figures cited to a data download page that
does not display them; that is true, and the validator accepted it.

Misses: an expired domain now serving unrelated content (it blocks robots, so it is
unverified), and claims with no number or quote ("limited availability", "groups up to
50"). A Jev question ("do these page excerpts support the claim?") is the obvious next
gate for those, but none of them has a snapshot to calibrate against, so it was not
wired in.

Identifier digits (phone numbers, street numbers, ZIPs, occupation codes, opening hours)
are skipped. Before that rule the already-fixed dataset drew 52 false findings; after it,
1 (a rating that has since changed).

Effect on a run: findings send the task back to the executor once (`RELAY_CITE_BOUNCE=0`
keeps it to a note), and the scout and validator get a note pointing at the table. A
bounce counts as a cycle toward `--max-cycles`, like a Jev-answered BLOCKED.
