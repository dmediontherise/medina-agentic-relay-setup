#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/../../relay/lanes/lib.sh"
doc="$here/fixtures/odd/tasks/demo.md"

row="$(lane_row "$doc" T3)"
t_has  "lane_row finds T3"            "$row" "Data marker in c"
t_eq   "lane_row misses unknown id"   "$(lane_row "$doc" T9)" ""
t_eq   "lane_row_id"                  "$(lane_row_id "$row")" "T3"
t_eq   "lane_row_mark pending"        "$(lane_row_mark "$row")" " "
t_eq   "route"                        "$(lane_row_route "$row")" "inline"
t_eq   "risk kv keeps parens"         "$(lane_row_kv "$row" risk)" "high(data)"
t_true "risk high"                    'lane_row_risk_high "$row"'
t_true "T1 not high"                  '! lane_row_risk_high "$(lane_row "$doc" T1)"'
t_eq   "In"                           "$(lane_row_in "$row")" "src/c"
t_eq   "after"                        "$(lane_row_after "$row")" "T1"
t_eq   "specs"                        "$(lane_row_specs "$row")" "S3"
t_eq   "title"                        "$(lane_row_title "$row")" "Data marker in c"
t_eq   "pending ids"                  "$(lane_pending_ids "$doc" | tr '\n' ' ')" "T1 T2 T3 "
t_eq   "route of ODD-style value"     "$(lane_row_route '- [ ] A1 S8/S9 x (route: inline, test-first; commit: e98)')" "inline"
t_eq   "specs from S8/S9"             "$(lane_row_specs '- [ ] A1 S8/S9 x (route: inline)' | tr '\n' ' ')" "S8 S9 "
t_eq   "In: is case-insensitive"      "$(lane_row_in '- [ ] A S1 x (route: write; in: `src/x`, src/y)')" "src/x src/y"
t_eq   "no parenthetical -> no route" "$(lane_row_route '- [ ] A S1 just text')" ""
t_done
