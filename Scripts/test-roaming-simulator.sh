#!/bin/sh
# Runs Tests/SimulatorRuntime in a simulator runtime against a real
# SwiftMux service with roaming (`swiftmux-agent --roaming-config`) on this Mac (loopback QUIC, real PTY).
#   Scripts/test-roaming-simulator.sh <simulator-udid> [platform]
# platform: iOS (default), tvOS or visionOS.
set -eu
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
exec python3 -I "$repository_root/Scripts/roaming-simulator.py" "$@"
