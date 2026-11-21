#!/usr/bin/env bash
# Runs every tests/lanes/test_*.sh; exits non-zero if any file fails.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$here"/test_*.sh; do
  printf '== %s\n' "$(basename "$t")"
  bash "$t" || rc=1
done
exit $rc
