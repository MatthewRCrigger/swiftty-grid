#!/bin/sh
# Runs the CompanionModel tests inside a watchOS simulator runtime and
# launches the WatchCompanion app there.
#   Scripts/test-companion-watch.sh <watch-simulator-udid>
set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 <watch-simulator-udid>" >&2; exit 2; }
udid=$1
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d /tmp/rstw.XXXXXX)
echo "Workspace: $workspace"
cat >"$workspace/project.yml" <<YML
name: CompanionWatch
options:
  deploymentTarget: { watchOS: "27.0" }
settings:
  base:
    SWIFT_VERSION: "6.0"
    GENERATE_INFOPLIST_FILE: YES
    CODE_SIGNING_ALLOWED: NO
packages:
  Swiftty: { path: "$repository_root" }
targets:
  CompanionHost:
    type: application
    platform: watchOS
    sources: [{ path: "$repository_root/Apps/WatchCompanion" }]
    dependencies:
      - { package: Swiftty, product: CompanionModel }
      - { package: Swiftty, product: MuxNavigation }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.swiftty.roaming.companion-host
        INFOPLIST_KEY_WKApplication: YES
        INFOPLIST_KEY_WKWatchOnly: YES
  CompanionTests:
    type: bundle.unit-test
    platform: watchOS
    sources:
      - { path: "$repository_root/Tests/ProtocolTests/CompanionCodecTests.swift" }
      - { path: "$repository_root/Tests/ProtocolTests/CompanionBridgeTests.swift" }
    dependencies:
      - { target: CompanionHost }
      - { package: Swiftty, product: CompanionModel }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.swiftty.roaming.companion-host.tests
        TEST_HOST: \$(BUILT_PRODUCTS_DIR)/CompanionHost.app/CompanionHost
        BUNDLE_LOADER: \$(TEST_HOST)
schemes:
  CompanionWatch:
    build: { targets: { CompanionHost: all, CompanionTests: [test] } }
    test: { targets: [CompanionTests] }
YML
cd "$workspace"
xcodegen generate --spec project.yml >/dev/null
status=0
xcodebuild -scheme CompanionWatch -destination "platform=watchOS Simulator,id=$udid" \
  -derivedDataPath "$workspace/build" -collect-test-diagnostics never test \
  >"$workspace/xcodebuild.log" 2>&1 || status=$?
grep -E "passed after|failed after|Test run with|error:|TEST (SUCCEEDED|FAILED)" \
  "$workspace/xcodebuild.log" | tail -40 || true
exit "$status"
