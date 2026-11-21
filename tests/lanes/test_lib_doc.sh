#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/../../relay/lanes/lib.sh"
src="$here/fixtures/odd/tasks/demo.md"
doc="$(mktemp)"; cp "$src" "$doc"

s1="$(lane_spec_text "$doc" S1)"
t_has   "S1 bullet verbatim"          "$s1" 'a must hold a marker per task'
t_has   "S1 continuation line"        "$s1" 'Derived: one file per task'
t_hasnt "S1 excludes S2"              "$s1" 'b must hold'
t_has   "plain '- S3' bullet"         "$(lane_spec_text "$doc" S3)" 'c is data'
t_has   "no ids -> all specs"         "$(lane_spec_text "$doc")" 'b must hold'
t_eq    "runner from header"          "$(lane_doc_runner "$doc")" 'test -d src'
t_has   "header excerpt"              "$(lane_doc_header "$doc")" 'Objective: exercise'
t_hasnt "header stops at ##"          "$(lane_doc_header "$doc")" '## Specs'

row="$(lane_row "$doc" T1)"
t_eq "row_with x + commit" "$(lane_row_with "$row" x abc123)" \
  '- [x] T1 S1 Marker in a (route: write; risk: low; In: src/a; commit: abc123)'
t_eq "row_with adds commit key" "$(lane_row_with '- [ ] Z S1 t (route: write)' x f00)" \
  '- [x] Z S1 t (route: write; commit: f00)'
t_eq "row_with no parenthetical" "$(lane_row_with '- [ ] Z S1 t' '!' f00)" '- [!] Z S1 t (commit: f00)'
t_eq "row_with mark only" "$(lane_row_with "$row" '~')" \
  '- [~] T1 S1 Marker in a (route: write; risk: low; In: src/a; commit: pending)'

lane_doc_replace_row "$doc" T1 "$(lane_row_with "$row" x abc123)"
t_eq "replace_row wrote it" "$(lane_row_mark "$(lane_row "$doc" T1)")" "x"
t_eq "pending after replace" "$(lane_pending_ids "$doc" | tr '\n' ' ')" "T2 T3 "

lane_doc_insert_after "$doc" T2 '- [ ] T2.f1 S2 Fix T2 (route: write; risk: low; In: src/b)'
t_eq "insert_after order" "$(lane_pending_ids "$doc" | tr '\n' ' ')" "T2 T2.f1 T3 "

lane_doc_log "$doc" "autopilot: hello"
t_eq "log numbering continues" "$(tail -n 1 "$doc")" "- L2 autopilot: hello"
t_done
