#!/bin/sh
# Notarizes Developer ID-signed code: an .app is submitted, stapled and
# assessed by Gatekeeper (skipped when it already has a stapled ticket); a
# bare executable is only submitted, since it cannot be stapled and
# Gatekeeper fetches its ticket online. Used by Scripts/package-swiftmux.sh,
# Scripts/install.sh and Scripts/release-mac-github.sh.
#
# usage: Scripts/notarize.sh <path/to/App.app | executable>
#
# Credentials, either:
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY
#                    App Store Connect API key (Developer role or higher);
#                    NOTARY_KEY is the .p8 file's contents.
#   NOTARY_PROFILE   a notarytool keychain profile
#                    (xcrun notarytool store-credentials).
set -eu

target=${1:?usage: Scripts/notarize.sh <App.app | executable>}
[ -e "$target" ] || { echo "notarize: no such file: $target" >&2; exit 66; }

if [ -d "$target" ] && xcrun stapler validate "$target" >/dev/null 2>&1; then
  echo "notarize: $target is already stapled"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-notarize.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
submission="$work/submission.zip"
if [ -d "$target" ]; then
  ditto -c -k --keepParent "$target" "$submission"
else
  ditto -c -k "$target" "$submission"
fi

if [ -n "${NOTARY_KEY_ID:-}" ]; then
  : "${NOTARY_ISSUER_ID:?notarize: NOTARY_ISSUER_ID is required with NOTARY_KEY_ID}"
  : "${NOTARY_KEY:?notarize: NOTARY_KEY is required with NOTARY_KEY_ID}"
  key="$work/AuthKey_$NOTARY_KEY_ID.p8"
  (umask 077 && printf '%s\n' "$NOTARY_KEY" >"$key")
  xcrun notarytool submit "$submission" --wait \
    --key "$key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$submission" --wait --keychain-profile "$NOTARY_PROFILE"
else
  echo "notarize: set NOTARY_KEY_ID/NOTARY_ISSUER_ID/NOTARY_KEY or NOTARY_PROFILE" >&2
  exit 64
fi

if [ -d "$target" ]; then
  xcrun stapler staple "$target"
  spctl --assess --type execute --verbose=2 "$target"
fi
