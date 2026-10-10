#!/bin/sh
# Runs Tests/SimulatorRuntime in a simulator runtime against a real
# a SwiftMux service with roaming (`swiftmux-agent --roaming-config`) on this Mac (loopback QUIC, real PTY).
#   Scripts/test-roaming-simulator.sh <simulator-udid> [platform]
# platform: iOS (default), tvOS or visionOS.
set -eu
[ "$#" -ge 1 ] || { echo "usage: $0 <simulator-udid> [iOS|tvOS|visionOS]" >&2; exit 2; }
udid=$1
platform=${2:-iOS}
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d /tmp/rsts.XXXXXX)
echo "Workspace (results and host log): $workspace"

(cd "$repository_root" && mise exec -- swift build --product swiftmux-agent && mise exec -- swift build --product swmux-launcher && mise exec -- swift build --product swifttyd >/dev/null)
bin_dir="$(cd "$repository_root" && mise exec -- swift build --show-bin-path)"
host_bin="$bin_dir/swiftmux-agent"
port=$((51300 + $$ % 500))
printf '{"bindAddress":"127.0.0.1","advertisedHost":"127.0.0.1","port":%s,"stateDirectory":"%s/state"}' \
  "$port" "$workspace" >"$workspace/config.json"
"$host_bin" --mach-service "com.chr33s.swiftty.swiftmux.test.$$" --launcher "$bin_dir/swmux-launcher" --roaming-config "$workspace/config.json" 2>"$workspace/host.log" &
host_pid=$!
trap 'kill $host_pid 2>/dev/null || true' EXIT INT TERM
i=0
while [ ! -S "$workspace/state/control.sock" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done

case $platform in
  iOS) destination="platform=iOS Simulator,id=$udid" ;;
  tvOS) destination="platform=tvOS Simulator,id=$udid" ;;
  visionOS) destination="platform=visionOS Simulator,id=$udid" ;;
  *) echo "unknown platform $platform" >&2; exit 2 ;;
esac

cat >"$workspace/project.yml" <<YML
name: RoamingRuntime
options:
  deploymentTarget: { iOS: "27.0", tvOS: "27.0", visionOS: "27.0" }
settings:
  base:
    SWIFT_VERSION: "6.0"
    GENERATE_INFOPLIST_FILE: YES
    CODE_SIGNING_ALLOWED: NO
packages:
  Swiftty: { path: "$repository_root" }
targets:
  RoamingRuntimeTests:
    type: bundle.unit-test
    platform: $platform
    sources: [{ path: "$repository_root/Tests/SimulatorRuntime" }]
    dependencies:
      - { package: Swiftty, product: TerminalSurface }
      - { package: Swiftty, product: ScreenProtocol }
      - { package: Swiftty, product: SessionCore }
      - { package: Swiftty, product: SwifttyCore }
    settings:
      base: { PRODUCT_BUNDLE_IDENTIFIER: dev.swiftty.roaming.runtime-tests }
schemes:
  RoamingRuntime:
    build: { targets: { RoamingRuntimeTests: [test] } }
    test: { targets: [RoamingRuntimeTests] }
YML
cd "$workspace"
xcodegen generate --spec project.yml >/dev/null
TEST_RUNNER_RST_CONTROL_SOCKET="$workspace/state/control.sock" \
  xcodebuild -scheme RoamingRuntime -destination "$destination" \
  -derivedDataPath "$workspace/build" -collect-test-diagnostics never test \
  2>&1 | tee "$workspace/xcodebuild.log" | grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)|Executed"
