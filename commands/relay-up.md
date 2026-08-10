---
description: "Bring up the agentic relay (agy executor + agy scout + Opus validator panes)"
---

Start the multi-agent relay for the current workspace.

To scaffold a brand-new project instead of using the current one, use `/relay-new`.

1. Run:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" up -Workspace "<current workspace path>"
   ```
   Add `-Safe` if the user asked for gated approvals instead of unattended agents.

2. Report any preflight warning the script prints verbatim. A missing `agy` or `claude`
   binary means that pane will not start at all.

3. Confirm each agent actually booted — the script clears folder-trust prompts, but do
   not take "Relay up" as proof the agents are working:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent executor -Lines 20
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent scout -Lines 20
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent validator -Lines 20
   ```
   You want `READY` in each. A pane sitting on an auth screen or approval dialog looks
   identical to a busy one — that is this relay's most common failure. If a pane is
   stuck, say which prompt it is waiting on rather than reporting the relay as ready.

4. Tell the user they can watch it live with `psmux attach -t relay` (Ctrl+B d detaches).

You remain the orchestrator in this session. You do not implement relay tasks yourself.
