#!/bin/sh
# XCUITest of a real roaming SSH client app against a real OpenSSH server
# and a real swifttyd agent (Scripts/real-ssh-env.sh).
#
#   Scripts/test-app-ui.sh <destination> [extra xcodebuild args...]
#
# destination selects the app:
#   'platform=iOS Simulator,id=<udid>'       MobileClient
#   'platform=macOS,variant=Mac Catalyst'    CatalystClient
#   'platform=iOS,id=<device-udid>'          MobileClient on a physical device
#                                            (set RST_PUBLIC_HOST)
# Mac Catalyst and device destinations sign with Apple Development for team $RST_UI_TEAM
# (default 72KB9YQR7B) using locally installed profiles; nothing is
# provisioned. Extra args go to xcodebuild, e.g.
#   -only-testing:AppUITests/RoamingAppUITests/testRejectUnknownHostKey
#
# The project (app target + AppUITests UI-test target) is generated with
# XcodeGen into a temporary workspace; the server details reach the test
# runner as TEST_RUNNER_RST_UI_* variables.
set -eu
[ "$#" -ge 1 ] || { echo "usage: $0 <destination> [xcodebuild args...]" >&2; exit 2; }
destination=$1
shift
command -v xcodegen >/dev/null || { echo "xcodegen required" >&2; exit 1; }
repository_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
apps="$repository_root/Apps"
team=${RST_UI_TEAM:-72KB9YQR7B}

catalyst=NO
device=NO
case $destination in
  *"Mac Catalyst"*) platform=iOS; app=CatalystClient; catalyst=YES ;;
  *"iOS Simulator"*) platform=iOS; app=MobileClient ;;
  # A physical iPhone or iPad: needs RST_PUBLIC_HOST=<this Mac's LAN IP>
  # so the device reaches swifttyd and the SSH relay over the network.
  *"platform=iOS,"*) platform=iOS; app=MobileClient; device=YES ;;
  *) echo "unsupported destination: $destination" >&2; exit 2 ;;
esac

env_file=$("$repository_root/Scripts/real-ssh-env.sh" start)
workspace=$(dirname "$env_file")
# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
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
# The fixture generates this private environment file at runtime.
# shellcheck source=/dev/null
. "$env_file"
# A file for the SFTP browser to list.
container exec "$(cat "$workspace/container.name")" \
  sh -c 'echo note > /home/rst/files/ui-note.txt && chown rst:rst /home/rst/files/ui-note.txt'

if [ $device = YES ] && [ -z "${RST_PUBLIC_HOST:-}" ]; then
  echo "physical devices need RST_PUBLIC_HOST=<this Mac's LAN address>" >&2
  exit 2
fi
if [ $catalyst = YES ] || [ $device = YES ]; then
  signing="CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: $team
        CODE_SIGN_IDENTITY: Apple Development"
else
  signing="CODE_SIGN_IDENTITY: \"-\""
fi

case $app in
  MobileClient)
    sources="[{ path: \"$apps/MobileClient\" }]"
    deps="- { package: Swiftty, product: RoamingApp }
      - { package: Swiftty, product: CompanionModel }"
    # RST_UI_BUNDLE_SUFFIX installs a separate app identity with fresh
    # permission state (e.g. a Local Network denial run) without touching
    # an installed client's data.
    app_settings="PRODUCT_BUNDLE_IDENTIFIER: dev.chr33s.swiftty${RST_UI_BUNDLE_SUFFIX:-}
        INFOPLIST_KEY_NSLocalNetworkUsageDescription: Find and connect to your Mac to access terminal workspaces on your local network.
        INFOPLIST_KEY_NSCameraUsageDescription: Scan the connection code displayed by your Mac.
        INFOPLIST_FILE: $apps/Config/AttentionLinks.plist
        TARGETED_DEVICE_FAMILY: \"1,2\"
        SUPPORTS_MACCATALYST: NO
        INFOPLIST_KEY_UILaunchScreen_Generation: YES" ;;
  CatalystClient)
    sources="[{ path: \"$apps/CatalystClient\", excludes: [\"*.entitlements\"] }]"
    deps="- { package: Swiftty, product: RoamingApp }"
    app_settings="PRODUCT_BUNDLE_IDENTIFIER: dev.chr33s.swiftty
        SUPPORTS_MACCATALYST: YES
        DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO
        TARGETED_DEVICE_FAMILY: \"2,6\"
        CODE_SIGN_ENTITLEMENTS: $apps/CatalystClient/CatalystClient.entitlements
        INFOPLIST_KEY_UILaunchScreen_Generation: YES" ;;
