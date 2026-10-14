#!/bin/sh
# Acceptance test A2 on a physical iPhone: keep one roaming session open
# while a person switches the phone between Wi-Fi and cellular.
#
#   Scripts/test-handover.sh <device-udid> [switches] [team-id]
#
# The phone must reach this Mac on both networks, e.g. both on the same
# Tailscale tailnet: RST_PUBLIC_HOST defaults to this Mac's tailnet IPv4.
# The phone shows progress; evidence is the Mac-side log written by the
# retained shell. Toggle Wi-Fi when the phone says so.
set -eu
[ "$#" -ge 1 ] || { echo "usage: $0 <device-udid> [switches] [team-id]" >&2; exit 2; }
udid=$1
switches=${2-50}
case "$switches" in
  *[!0-9]*|'') echo "switches must be a positive integer" >&2; exit 2 ;;
esac
if ! [ "$switches" -gt 0 ] 2>/dev/null; then
  echo "switches must be a positive integer" >&2
  exit 2
fi
team=${3:-72KB9YQR7B}
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
# RST_PUBLIC_HOST=<router's public IP> with RST_QUIC_PORT/RST_SSH_PORT
# forwarded tests direct QUIC migration without a VPN.
if [ -z "${RST_PUBLIC_HOST:-}" ]; then
  RST_PUBLIC_HOST=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 2>/dev/null | head -1 || true)
fi
[ -n "$RST_PUBLIC_HOST" ] || { echo "set RST_PUBLIC_HOST (no tailnet address found)" >&2; exit 2; }
export RST_PUBLIC_HOST

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

bundle=dev.swiftty.roaming.handover
progress="$workspace/handover-progress.log"
: >"$progress"
mkdir -p "$workspace/handover"
cat >"$workspace/handover/project.yml" <<YML
name: Handover
options:
  deploymentTarget: { iOS: "27.0" }
settings:
  base:
    SWIFT_VERSION: "6.0"
    GENERATE_INFOPLIST_FILE: YES
    CODE_SIGN_STYLE: Automatic
    DEVELOPMENT_TEAM: $team
    CODE_SIGN_IDENTITY: Apple Development
packages:
  Swiftty: { path: "$repository_root" }
targets:
  Handover:
    type: application
    platform: iOS
    sources:
      - { path: "$repository_root/Tests/DeviceHandover" }
      - { path: "$repository_root/Tests/Support/HandoverObservation.swift" }
      - { path: "$repository_root/Tests/Support/HandoverExecution.swift" }
    dependencies:
      - { package: Swiftty, product: TerminalSurface }
      - { package: Swiftty, product: SSHClient }
      - { package: Swiftty, product: ScreenProtocol }
      - { package: Swiftty, product: SessionCore }
      - { package: Swiftty, product: SwifttyCore }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $bundle
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_NSLocalNetworkUsageDescription: Roaming SSH connects to your Mac.
YML
cd "$workspace/handover"
xcodegen generate --spec project.yml >/dev/null
echo "building handover app for $udid"
xcodebuild -scheme Handover -destination "platform=iOS,id=$udid" \
  -derivedDataPath "$workspace/handover/build" build >"$workspace/handover-build.log" 2>&1 \
  || { echo "build failed; see $workspace/handover-build.log" >&2; exit 1; }
app="$workspace/handover/build/Build/Products/Debug-iphoneos/Handover.app"
xcrun devicectl device install app --device "$udid" "$app" >/dev/null
env_json=$(python3 -I -c '
import json, sys
keys = ["RST_HANDOVER_HOST", "RST_HANDOVER_PORT", "RST_HANDOVER_PASSWORD",
        "RST_HANDOVER_HOSTKEY", "RST_HANDOVER_LOG", "RST_HANDOVER_SWITCHES"]
print(json.dumps(dict(zip(keys, sys.argv[1:]))))' \
  "$RST_REAL_SSH_HOST" "$RST_REAL_SSH_PORT" "$RST_REAL_SSH_PASSWORD" \
  "$RST_REAL_SSH_HOSTKEY" "$progress" "$switches")
xcrun devicectl device process launch --device "$udid" --terminate-existing \
  --environment-variables "$env_json" "$bundle" >/dev/null
echo "HANDOVER launched; Mac at $RST_REAL_SSH_HOST; evidence in $progress"
echo "HANDOVER watch the phone; toggle Wi-Fi once it says 'toggle Wi-Fi'"

# Validate ordered hops, one retained shell PID, and every path/mode field.
# The monitor uses monotonic phase deadlines even if the app exits silently.
python3 -I "$repository_root/Scripts/handover-evidence.py" "$progress" "$switches"
