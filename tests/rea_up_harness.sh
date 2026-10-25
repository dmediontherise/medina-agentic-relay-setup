#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tests/rea_up_harness.sh - verification harness for relay.sh REA integration
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEMP_RELAY_DIR="$(mktemp -d)"
TEMP_WS="$(mktemp -d)"
TEMP_BIN="$(mktemp -d)"

RELAY_SESSION="reatest"
export RELAY_SESSION

cleanup() {
  local rc=$?
  if tmux has-session -t "$RELAY_SESSION" 2>/dev/null; then
    bash "$TEMP_RELAY_DIR/relay/relay.sh" down >/dev/null 2>&1 || tmux kill-session -t "$RELAY_SESSION" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_RELAY_DIR" "$TEMP_WS" "$TEMP_BIN" 2>/dev/null || true
  exit $rc
}
trap cleanup EXIT INT TERM

# Copy relay/ into a fresh temp directory
cp -r "$REPO_ROOT/relay" "$TEMP_RELAY_DIR/relay"
RELAY_HOME="$TEMP_RELAY_DIR/relay"
RELAY_BIN="$RELAY_HOME/relay.sh"
export RELAY_HOME

# Stub rea binary
cat << 'EOF' > "$TEMP_BIN/rea"
#!/bin/sh
case "${1:-}" in
  --version)
    echo "6.7.0"
    exit 0
    ;;
  doctor)
    if [ "${2:-}" = "--json" ]; then
      printf '%s\n' '{"healthy":false,"scope_checks":[{"name":"node","classification":"healthy"}]}'
      exit 0
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$TEMP_BIN/rea"

# Stub agy, claude, opencode (sleep 600 with fault hint so liveness fails fast)
for cmd in agy claude opencode; do
  cat << 'EOF' > "$TEMP_BIN/$cmd"
#!/bin/sh
echo "Agent execution terminated due to error"
exec sleep 600
EOF
  chmod +x "$TEMP_BIN/$cmd"
done

export PATH="$TEMP_BIN:$PATH"

# ---------------------------------------------------------------------------
# Run 1: RELAY_REA=1
# ---------------------------------------------------------------------------
out1="$(RELAY_SESSION="$RELAY_SESSION" RELAY_REA=1 bash "$RELAY_BIN" up -w "$TEMP_WS" 2>&1 || true)"

# (a) <ws>/.relay/rea.md exists and is byte-identical to relay/charters/rea.md
if [ ! -f "$TEMP_WS/.relay/rea.md" ]; then
  echo "Assertion (a) failed: $TEMP_WS/.relay/rea.md does not exist" >&2
  exit 1
fi
if ! cmp -s "$TEMP_WS/.relay/rea.md" "$REPO_ROOT/relay/charters/rea.md"; then
  echo "Assertion (a) failed: $TEMP_WS/.relay/rea.md is not byte-identical to $REPO_ROOT/relay/charters/rea.md" >&2
  exit 1
fi

# (b) <ws>/.relay/rea/ exists
if [ ! -d "$TEMP_WS/.relay/rea" ]; then
  echo "Assertion (b) failed: $TEMP_WS/.relay/rea/ does not exist" >&2
  exit 1
fi

# (c) every <ws>/.relay/launch/*.sh agent launcher has stub rea's directory as first PATH entry
for role in executor scout mutator validator executor-oc scout-oc mutator-oc; do
  lfile="$TEMP_WS/.relay/launch/$role.sh"
  if [ ! -f "$lfile" ]; then
    echo "Assertion (c) failed: launcher $lfile missing" >&2
    exit 1
  fi
  first_path="$(grep '^export PATH="' "$lfile" | head -1 | sed -e 's/^export PATH="//' -e 's/:.*//')"
  if [ "$first_path" != "$TEMP_BIN" ]; then
    echo "Assertion (c) failed: launcher $role.sh first PATH entry is '$first_path', expected '$TEMP_BIN'" >&2
    exit 1
  fi
done

# (d) executor, scout and validator launchers mention .relay/rea.md, mutator launchers do not
for role in executor scout validator executor-oc scout-oc; do
  lfile="$TEMP_WS/.relay/launch/$role.sh"
  if ! grep -q '\.relay/rea\.md' "$lfile"; then
    echo "Assertion (d) failed: launcher $role.sh does not mention .relay/rea.md" >&2
    exit 1
  fi
