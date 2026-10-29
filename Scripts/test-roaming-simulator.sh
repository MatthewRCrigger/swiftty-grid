#!/bin/sh
# Runs Tests/SimulatorRuntime in a simulator runtime against a real
# SwiftMux service with roaming (`swiftmux-agent --roaming-config`) on this Mac (loopback QUIC, real PTY).
#   Scripts/test-roaming-simulator.sh <simulator-udid> [platform] [--configuration debug|release]
# platform: iOS (default), tvOS or visionOS.
# Configuration applies to both the native host and simulator tests; default debug.
set -eu
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
exec python3 -I "$repository_root/Scripts/roaming-simulator.py" "$@"
