---
description: "Automatically hand off and trigger plan implementation via Gemini/Antigravity in another terminal"
---

Locate the latest implementation plan and activate the implementation in another terminal:

1. Search for implementation plans in the workspace:
   - Check `docs/superpowers/plans/` and `docs/maestro/plans/` for markdown files ending in `.md`.
   - Identify the most recently modified implementation plan file.

2. If no plan file is found, inform the user that they must write a plan first (using `superpowers:writing-plans` skill).

3. Once the latest plan file is found, print a confirmation message showing the plan path (e.g., `docs/superpowers/plans/YYYY-MM-DD-feature-name.md`).

4. Run this PowerShell command to:
   - Open the current workspace in Antigravity IDE (minimized).
   - Launch a new PowerShell terminal running the Gemini CLI initialized with the Maestro execution command for that plan.

Run this command:
```bash
powershell.exe -NoProfile -Command "Start-Process antigravity-ide.cmd -ArgumentList '.' -WindowStyle Minimized; Start-Process powershell -ArgumentList '-NoExit', '-Command', 'gemini -i \"/maestro:execute <plan-path>\"'"
```
*(Replace `<plan-path>` with the relative path of the plan file you found, e.g., `docs/superpowers/plans/2026-05-30-some-feature.md`)*

5. Confirm to the user:
   "🚀 Activated Antigravity IDE and launched Gemini/Maestro executor in a new terminal window to execute the plan: <plan-filename>"