done
for role in mutator mutator-oc; do
  lfile="$TEMP_WS/.relay/launch/$role.sh"
  if grep -q '\.relay/rea\.md' "$lfile"; then
    echo "Assertion (d) failed: launcher $role.sh mentions .relay/rea.md" >&2
    exit 1
  fi
done

# (e) up's output contains rea bin line with stub path and 6.7.0
if ! printf '%s\n' "$out1" | grep -q "rea    bin   : $TEMP_BIN/rea   (6.7.0)"; then
  echo "Assertion (e) failed: output does not contain rea bin with stub path and 6.7.0" >&2
  echo "$out1" >&2
  exit 1
fi

# Clean down after Run 1
RELAY_SESSION="$RELAY_SESSION" bash "$RELAY_BIN" down >/dev/null 2>&1 || true
rm -rf "$TEMP_WS/.relay"

# ---------------------------------------------------------------------------
# Run 2: RELAY_REA_BIN=/nonexistent/rea
# ---------------------------------------------------------------------------
out2="$(RELAY_SESSION="$RELAY_SESSION" RELAY_REA=1 RELAY_REA_BIN=/nonexistent/rea bash "$RELAY_BIN" up -w "$TEMP_WS" 2>&1 || true)"

# (f) up's output contains one RELAY_REA=1 but REA is unusable line naming /nonexistent/rea
unusable_count="$(printf '%s\n' "$out2" | grep -c "RELAY_REA=1 but REA is unusable.*binary '/nonexistent/rea' not found" || true)"
if [ "$unusable_count" -ne 1 ]; then
  echo "Assertion (f) failed: expected 1 unusable warning naming /nonexistent/rea, got $unusable_count" >&2
  echo "$out2" >&2
  exit 1
fi

# (g) no launcher mentions rea.md
for lfile in "$TEMP_WS"/.relay/launch/*.sh; do
  [ -f "$lfile" ] || continue
  if grep -q 'rea\.md' "$lfile"; then
    echo "Assertion (g) failed: launcher $lfile mentions rea.md" >&2
    exit 1
  fi
done

# Clean down after Run 2
RELAY_SESSION="$RELAY_SESSION" bash "$RELAY_BIN" down >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Checks on relay.sh rea (survivors 9, 10, 3, 5)
# ---------------------------------------------------------------------------
# (h) RELAY_REA=1 relay.sh rea prints ready (survivor 9) and node: healthy (survivor 10)
rea_out="$(RELAY_SESSION="$RELAY_SESSION" RELAY_REA=1 bash "$RELAY_BIN" rea)"
if ! printf '%s\n' "$rea_out" | grep -q "status        : ready"; then
  echo "Assertion (h) failed: relay.sh rea did not output 'status        : ready'" >&2
  echo "$rea_out" >&2
  exit 1
fi
if ! printf '%s\n' "$rea_out" | grep -q "node: healthy"; then
  echo "Assertion (h) failed: relay.sh rea did not output 'node: healthy' scope check" >&2
  echo "$rea_out" >&2
  exit 1
fi

# (i) RELAY_REA=1 relay.sh rea --print-boot bogus exits non-zero (survivor 3)
if RELAY_SESSION="$RELAY_SESSION" RELAY_REA=1 bash "$RELAY_BIN" rea --print-boot bogus >/dev/null 2>&1; then
  echo "Assertion (i) failed: rea --print-boot bogus exited 0 when non-zero was expected" >&2
  exit 1
fi

# (j) with charters/rea.md removed from temp RELAY_HOME, reports unusable and names charter (survivor 5)
rm -f "$RELAY_HOME/charters/rea.md"
rea_out_nocharter="$(RELAY_SESSION="$RELAY_SESSION" RELAY_REA=1 bash "$RELAY_BIN" rea)"
if ! printf '%s\n' "$rea_out_nocharter" | grep -q "status        : unusable"; then
  echo "Assertion (j) failed: did not report unusable when charter is missing" >&2
  echo "$rea_out_nocharter" >&2
  exit 1
fi
if ! printf '%s\n' "$rea_out_nocharter" | grep -q "charter '.*rea\.md' missing"; then
  echo "Assertion (j) failed: did not name missing charter" >&2
  echo "$rea_out_nocharter" >&2
  exit 1
fi

echo "PASS"
exit 0
