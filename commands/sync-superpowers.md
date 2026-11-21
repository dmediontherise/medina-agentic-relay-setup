Pull the latest superpowers from GitHub and refresh all local skills and commands.

Run these bash commands in sequence:

```bash
git -C "$HOME/.claude/superpowers" pull origin main
```

Then copy updated skills and commands:

```bash
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/commands"
cp -r "$HOME/.claude/superpowers/skills/." "$HOME/.claude/skills/"
cp "$HOME/.claude/superpowers/commands/"*.md "$HOME/.claude/commands/"
# Retired in favour of gentle-ai's ODD workflow (2026-11-21): these five impose a planning
# pipeline that ODD replaces. Moved to ~/.claude/skills-retired, not deleted.
for s in using-superpowers brainstorming writing-plans executing-plans subagent-driven-development; do
  rm -rf "$HOME/.claude/skills/$s"
done
rm -f "$HOME/.claude/commands/brainstorm.md" "$HOME/.claude/commands/write-plan.md"
```

After syncing, show the user:
1. The last 5 git commits: `git -C "$HOME/.claude/superpowers" log --oneline -5`
2. Confirm: "Superpowers synced to version X.Y.Z — skills and commands updated."

If the first command fails with `not a git repository`, the superpowers repo has not been
cloned yet. Clone it rather than creating the directory by hand:

```bash
git clone https://github.com/obra/superpowers.git "$HOME/.claude/superpowers"
```
