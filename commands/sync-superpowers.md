Pull the latest superpowers from GitHub and refresh all local skills and commands.

Run these bash commands in sequence:

```bash
git -C /c/Users/mrlgp/.claude/superpowers pull origin main
```

Then copy updated skills and commands:

```bash
cp -r /c/Users/mrlgp/.claude/superpowers/skills/* /c/Users/mrlgp/.claude/skills/
cp /c/Users/mrlgp/.claude/superpowers/commands/* /c/Users/mrlgp/.claude/commands/
```

After syncing, show the user:
1. The last 5 git commits: `git -C /c/Users/mrlgp/.claude/superpowers log --oneline -5`
2. Confirm: "Superpowers synced to version X.Y.Z — skills and commands updated."
