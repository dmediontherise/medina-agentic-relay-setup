---
description: "Tear down the psmux agentic relay session"
---

Shut down the relay.

1. Before killing anything, check for work in flight:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" status
   ```
   If a task was dispatched with no matching result or report yet, tell the user what
   is still running and confirm before tearing down — killing the session loses that
   agent's in-memory context, though bus artifacts on disk survive.

   **If autopilot is running, stop it first.** Tearing the session out from under it
   leaves it dispatching into dead panes until its restart budget runs out. Create the
   stop file and let it finish the phase it is in:
   ```
   New-Item -ItemType File "<workspace>\.relay\STOP"
   ```
   Then wait for the autopilot process to exit before running `down`.

2. Tear down:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" down
   ```

3. Confirm the session is gone and remind the user that `.relay/` in the workspace is
   kept as the audit trail of the run.
