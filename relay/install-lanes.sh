#!/usr/bin/env bash
# Installs lanes into ~/.claude/relay and its commands into ~/.claude/commands. Every file
# it would overwrite is first copied to <file>.bak-<stamp>-pre-lanes, same convention as
# the earlier relay installs. relay.sh, relay.ps1 and the legacy charters are not touched
# except charters this repo also ships (they are backed up first).
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst="$HOME/.claude"; stamp="$(date +%Y%m%d-%H%M%S)"
put() { # <from> <to>
  mkdir -p "$(dirname "$2")"
  if [ -f "$2" ] && ! cmp -s "$1" "$2"; then cp -p "$2" "$2.bak-$stamp-pre-lanes"; fi
  cp -p "$1" "$2"
}
put "$src/relay/lanes.sh" "$dst/relay/lanes.sh"; chmod +x "$dst/relay/lanes.sh"
for f in "$src"/relay/lanes/*.sh; do put "$f" "$dst/relay/lanes/$(basename "$f")"; done
for f in "$src"/relay/charters/*.md; do put "$f" "$dst/relay/charters/$(basename "$f")"; done
for f in relay_jev.py relay_cite.py; do [ -f "$src/relay/$f" ] && put "$src/relay/$f" "$dst/relay/$f"; done
for f in lane implement relay-auto execute-plan; do put "$src/commands/$f.md" "$dst/commands/$f.md"; done
echo "lanes installed to $dst/relay (backups: *.bak-$stamp-pre-lanes)"
