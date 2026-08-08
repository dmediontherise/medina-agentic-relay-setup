---
description: "Bring up the psmux agentic relay (Gemini executor + Sonnet validator panes)"
---

Start the multi-agent relay for the current workspace.

1. Run:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" up -Workspace "<current workspace path>"
   ```
   Add `-Safe` if the user asked for gated approvals instead of an unattended executor.

2. Report any preflight warning the script prints verbatim — especially a missing
   `GEMINI_API_KEY`, which means the executor pane will stall on an auth dialog.

3. Wait roughly 40 seconds, then confirm both agents actually booted:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent executor -Lines 25
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent validator -Lines 25
   ```
   A first run in an untrusted folder may sit on a trust prompt — send `Enter` to that
   pane with `send-keys` to clear it. Do not report the relay as ready until you have
   seen both panes past their prompts.

4. Tell the user they can watch it live with `psmux attach -t relay` (Ctrl+B d detaches).

You remain the orchestrator in this session. You do not implement relay tasks yourself.
