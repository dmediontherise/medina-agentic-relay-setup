#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/env.sh"
L="$RELAY_HOME/lanes.sh"
ws="$(t_repo)"; cp "$here/fixtures/odd/tasks/demo.md" "$ws/odd/tasks/demo.md"
git -C "$ws" add -A; git -C "$ws" commit -qm doc

out="$(bash "$L" explore -w "$ws" --doc odd/tasks/demo.md --task T1 --question "where is a?")"
t_has "explore reports ok" "$out" "LANE explore ok"
run="${out##* }"
t_file "map written" "$run/map.md"
t_has  "specs excerpt has S1" "$(cat "$run/specs.md")" "a must hold a marker"
t_hasnt "specs excerpt omits S2" "$(cat "$run/specs.md")" "b must hold"
t_has  "dispatch names explore charter" "$(cat "$run"/explore-1.sh)" "lane-explore.md"

out="$(bash "$L" write -w "$ws" --doc odd/tasks/demo.md --task T1)"
t_has  "write ok" "$out" "LANE write ok"
t_file "writer output in scope" "$ws/src/a/T1.txt"

out="$(STUB_write=stray bash "$L" write -w "$ws" --doc odd/tasks/demo.md --task T2)"
t_has    "stray -> scope-violation" "$out" "LANE write scope-violation"
t_nofile "stray reverted" "$ws/stray.txt"
t_file   "in-scope work kept" "$ws/src/b/T2.txt"
run="${out##* }"
t_has    "violation recorded" "$(cat "$run/scope-violations.txt")" "stray.txt"

head0="$(git -C "$ws" rev-parse HEAD)"
out="$(STUB_write=commit bash "$L" write -w "$ws" --doc odd/tasks/demo.md --task T2)"
t_eq  "writer commit undone" "$(git -C "$ws" rev-parse HEAD)" "$head0"
t_has "still ok" "$out" "LANE write ok"

out="$(bash "$L" write -w "$ws" --doc odd/tasks/demo.md --task T9 2>&1 || true)"
t_has "unknown task fails" "$out" "no row T9"
t_done
