#!/bin/sh
# Runs the Keychain store against the real data-protection keychain from a
# signed, app-hosted test with a keychain-access-group entitlement.
#   Scripts/test-keychain-signed.sh <destination> [team-id]
# e.g. 'platform=iOS Simulator,id=<udid>' (no team needed),
#      'platform=macOS,variant=Mac Catalyst' <team-id>, or
#      'platform=macOS' <team-id> (Apple Development signing; Xcode must be
#      signed in to the team for automatic provisioning).
set -eu
[ "$#" -ge 1 ] || { echo "usage: $0 <destination> [team-id]" >&2; exit 2; }
destination=$1
team=${2:-}
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d /tmp/rstk.XXXXXX)
echo "Workspace: $workspace"
catalyst=NO
case $destination in
  *"Mac Catalyst"*) platform=iOS; catalyst=YES ;;
  *iOS*) platform=iOS ;;
  *tvOS*) platform=tvOS ;;
  *visionOS*) platform=visionOS ;;
  *macOS*) platform=macOS ;;
  *) echo "unsupported destination" >&2; exit 2 ;;
esac
bundle=dev.swiftty.roaming.keychain-host
cat >"$workspace/Host.entitlements" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>keychain-access-groups</key>
  <array><string>\$(AppIdentifierPrefix)$bundle</string></array>
</dict></plist>
XML
if [ -n "$team" ]; then
  signing="CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: $team
        CODE_SIGN_IDENTITY: Apple Development"
  extra=${ALLOW_PROVISIONING:+-allowProvisioningUpdates}
else
  signing="CODE_SIGN_IDENTITY: \"-\""
  extra=
fi
cat >"$workspace/project.yml" <<YML
name: KeychainRuntime
options:
  deploymentTarget: { iOS: "27.0", macOS: "27.0", tvOS: "27.0", visionOS: "27.0" }
settings:
  base:
    SWIFT_VERSION: "6.0"
    GENERATE_INFOPLIST_FILE: YES
packages:
  Swiftty: { path: "$repository_root" }
targets:
  KeychainHost:
    type: application
    platform: $platform
    sources: [{ path: "$repository_root/Tests/KeychainRuntime/HostApp.swift" }]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $bundle
        SUPPORTS_MACCATALYST: $catalyst
        CODE_SIGN_ENTITLEMENTS: $workspace/Host.entitlements
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        $signing
  KeychainTests:
    type: bundle.unit-test
    platform: $platform
    sources: [{ path: "$repository_root/Tests/KeychainRuntime/KeychainRuntimeTests.swift" }]
    dependencies:
      - { target: KeychainHost }
      - { package: Swiftty, product: SSHClient }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $bundle.tests
        SUPPORTS_MACCATALYST: $catalyst
        TEST_HOST: \$(BUILT_PRODUCTS_DIR)/KeychainHost.app/$( [ $platform = macOS ] || [ $catalyst = YES ] && echo Contents/MacOS/ )KeychainHost
        BUNDLE_LOADER: \$(TEST_HOST)
        $signing
schemes:
  KeychainRuntime:
    build: { targets: { KeychainHost: all, KeychainTests: [test] } }
    test: { targets: [KeychainTests] }
YML
cd "$workspace"
xcodegen generate --spec project.yml >/dev/null
xcodebuild -scheme KeychainRuntime -destination "$destination" $extra \
  -derivedDataPath "$workspace/build" -collect-test-diagnostics never test \
  2>&1 | tee "$workspace/xcodebuild.log" | grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)|Signing Identity"
