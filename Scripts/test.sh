#!/bin/bash
# A successful SwiftPM exit must also complete every started Swift Testing run.
set -euo pipefail
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$repository_root"
test_log=$(mktemp "${TMPDIR:-/tmp}/swiftty-test.XXXXXX")
trap 'rm -f "$test_log"' EXIT

# pipefail preserves test/build failures and failed log capture. Keep the
# original output visible while checking completion from the same bytes.
swift test "$@" 2>&1 | tee "$test_log"
python3 Scripts/check-test-output.py --suite-log "$test_log"
