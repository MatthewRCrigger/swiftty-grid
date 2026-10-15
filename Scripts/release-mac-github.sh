#!/bin/sh
# Notarizes, staples and publishes a Developer ID-signed macOS app
# (Swiftty.app from Scripts/package-swiftmux.sh) as a GitHub release asset
# (zip plus SHA-256). .github/workflows/release-mac.yml runs it; it also
# runs locally.
#
# usage: Scripts/release-mac-github.sh <path/to/App.app>
#
# Environment:
#   GITHUB_TOKEN       token with contents:write on the repository.
#   GITHUB_REPOSITORY  owner/name; default parsed from the origin remote.
#   NOTARY_*           notarization credentials, see Scripts/notarize.sh;
#                      not needed when the app is already stapled.
#   Release naming:
#     RELEASE_TAG      release this existing tag as-is; otherwise a
#                      prerelease tagged mac-v<version>-<build> is
#                      created at RELEASE_COMMIT (default HEAD). An
#                      existing release for the tag, draft or published,
#                      receives the assets.
set -eu

app=${1:?usage: Scripts/release-mac-github.sh <App.app>}
[ -d "$app" ] || { echo "release-mac-github: no app at $app" >&2; exit 66; }
: "${GITHUB_TOKEN:?release-mac-github: GITHUB_TOKEN is required}"

repository_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-release.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

info="$app/Contents/Info.plist"
name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$info")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")

repository=${GITHUB_REPOSITORY:-$(git -C "$repository_root" remote get-url origin |
  sed -E 's#^(git@github\.com:|https://([^@/]*@)?github\.com/)##; s#\.git$##')}
case "$repository" in
  */*) ;;
  *) echo "release-mac-github: set GITHUB_REPOSITORY=owner/name" >&2; exit 64 ;;
esac

if [ -n "${RELEASE_TAG:-}" ]; then
  tag=$RELEASE_TAG
  prerelease=false
else
  tag="mac-v$version-$build"
  prerelease=true
fi
commit=${RELEASE_COMMIT:-$(git -C "$repository_root" rev-parse HEAD)}

# The app must be Developer ID-signed under the hardened runtime.
codesign --verify --strict --deep --verbose=1 "$app"
codesign -dv "$app" 2>&1 | grep -q '^Authority=Developer ID Application' || {
  echo "release-mac-github: $app is not signed with a Developer ID identity" >&2
  exit 65
}

# Notarize (a no-op for an app package-swiftmux.sh already stapled) ------
"$repository_root/Scripts/notarize.sh" "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

# Package ----------------------------------------------------------------
asset="$name-$version-$build-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$asset"
(cd "$work" && shasum -a 256 "$asset" >"$asset.sha256")

# Publish ----------------------------------------------------------------
headers="$work/headers"
(umask 077 && printf '%s\n' \
  "Authorization: Bearer $GITHUB_TOKEN" \
  "Accept: application/vnd.github+json" \
  "X-GitHub-Api-Version: 2022-11-28" >"$headers")
api="https://api.github.com/repos/$repository"

# github <method> <url> [curl args...]: the response body on stdout; fails
# on HTTP errors.
github() {
  method=$1
  url=$2
  shift 2
  curl --silent --show-error --fail-with-body --location \
    --header @"$headers" --request "$method" "$@" "$url"
}

json_field() {
  /usr/bin/python3 -I -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

# The release for the tag, if any. /releases/tags/{tag} never returns
# drafts, so search the listing (newest first), which includes them; any
# HTTP error stops the script instead of creating a duplicate.
release=""
page=1
while [ -z "$release" ]; do
  listing=$(github GET "$api/releases?per_page=100&page=$page")
  [ "$listing" != "[]" ] || break
  release=$(printf '%s' "$listing" | /usr/bin/python3 -I -c '
import json, sys
match = next((r for r in json.load(sys.stdin) if r["tag_name"] == sys.argv[1]), None)
print(json.dumps(match) if match else "")
' "$tag")
  page=$((page + 1))
done

if [ -n "$release" ]; then
  echo "release-mac-github: updating release $tag"
else
  body=$(/usr/bin/python3 -I - "$tag" "$commit" "$name $version ($build)" "$prerelease" <<'PY'
import json, sys
tag, commit, title, prerelease = sys.argv[1:]
print(json.dumps({
    "tag_name": tag,
    "target_commitish": commit,
    "name": title,
    "body": f"Developer ID-signed, notarized macOS build of {title} from {commit}.\n\n"
            "Unzip and move the app to /Applications.",
    "prerelease": prerelease == "true",
}))
PY
  )
  release=$(github POST "$api/releases" --header 'Content-Type: application/json' --data "$body")
  echo "release-mac-github: created release $tag"
fi
release_id=$(printf '%s' "$release" | json_field id)
html_url=$(printf '%s' "$release" | json_field html_url)

# Replace assets of the same name so a rerun of the same build succeeds.
existing=$(github GET "$api/releases/$release_id/assets?per_page=100")
for file in "$asset" "$asset.sha256"; do
  asset_id=$(printf '%s' "$existing" | /usr/bin/python3 -I -c '
import json, sys
print(next((a["id"] for a in json.load(sys.stdin) if a["name"] == sys.argv[1]), ""))
' "$file")
  if [ -n "$asset_id" ]; then
    github DELETE "$api/releases/assets/$asset_id" >/dev/null
  fi
  case "$file" in
    *.zip) type=application/zip ;;
    *) type=text/plain ;;
  esac
  github POST "https://uploads.github.com/repos/$repository/releases/$release_id/assets?name=$file" \
    --header "Content-Type: $type" --data-binary @"$work/$file" >/dev/null
  echo "release-mac-github: uploaded $file"
done
echo "$html_url"
