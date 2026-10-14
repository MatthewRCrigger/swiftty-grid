#!/bin/sh
# Real OpenSSH + real swifttyd test without touching this Mac's SSH setup.
# The environment (OpenSSH VM, swifttyd agent, bridges) comes from
# Scripts/real-ssh-env.sh; this runs the SwiftPM RealOpenSSHTests against it.
set -eu
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
env_file=$("$repository_root/Scripts/real-ssh-env.sh" start)
workspace=$(dirname "$env_file")
cleanup_fixture() {
  fixture_status=$?
  trap - EXIT
  trap '' INT TERM
  if ! "$repository_root/Scripts/real-ssh-env.sh" stop "$workspace"; then
    echo "fixture cleanup incomplete: $workspace" >&2
    [ "$fixture_status" -ne 0 ] || fixture_status=1
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
. "$env_file"

cd "$repository_root"
status=0
rm -f "$workspace/test-events.jsonl"
RST_REAL_SSH_POSIX=${RST_REAL_SSH_POSIX:-} \
  mise exec -- swift test --filter RealOpenSSHTests \
  --event-stream-version 0 --event-stream-output-path "$workspace/test-events.jsonl" \
  >"$workspace/test.log" 2>&1 || status=$?
grep -E "✔ Test|✘|recorded|Test run with" "$workspace/test.log" || true
if [ "$status" -eq 0 ]; then
  python3 -I "$repository_root/Scripts/real-ssh-evidence.py" "$workspace/test-events.jsonl" || status=$?
fi
exit "$status"
