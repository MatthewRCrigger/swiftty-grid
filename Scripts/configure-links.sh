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
#   <Target>.entitlements  for MobileClient, MacClient, CatalystClient and
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
set -eu

repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
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

mkdir -p "$out"
# shellcheck disable=SC2086 # one word per validated domain
domains_json=$(json_array $domains)
# shellcheck disable=SC2086
applinks_json=$(json_array $applinks)

info="$out/AttentionLinks.plist"
cp "$repository_root/Apps/Config/AttentionLinks.plist" "$info.tmp"
plutil -replace SwifttyAssociatedDomains -json "$domains_json" "$info.tmp"
plutil -lint -s "$info.tmp"
mv "$info.tmp" "$info"

for target in MobileClient MacClient CatalystClient VisionClient; do
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
  plutil -lint -s "$file.tmp"
  mv "$file.tmp" "$file"
done

if [ -n "$domains" ]; then
  echo "configure-links: Universal Links for $(echo $domains)" >&2
else
  echo "configure-links: SWIFTTY_LINK_DOMAINS unset; swiftty:// links only" >&2
fi
