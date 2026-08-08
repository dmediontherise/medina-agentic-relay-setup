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

2. Tear down:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" down
   ```

3. Confirm the session is gone and remind the user that `.relay/` in the workspace is
   kept as the audit trail of the run.
