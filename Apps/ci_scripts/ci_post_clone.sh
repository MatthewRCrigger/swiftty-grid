#!/bin/sh
# Xcode Cloud: runs after the clone, before package resolution and the
# build/archive action. Xcode Cloud finds ci_scripts beside the project it
# builds (Apps/RoamingClients.xcodeproj), which is generated, not
# committed, so this generates it from Apps/project.yml.
#
# Workflow environment (Xcode Cloud > Workflow > Environment):
#   SWIFTTY_TEAM_ID       Apple Developer team ID for cloud-managed
#                         automatic signing (required).
#   SWIFTTY_LINK_DOMAINS  optional Universal Link domains; see
#                         Scripts/configure-links.sh.
#   SWIFTTY_CLOUDKIT_CONTAINER
#                         optional provisioned CloudKit container for
#                         opt-in metadata sync; see the same script.
set -eu

repository_root=${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)}

case "${SWIFTTY_TEAM_ID:-}" in
  '') echo "ci_post_clone: set SWIFTTY_TEAM_ID in the workflow environment" >&2; exit 64 ;;
  *[!A-Z0-9]*) echo "ci_post_clone: SWIFTTY_TEAM_ID must be a team ID such as ABCDE12345" >&2; exit 64 ;;
esac

if ! command -v xcodegen >/dev/null; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
fi

xcodegen generate --quiet \
  --spec "$repository_root/Apps/project.yml" \
  --project "$repository_root/Apps"

# Xcode Cloud disables automatic package resolution, so the generated
# workspace needs the committed pins (the project's only remote packages
# come from the local Swiftty package).
swiftpm="$repository_root/Apps/RoamingClients.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$swiftpm"
cp "$repository_root/Package.resolved" "$swiftpm/Package.resolved"
