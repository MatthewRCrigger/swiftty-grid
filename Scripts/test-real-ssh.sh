#!/bin/sh
# Real OpenSSH + real swifttyd test without touching this Mac's SSH setup.
# The environment (OpenSSH VM, swifttyd agent, bridges) comes from
# Scripts/real-ssh-env.sh; this runs the SwiftPM RealOpenSSHTests against it.
set -eu
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
env_file=$("$repository_root/Scripts/real-ssh-env.sh" start)
workspace=$(dirname "$env_file")
trap '"$repository_root/Scripts/real-ssh-env.sh" stop "$workspace"' EXIT INT TERM
. "$env_file"

cd "$repository_root"
RST_REAL_SSH_POSIX=${RST_REAL_SSH_POSIX:-} \
  mise exec -- swift test --filter RealOpenSSHTests 2>&1 | tee "$workspace/test.log" \
  | grep -E "✔ Test|✘|recorded|Test run with"
