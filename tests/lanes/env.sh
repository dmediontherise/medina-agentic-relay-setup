# shellcheck shell=bash
# Shared setup for tests that run lanes against stub agents in a private tmux session.
LANES_TEST_BIN="$(mktemp -d)"
for n in agy opencode claude; do ln -s "$here/stub_agent.sh" "$LANES_TEST_BIN/$n"; done
export PATH="$LANES_TEST_BIN:$PATH"
export STUB_STATE; STUB_STATE="$(mktemp -d)"
export RELAY_HOME; RELAY_HOME="$(cd "$here/../../relay" && pwd)"
export RELAY_LANES_SESSION="lanestest$$"
export RELAY_LANES_STATE="$STUB_STATE/lanes-state"
export RELAY_LANE_TIMEOUT=8 RELAY_LANE_POLL=0.2 RELAY_LANE_LINGER=0 RELAY_JEV=0 RELAY_CITE=0 RELAY_REA=0
lanes_test_cleanup() { tmux kill-session -t "$RELAY_LANES_SESSION" 2>/dev/null || true; rm -rf "$LANES_TEST_BIN"; }
trap lanes_test_cleanup EXIT
