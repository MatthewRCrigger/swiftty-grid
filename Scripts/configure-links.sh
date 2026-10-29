#!/bin/sh
# Writes the per-target Universal Link configuration for the roaming
# clients (spec.inbox.md §4.4) into Apps/Config/Generated (gitignored).
# Apps/project.yml runs this as its XcodeGen preGenCommand, so generating
# the project always reflects SWIFTTY_LINK_DOMAINS at that moment.
#
# usage: SWIFTTY_LINK_DOMAINS=links.example.com[,more...] \
#          Scripts/configure-links.sh [output-dir]
#
# Writes:
#   AttentionLinks.plist   Apps/Config/AttentionLinks.plist with
#                          SwifttyAssociatedDomains set to the domains.
#   <Target>.entitlements  for MobileClient, CatalystClient and
#                          VisionClient: the target's own entitlements
#                          (Apps/<Target>/<Target>.entitlements, or an
#                          empty dictionary) plus, only when domains are
#                          given, com.apple.developer.associated-domains
#                          with applinks:<domain> each (the key shown in
#                          Apps/Config/AssociatedDomains.entitlements.template).
#
# With SWIFTTY_LINK_DOMAINS unset or empty, no entitlement is added and
# the domain list is empty: only swiftty:// links work. TVClient keeps
# the committed AttentionLinks.plist and has no associated domains:
# tvOS has no browser to hand https links to the app.
#
# SSH identities (spec.ssh-identity.md §10): every generated plist and
# entitlement file also gets the Keychain access group
# $(AppIdentifierPrefix)dev.chr33s.swiftty (SwifttyKeychainAccessGroup and
# keychain-access-groups, from one value). CloudKit metadata sync is
# opt-in: only when SWIFTTY_CLOUDKIT_CONTAINER names a provisioned
# container (for example iCloud.dev.chr33s.swiftty) are the iCloud
# entitlements and SwifttyCloudKitContainer written. Unset, the app has
# no CloudKit capability and hides sync. TVClient gets neither.
set -eu
# Split validated records into words without expanding the literal ? in
# developer-mode entitlements against filenames in the caller's directory.
set -f

repository_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
out=${1:-"$repository_root/Apps/Config/Generated"}
domains=$("$repository_root/Scripts/link-domains.sh")
applinks=$("$repository_root/Scripts/link-domains.sh" --entitlements)

# json_array <word>...: a JSON array of strings (inputs are validated
# hostnames, so no escaping is needed).
json_array() {
  printf '['
  separator=""
  for word in "$@"; do
    printf '%s"%s"' "$separator" "$word"
    separator=","
  done
  printf ']'
}

access_group='$(AppIdentifierPrefix)dev.chr33s.swiftty'
container=${SWIFTTY_CLOUDKIT_CONTAINER:-}
if [ -n "$container" ]; then
  case $container in
    iCloud.dev.chr33s.shell)
      echo "configure-links: refusing Shell's CloudKit container" >&2
      exit 2 ;;
    iCloud.*) ;;
    *)
      echo "configure-links: SWIFTTY_CLOUDKIT_CONTAINER must start with iCloud." >&2
      exit 2 ;;
  esac
  if printf '%s' "$container" | LC_ALL=C grep -q '[^A-Za-z0-9.-]'; then
    echo "configure-links: invalid SWIFTTY_CLOUDKIT_CONTAINER" >&2
    exit 2
  fi
fi

mkdir -p "$out"
# shellcheck disable=SC2086 # one word per validated domain
domains_json=$(json_array $domains)
# shellcheck disable=SC2086
applinks_json=$(json_array $applinks)

info="$out/AttentionLinks.plist"
cp "$repository_root/Apps/Config/AttentionLinks.plist" "$info.tmp"
plutil -replace SwifttyAssociatedDomains -json "$domains_json" "$info.tmp"
plutil -replace SwifttyKeychainAccessGroup -string "$access_group" "$info.tmp"
if [ -n "$container" ]; then
  plutil -replace SwifttyCloudKitContainer -string "$container" "$info.tmp"
fi
plutil -lint -s "$info.tmp"
mv "$info.tmp" "$info"

for target in MobileClient CatalystClient VisionClient; do
  file="$out/$target.entitlements"
  base="$repository_root/Apps/$target/$target.entitlements"
  if [ -f "$base" ]; then
    plutil -convert xml1 -o "$file.tmp" "$base"
  else
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' '<dict/>' '</plist>' >"$file.tmp"
  fi
  if [ -n "$applinks" ]; then
    # Escaped dots: one key, not a key path.
    plutil -replace 'com\.apple\.developer\.associated-domains' \
      -json "$applinks_json" "$file.tmp"
  fi
  plutil -replace keychain-access-groups -json "[\"$access_group\"]" "$file.tmp"
  if [ -n "$container" ]; then
    plutil -replace 'com\.apple\.developer\.icloud-container-identifiers' \
      -json "[\"$container\"]" "$file.tmp"
    plutil -replace 'com\.apple\.developer\.icloud-services' \
      -json '["CloudKit"]' "$file.tmp"
  fi
  plutil -lint -s "$file.tmp"
  mv "$file.tmp" "$file"
done

if [ -n "$container" ]; then
  echo "configure-links: CloudKit container $container" >&2
else
  echo "configure-links: SWIFTTY_CLOUDKIT_CONTAINER unset; no iCloud sync" >&2
fi
if [ -n "$domains" ]; then
  echo "configure-links: Universal Links for $domains" >&2
else
  echo "configure-links: SWIFTTY_LINK_DOMAINS unset; swiftty:// links only" >&2
fi