esac

project="$workspace/project"
mkdir -p "$project"
cat >"$project/project.yml" <<YML
name: RoamingUITests
options:
  deploymentTarget: { iOS: "27.0", macOS: "27.0" }
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    GENERATE_INFOPLIST_FILE: YES
    MARKETING_VERSION: "0.1"
    CURRENT_PROJECT_VERSION: "1"
packages:
  Swiftty: { path: "$repository_root" }
targets:
  $app:
    type: application
    platform: $platform
    sources: $sources
    dependencies:
      $deps
    settings:
      base:
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_CFBundleDisplayName: Swiftty
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO
        SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: NO
        $app_settings
        $signing
  AppUITests:
    type: bundle.ui-testing
    platform: $platform
    sources: [{ path: "$repository_root/Tests/AppUITests" }]
    dependencies: [{ target: $app }]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.swiftty.roaming.uitests
        TEST_TARGET_NAME: $app
        SUPPORTS_MACCATALYST: $catalyst
        DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO
        TARGETED_DEVICE_FAMILY: "$( [ $catalyst = YES ] && echo 2,6 || echo 1,2 )"
        $signing
schemes:
  RoamingUITests:
    build: { targets: { $app: all, AppUITests: [test] } }
    test: { targets: [AppUITests] }
YML
(cd "$project" && xcodegen generate --quiet --spec project.yml)

# Optional Nearby Macs fixture: RST_UI_ADVERTISE=<instance name> registers
# _swiftty._tcp for the relayed SSH port with the system DNS-SD service,
# as the Mac's Connect a Device panel does, for the run's duration.
advertise_pid=""
if [ -n "${RST_UI_ADVERTISE:-}" ]; then
  dns-sd -R "$RST_UI_ADVERTISE" _swiftty._tcp local "$RST_REAL_SSH_PORT" \
    txtvers=1 product=swiftty >"$workspace/advertise.log" 2>&1 &
  advertise_pid=$!
fi

echo "Testing $app on $destination (result bundle: $workspace/result.xcresult)"
status=0
TEST_RUNNER_RST_UI_SCAN=${RST_UI_SCAN:-} \
TEST_RUNNER_RST_UI_NEARBY=${RST_UI_ADVERTISE:-} \
TEST_RUNNER_RST_UI_LOCAL_NETWORK=${RST_UI_LOCAL_NETWORK:-allow} \
TEST_RUNNER_RST_UI_HOST=$RST_REAL_SSH_HOST \
TEST_RUNNER_RST_UI_PORT=$RST_REAL_SSH_PORT \
TEST_RUNNER_RST_UI_USER=$RST_REAL_SSH_USER \
TEST_RUNNER_RST_UI_PASSWORD=$RST_REAL_SSH_PASSWORD \
TEST_RUNNER_RST_UI_FINGERPRINT=$RST_REAL_SSH_FINGERPRINT \
  xcodebuild -project "$project/RoamingUITests.xcodeproj" -scheme RoamingUITests \
  -destination "$destination" -derivedDataPath "$workspace/build" \
  -resultBundlePath "$workspace/result.xcresult" -collect-test-diagnostics never \
  "$@" test >"$workspace/xcodebuild.log" 2>&1 || status=$?
[ -z "$advertise_pid" ] || kill "$advertise_pid" 2>/dev/null || true
grep -E "Test Case|error:|XCTAssert|failed|TEST (SUCCEEDED|FAILED)|Signing Identity" \
  "$workspace/xcodebuild.log" | grep -Ev "^ *[0-9]+ \|" | uniq | tail -60
[ $status -eq 0 ] || echo "xcodebuild failed ($status); log: $workspace/xcodebuild.log" >&2
exit $status
