#!/bin/sh
# Tells Xcode to build Swift packages with the arm64e slice, so the app
# targets' pointer authentication (ENABLE_ENHANCED_SECURITY, see
# spec.roaming.md §2.5) also covers the package code they link: all
# shared app logic lives in the local Swiftty package. Xcode reads this from
# the project's embedded workspace settings, which XcodeGen does not write,
# so Apps/project.yml runs this as its postGenCommand after every generation.
#
# usage: Scripts/configure-arm64e-packages.sh [path/to/Project.xcodeproj]
#
# Xcode 27 reads only iOSPackagesShouldBuildARM64e (verified: no other
# *PackagesShouldBuildARM64e key exists in its frameworks). It covers the
# iOS, visionOS and watchOS device builds; Mac Catalyst and tvOS packages
# stay arm64, so those targets set ENABLE_POINTER_AUTHENTICATION = NO in
# Apps/project.yml.
set -eu

project=${1:-Swiftty.xcodeproj}
if [ ! -d "$project" ]; then
  # xcodegen --project elsewhere: nothing generated beside the spec.
  echo "configure-arm64e-packages: $project not found; skipped" >&2
  exit 0
fi

dir="$project/project.xcworkspace/xcshareddata"
settings="$dir/WorkspaceSettings.xcsettings"
mkdir -p "$dir"
[ -f "$settings" ] || plutil -create xml1 "$settings"
plutil -replace iOSPackagesShouldBuildARM64e -bool YES "$settings"
plutil -lint -s "$settings"
