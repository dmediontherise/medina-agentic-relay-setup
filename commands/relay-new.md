---
description: "Scaffold a new project and bring the agentic relay up on it in one step"
---

Create a new project and start the relay on it: $ARGUMENTS

1. Take the project name (or path) from the arguments. If none was given, ask for one
   before doing anything — never guess a project name.

2. Run:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" new <name>
   ```
   Add `-Safe` if the user wants gated approvals instead of unattended agents.

   This creates the directory, runs `git init` with an initial commit, writes a
   `.gitignore` that excludes the `.relay/` bus, seeds `.relay/tasks/001-first-task.md`,
   and then brings the relay up. It refuses to scaffold over a non-empty directory —
   if that happens, use `/relay-up` on the existing folder instead.

3. Report any warning the script prints verbatim. A failed `git commit` usually means
   `user.email` is unset, and it leaves the repo with an empty history — say so rather
   than glossing over it.

4. Confirm the agents actually booted before calling it ready:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent executor -Lines 20
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" capture -Agent scout -Lines 20
   ```
   A pane on a trust gate, an auth screen, or an approval dialog looks identical to a
   busy one. Do not report the relay as ready until you have seen each pane past its
   prompt.

5. Offer to fill in `.relay/tasks/001-first-task.md` with the user. That file is the
   contract the validator grades against, so vague requirements there produce a
   worthless verdict — write them so someone who did not read this conversation could
   check each one, and give every requirement a verification command.

You remain the orchestrator in this session. You write specs and judge outcomes; you do
not implement relay tasks yourself.
