# shellcheck shell=bash
# Minimal assertions for the lanes tests. Each test file sources this, calls t_*,
# and ends with t_done, which exits non-zero when anything failed.
T_FAILS=0; T_COUNT=0
t_ok()   { T_COUNT=$((T_COUNT + 1)); printf '  ok   %s\n' "$1"; }
t_bad()  { T_COUNT=$((T_COUNT + 1)); T_FAILS=$((T_FAILS + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
t_eq()   { if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "expected [$3] got [$2]"; fi; }
t_has()  { case "$2" in *"$3"*) t_ok "$1" ;; *) t_bad "$1" "[$3] not in [$2]" ;; esac; }
t_hasnt(){ case "$2" in *"$3"*) t_bad "$1" "[$3] unexpectedly in [$2]" ;; *) t_ok "$1" ;; esac; }
t_file() { if [ -f "$2" ]; then t_ok "$1"; else t_bad "$1" "missing file $2"; fi; }
t_nofile(){ if [ -e "$2" ]; then t_bad "$1" "unexpected file $2"; else t_ok "$1"; fi; }
t_true() { if eval "$2"; then t_ok "$1"; else t_bad "$1" "false: $2"; fi; }
t_done() { printf '%s: %d checks, %d failed\n' "$(basename "$0")" "$T_COUNT" "$T_FAILS"; [ "$T_FAILS" -eq 0 ]; }

# A throwaway git repo with one commit; prints its path.
t_repo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email lanes@test; git -C "$d" config user.name lanes-test
  mkdir -p "$d/src/a" "$d/src/b" "$d/odd/tasks"
  printf 'a\n' > "$d/src/a/one.txt"; printf 'b\n' > "$d/src/b/two.txt"; printf 'r\n' > "$d/README.md"
  git -C "$d" add -A; git -C "$d" commit -qm init
  printf '%s' "$d"
}
