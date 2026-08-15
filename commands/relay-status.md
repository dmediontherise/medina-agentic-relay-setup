---
description: "Show relay session health, pane state, and what is on the file bus"
---

Report the current state of the agentic relay.

1. Session and bus summary:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" status
   ```
   This also warns about tasks that have a result but no scout evidence, and about agy
   panes that have been up long enough to be at risk of wedging. Report both verbatim.

2. Agent liveness — `status` deliberately does not check this, because proving an agent
   is alive means making it answer:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" health
   ```
   Exit `1` means an agent is faulted, crashed or unresponsive; the output names it and
   prints the recovery command. Probing the agy panes is free; add `-Deep` to probe the
   validator only when you suspect that pane, since it costs Claude quota.

   Four states worth telling apart in what you report back:
   - `FAULT` — a known bad banner on screen (wedged token, rate limit, signed out).
   - `CRASHED` — the agent process is gone and the pane is a bare shell. Invisible on
     screen; only the process-tree check finds it.
   - `ABSENT` — this relay was started before that agent existed. Needs `down` then `up`,
     not a restart. You will see this for the mutator on any pre-2026-08-12 session.
   - `BUSY` — working, and deliberately not probed.

3. Live view of any agent that `health` flagged:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent scout -Lines 30
   ```

4. If an autopilot run is in flight or recently finished, read the tail of
   `.relay/logs/autopilot-latest.md` — it is the authoritative record of what the relay
   has been doing unattended, and it names the stop reason.

5. Summarize for the user:
   - Is the relay up, and is each agent healthy, working, faulted, crashed or absent?
   - What is the newest artifact in `tasks/`, `results/`, `evidence/`, `reports/`,
     `mutation/`?
   - Any cycle that dispatched but never produced its artifact?
   - Any pending task with no report yet — that is what autopilot would pick up next.

A missing mutation report is **not** a problem to report as one: the mutation lane runs in
parallel and is never waited on, so reports land late by design and are swept at the end
of a run. A missing *evidence* file, by contrast, always means the scout was broken or
skipped.

**Never read health off a capture.** A wedged agy pane shows an ordinary idle prompt with
`? for shortcuts`, identical to a healthy one, and keeps whatever `READY` it printed hours
ago in its scrollback. That is precisely how a dead scout survived six task cycles
unnoticed on 2026-08-10. `health` is the only check that tells them apart.

A pane sitting on an auth screen, a trust prompt, or an approval dialog is **stuck**, not
working. Say so explicitly and name the prompt it is waiting on.
