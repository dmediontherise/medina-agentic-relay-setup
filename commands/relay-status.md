---
description: "Show relay session health, pane state, and what is on the file bus"
---

Report the current state of the agentic relay.

1. Session and bus summary:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" status
   ```

2. Live view of all three agents:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent executor -Lines 30
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent scout -Lines 30
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent validator -Lines 30
   ```

3. Summarize for the user:
   - Is the relay up, and is each agent idle, working, or stuck?
   - What is the newest artifact in `tasks/`, `results/`, `evidence/`, `reports/`?
   - Any cycle that dispatched but never produced its artifact?

A pane sitting on an auth screen, a trust prompt, or an approval dialog is **stuck**,
not working. Say so explicitly and name the prompt it is waiting on — a relay that
looks busy but is blocked is the main failure mode worth catching early.
