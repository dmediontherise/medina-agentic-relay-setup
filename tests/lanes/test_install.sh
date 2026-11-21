#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"
fake="$(mktemp -d)"; mkdir -p "$fake/.claude/relay" "$fake/.claude/commands"
printf 'old\n' > "$fake/.claude/commands/implement.md"
printf 'keep\n' > "$fake/.claude/relay/relay.sh"
HOME="$fake" bash "$here/../../relay/install-lanes.sh" >/dev/null
t_file "lanes installed"   "$fake/.claude/relay/lanes.sh"
t_file "lib installed"     "$fake/.claude/relay/lanes/lib.sh"
t_file "charter installed" "$fake/.claude/relay/charters/lane-mode.md"
t_file "command installed" "$fake/.claude/commands/lane.md"
t_eq   "relay.sh untouched" "$(cat "$fake/.claude/relay/relay.sh")" "keep"
t_true "implement backed up" 'ls "$fake/.claude/commands/" | grep -q "implement.md.bak-.*-pre-lanes"'
t_done
