#!/bin/sh
# Two-device CloudKit check for spec.ssh-identity.md SYN-01 (development
# environment). Run the writer on one signed device, then the reader with
# the same run ID on another device signed in to the same iCloud account:
#   Scripts/test-cloud-signed.sh <destination> <team-id> writer <run-id>
#   Scripts/test-cloud-signed.sh <destination> <team-id> reader <run-id>
# e.g. 'platform=macOS,variant=Mac Catalyst' or 'platform=iOS,id=<udid>'.
# Set ALLOW_PROVISIONING=1 to let Xcode register the App ID, the iCloud
# capability and SWIFTTY_CLOUDKIT_CONTAINER (default iCloud.dev.chr33s.swiftty)
# for the team. SWIFTTY_CLOUD_KEY_WAIT bounds the reader's wait, in seconds,
# for iCloud Keychain delivery (default 300). Not REL-01: that needs the
# production schema and TestFlight builds.
set -eu
[ "$#" -eq 4 ] || { echo "usage: $0 <destination> <team-id> writer|reader <run-id>" >&2; exit 2; }
destination=$1
team=$2
role=$3
run=$4
case $role in writer|reader) ;; *) echo "role must be writer or reader" >&2; exit 2 ;; esac
container=${SWIFTTY_CLOUDKIT_CONTAINER:-iCloud.dev.chr33s.swiftty}
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d /tmp/rstc.XXXXXX)
echo "Workspace: $workspace"
catalyst=NO
case $destination in
  *"Mac Catalyst"*) catalyst=YES ;;
  *iOS*) ;;
  *) echo "unsupported destination (iOS or Mac Catalyst)" >&2; exit 2 ;;
esac
bundle=dev.chr33s.swiftty.cloud-host
cat >"$workspace/Host.entitlements" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>keychain-access-groups</key>
  <array><string>\$(AppIdentifierPrefix)$bundle</string></array>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array><string>$container</string></array>
  <key>com.apple.developer.icloud-services</key>
  <array><string>CloudKit</string></array>
</dict></plist>
XML
cat >"$workspace/project.yml" <<YML
name: CloudRuntime
options:
  deploymentTarget: { iOS: "27.0" }
settings:
  base:
    SWIFT_VERSION: "6.0"
    GENERATE_INFOPLIST_FILE: YES
    CODE_SIGN_STYLE: Automatic
    DEVELOPMENT_TEAM: $team
    CODE_SIGN_IDENTITY: Apple Development
    SUPPORTS_MACCATALYST: $catalyst
    DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO
packages:
  Swiftty: { path: "$repository_root" }
targets:
  CloudHost:
    type: application
    platform: iOS
    sources: [{ path: "$repository_root/Tests/CloudRuntime/HostApp.swift" }]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $bundle
        CODE_SIGN_ENTITLEMENTS: $workspace/Host.entitlements
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
  CloudTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - { path: "$repository_root/Tests/CloudRuntime/CloudSyncRuntimeTests.swift" }
    dependencies:
      - { target: CloudHost }
      - { package: Swiftty, product: RoamingApp }
      - { package: Swiftty, product: SSHIdentity }
      - { package: Swiftty, product: SSHClient }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $bundle.tests
        TEST_HOST: \$(BUILT_PRODUCTS_DIR)/CloudHost.app/$( [ $catalyst = YES ] && echo Contents/MacOS/ )CloudHost
        BUNDLE_LOADER: \$(TEST_HOST)
schemes:
  CloudRuntime:
    build: { targets: { CloudHost: all, CloudTests: [test] } }
    test: { targets: [CloudTests] }
YML
cd "$workspace"
xcodegen generate --spec project.yml >/dev/null
status=0
TEST_RUNNER_SWIFTTY_CLOUD_ROLE=$role TEST_RUNNER_SWIFTTY_CLOUD_RUN=$run \
TEST_RUNNER_SWIFTTY_CLOUD_KEY_WAIT=${SWIFTTY_CLOUD_KEY_WAIT:-300} \
xcodebuild -scheme CloudRuntime -destination "$destination" \
  ${ALLOW_PROVISIONING:+-allowProvisioningUpdates} \
  -derivedDataPath "$workspace/build" -collect-test-diagnostics never test \
  >"$workspace/xcodebuild.log" 2>&1 || status=$?
grep -E "CLOUD |Test Case|error:|TEST (SUCCEEDED|FAILED)|XCTAssert|Signing Identity" \
  "$workspace/xcodebuild.log" || true
exit "$status"
