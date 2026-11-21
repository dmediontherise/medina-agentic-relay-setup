#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/assert.sh"; . "$here/../../relay/lanes/lib.sh"

t_true "disjoint"          '! lane_scopes_overlap "src/a" "src/b"'
t_true "same path"         'lane_scopes_overlap "src/a" "src/a"'
t_true "parent/child"      'lane_scopes_overlap "src" "src/a/x.sh"'
t_true "wildcard overlaps" 'lane_scopes_overlap "src/*" "docs"'
t_true "empty overlaps"    'lane_scopes_overlap "" "docs"'
t_true "in scope: dir"     'lane_path_in_scope "src/a/x.txt" "src/a"'
t_true "in scope: glob"    'lane_path_in_scope "src/a/x.sh" "src/*/x.sh"'
t_true "out of scope"      '! lane_path_in_scope "src/ab/x.txt" "src/a"'
t_true "dot = everything"  'lane_path_in_scope "any/thing" "."'

ws="$(t_repo)"
printf 'dirty\n' >> "$ws/src/b/two.txt"            # dirty before the lane
snaps="$(mktemp -d)"
lane_tree_state "$ws" > "$snaps/pre"
printf 'lane\n' >> "$ws/src/a/one.txt"              # lane edits tracked file in scope
mkdir -p "$ws/src/a/new"; printf 'n\n' > "$ws/src/a/new/f.txt"   # lane adds file in scope
printf 'stray\n' > "$ws/stray.txt"                 # lane adds file out of scope
printf 'more\n' >> "$ws/src/b/two.txt"             # lane edits an already-dirty file out of scope
rm "$ws/README.md"                                 # lane deletes tracked file out of scope
lane_tree_state "$ws" > "$snaps/post"

changed="$(lane_tree_delta "$snaps/pre" "$snaps/post" | tr '\n' ' ')"
t_eq "delta" "$changed" "README.md src/a/new/f.txt src/a/one.txt src/b/two.txt stray.txt "
bad="$(lane_tree_delta "$snaps/pre" "$snaps/post" | lane_out_of_scope "src/a" | tr '\n' ' ')"
t_eq "out of scope" "$bad" "README.md src/b/two.txt stray.txt "

for p in $bad; do lane_revert_path "$ws" "$p" "$snaps/pre"; done
t_nofile "stray removed"                 "$ws/stray.txt"
t_file   "deleted tracked file restored" "$ws/README.md"
t_eq     "dirty file back to pre-lane"   "$(cat "$ws/src/b/two.txt")" "$(printf 'b\ndirty')"
t_eq     "in-scope edit kept"            "$(tail -n 1 "$ws/src/a/one.txt")" "lane"

printf 'u\n' > "$ws/src/a/untracked.txt"
d="$(lane_diff "$ws")"
t_has   "diff shows tracked edit"   "$d" "+lane"
t_has   "diff shows untracked file" "$d" "untracked.txt"
t_hasnt "diff hides .relay"         "$d" ".relay"

lane_init_ws "$ws"
t_true "relay ignored by git" 'grep -qxF ".relay/" "$ws/.git/info/exclude"'
lane_init_ws "$ws"
t_eq "exclude written once" "$(grep -cxF '.relay/' "$ws/.git/info/exclude")" "1"
r="$(lane_new_run "$ws" demo T1 write)"
t_true "run dir made"       '[ -d "$r" ]'
t_eq   "latest link"        "$(readlink "$ws/.relay/runs/demo/T1/latest-write")" "$(basename "$r")"
t_done
