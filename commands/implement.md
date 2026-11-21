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
