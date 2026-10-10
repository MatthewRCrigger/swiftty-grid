#!/bin/sh
# Prints the Universal Link domains named by SWIFTTY_LINK_DOMAINS, one
# per line, lowercased and deduplicated (spec.inbox.md §4.4). Domains are
# separated by commas and/or whitespace. Nothing is printed when the
# variable is unset or empty, and an invalid hostname exits 64.
#
# usage: SWIFTTY_LINK_DOMAINS=links.example.com,go.example.com \
#          Scripts/link-domains.sh [--entitlements]
#   --entitlements  print "applinks:<domain>" instead, with
#                   "?mode=developer" appended when SWIFTTY_LINK_MODE is
#                   "developer" (alternate mode: the device fetches the
#                   association file directly instead of from Apple's CDN;
#                   development-signed builds only).
#
# A hostname here must also pass AttentionLinkConfiguration's check
# (letters, digits, dots and hyphens; at most 253 bytes), so a domain
# the app would ignore is never signed into an entitlement.
set -eu

prefix=""
suffix=""
case "${1:-}" in
  "") ;;
  --entitlements)
    prefix="applinks:"
    case "${SWIFTTY_LINK_MODE:-}" in
      "") ;;
      developer) suffix="?mode=developer" ;;
      *) echo "SWIFTTY_LINK_MODE must be empty or \"developer\"" >&2; exit 64 ;;
    esac
    ;;
  *) echo "usage: link-domains.sh [--entitlements]" >&2; exit 64 ;;
esac

printf '%s\n' "${SWIFTTY_LINK_DOMAINS:-}" | tr ',[:space:]' '\n\n' \
  | tr '[:upper:]' '[:lower:]' | awk -v prefix="$prefix" -v suffix="$suffix" '
    NF == 0 { next }
    {
      d = $0
      bad = length(d) > 253 || d !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/
      if (!bad) {
        n = split(d, labels, ".")
        for (i = 1; i <= n; i++) if (length(labels[i]) > 63) bad = 1
      }
      if (bad) {
        print "invalid link domain: " d > "/dev/stderr"
        failed = 1
        exit 64
      }
      if (!(d in seen)) { seen[d] = 1; print prefix d suffix }
    }
    END { if (failed) exit 64 }
  '
