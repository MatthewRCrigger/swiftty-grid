#!/bin/sh
# Builds every roaming-SSH product for its generic destination and records
# A0 build evidence (spec.roaming.md §2.4, §13 A0).
#
# usage: Scripts/build-platforms.sh [evidence-file]
#
# - Generates Apps/project.yml with XcodeGen. The project must sit beside
#   the spec because Xcode resolves the local package path (`..`) and the
#   entitlements paths relative to the project directory, so it is written
#   to Apps/RoamingClients.xcodeproj, which is gitignored (*.xcodeproj) and
#   never committed. Derived data, logs and evidence go to a temp dir.
# - XcodeGen's preGenCommand runs Scripts/configure-links.sh, which writes
#   Apps/Config/Generated/ from SWIFTTY_LINK_DOMAINS (spec.inbox.md §4.4).
#   The evidence records the associated domains each target was given:
#   none when the variable is unset.
# - Builds each app with CODE_SIGNING_ALLOWED=NO for: iOS Simulator,
#   macOS, Mac Catalyst, visionOS Simulator, tvOS Simulator and watchOS
#   Simulator.
# - Builds the swifttyd helper with SwiftPM.
# - Writes an evidence file with toolchain/SDK versions, destinations and
#   pass/fail per target. Exit status is non-zero if any build failed.
#
# This is BUILD evidence only. Simulator/device runtime validation, physical
# hardware, entitlements under real signing, and paired-watch tests are
# separate release gates and are not exercised here.
set -u

for tool in xcodegen xcodebuild swift; do
  command -v "$tool" >/dev/null || { echo "required tool: $tool" >&2; exit 1; }
done

repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-platforms.XXXXXX")
evidence=${1:-"$work/build-evidence.txt"}
logs="$work/logs"
derived="$work/DerivedData"
mkdir -p "$logs"

echo "Workspace: $work"
xcodegen generate --quiet \
  --spec "$repository_root/Apps/project.yml" \
  --project "$repository_root/Apps" || { echo "xcodegen failed" >&2; exit 1; }
project="$repository_root/Apps/RoamingClients.xcodeproj"

# Resolve package dependencies once so per-target builds share the result.
xcodebuild -resolvePackageDependencies -project "$project" \
  -scheme MobileClient -derivedDataPath "$derived" \
  >"$logs/resolve.log" 2>&1 || echo "package resolution failed; see $logs/resolve.log" >&2

{
  echo "# Roaming SSH platform build evidence (spec.roaming.md A0)"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Host: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
  echo "Revision: $(git -C "$repository_root" rev-parse HEAD 2>/dev/null || echo unknown)$(git -C "$repository_root" diff --quiet 2>/dev/null || echo ' (with uncommitted changes)')"
  echo
  echo "## swift --version (SwiftPM swifttyd build)"
  swift --version 2>&1 | grep -v libSwiftScan
  echo
  echo "## xcodebuild -version (app builds)"
  xcodebuild -version
  echo
  echo "## Xcode toolchain swift"
  xcrun swift --version 2>&1 | grep -v libSwiftScan
  echo
  echo "## SDKs"
  for sdk in iphoneos iphonesimulator macosx appletvos appletvsimulator \
    xros xrsimulator watchos watchsimulator; do
    printf '%-18s %s (%s)\n' "$sdk" \
      "$(xcrun --sdk "$sdk" --show-sdk-version 2>/dev/null || echo missing)" \
      "$(xcrun --sdk "$sdk" --show-sdk-build-version 2>/dev/null || echo -)"
  done
  echo
  echo "## Resolved package dependencies"
  resolved="$repository_root/Package.resolved"
  if [ -f "$resolved" ]; then
    /usr/bin/python3 - "$resolved" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1])).get("pins", [])
for pin in pins:
    state = pin.get("state", {})
    print(f'{pin.get("identity")}: {state.get("version") or state.get("branch")} @ {state.get("revision")}')
PY
  else
    echo "Package.resolved not present"
  fi
  echo
  echo "## Universal Links (SWIFTTY_LINK_DOMAINS=${SWIFTTY_LINK_DOMAINS:-})"
  for target in MobileClient MacClient CatalystClient VisionClient; do
    entitlements="$repository_root/Apps/Config/Generated/$target.entitlements"
    printf '%-16s %s\n' "$target" "$(/usr/bin/python3 -I - "$entitlements" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    domains = plistlib.load(f).get("com.apple.developer.associated-domains", [])
print(" ".join(domains) or "no associated domains")
PY
)"
  done
  printf '%-16s %s\n' "TVClient" "no associated domains (swiftty:// only)"
  echo
  echo "## Builds (deployment target 27.0 everywhere; CODE_SIGNING_ALLOWED=NO)"
  echo
  printf '%-16s %-48s %s\n' "Target" "Destination" "Result"
} >"$evidence"

failures=0

# build <scheme> <destination>
build() {
  scheme=$1
  destination=$2
  log="$logs/$scheme.log"
  echo "Building $scheme for $destination"
  if xcodebuild build -project "$project" -scheme "$scheme" \
    -destination "$destination" -derivedDataPath "$derived" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    >"$log" 2>&1; then
    result=PASS
  else
    result="FAIL (log: $log)"
    failures=$((failures + 1))
    grep -E "error:" "$log" | sort -u | head -20 >&2
  fi
  warnings=$(grep -E "^/[^:]*/Apps/[^:]*\.swift:[0-9]+:[0-9]+: warning:" "$log" \
    | sort -u | wc -l | tr -d ' ')
  printf '%-16s %-48s %s; app-source warnings: %s\n' \
    "$scheme" "$destination" "$result" "$warnings" >>"$evidence"
}

build MobileClient "generic/platform=iOS Simulator"
build MacClient "generic/platform=macOS"
build CatalystClient "generic/platform=macOS,variant=Mac Catalyst"
build VisionClient "generic/platform=visionOS Simulator"
build TVClient "generic/platform=tvOS Simulator"
build WatchCompanion "generic/platform=watchOS Simulator"

# The watch target must link only CompanionModel and MuxNavigation (spec §2.2).
watch_log="$logs/WatchCompanion.log"
if grep -qE "SwifttyCore|SSHClient|NIOSSH|NIOCore|TerminalSurface|AppleTransport" "$watch_log"; then
  echo "WatchCompanion dependency check: FAIL (direct-client modules built for watchOS)" >>"$evidence"
  failures=$((failures + 1))
else
  echo "WatchCompanion dependency check: PASS (only CompanionModel and MuxNavigation built for watchOS)" >>"$evidence"
fi

echo "Building swifttyd with SwiftPM"
if (cd "$repository_root" && swift build --product swifttyd) >"$logs/swifttyd.log" 2>&1; then
  result=PASS
else
  result="FAIL (log: $logs/swifttyd.log)"
  failures=$((failures + 1))
fi
printf '%-16s %-48s %s\n' "swifttyd" "SwiftPM, native macOS host" "$result" >>"$evidence"

{
  echo
  echo "## Scope of this evidence"
  echo
  echo "Build-only: each product compiled and linked for its generic destination."
  echo "NOT covered: simulator or device launch, runtime behaviour, physical"
  echo "iPhone/iPad/Apple Vision/Apple TV/paired Apple Watch runs, signed"
  echo "entitlements, the 27.x shipping-runtime matrix, SSH/RST/SFTP tests."
  echo "Those device/runtime gates (spec §2.4, A0) are validated separately."
} >>"$evidence"

cat "$evidence"
echo
echo "Evidence: $evidence"
[ "$failures" -eq 0 ]
