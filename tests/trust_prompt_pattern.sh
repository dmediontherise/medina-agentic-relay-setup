#!/usr/bin/env bash
# The folder-trust detector in relay.sh and relay.ps1 must recognise every wording
# Claude Code has used for its trust dialog, or the validator pane exits on "No, exit".
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
pat_sh="$(sed -nE "s/.*pane_match \"\\\$txt\" '([^']*trust[^']*)'.*/\1/p" "$here/../relay/relay.sh" | head -n 1)"
pat_ps="$(sed -nE "s/.*Pattern = '([^']*trust[^']*)'.*What = 'folder-trust prompt'.*/\1/p" "$here/../relay/relay.ps1" | head -n 1)"
check() { # <name> <pattern> <text> <want 0|1>
  if printf '%s\n' "$3" | grep -qiE -- "$2"; then got=0; else got=1; fi
  if [ "$got" = "$4" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi
}
old='Do you trust the files in this folder? ... trust the contents of this directory'
new2='Quick safety check: Is this a project you created or one you trust? (Like your'
for which in sh ps; do
  [ "$which" = sh ] && p="$pat_sh" || p="$pat_ps"
  [ -n "$p" ] || { echo "  FAIL $which: pattern not found"; fail=1; continue; }
  check "$which matches old wording"            "$p" "$old" 0
  check "$which matches 2026-11 wording"        "$p" "$new2" 0
  check "$which ignores ordinary output"        "$p" "Running tests... 14 passed" 1
done
[ "$fail" = 0 ] && echo "trust_prompt_pattern: ok" || { echo "trust_prompt_pattern: FAILED"; exit 1; }
