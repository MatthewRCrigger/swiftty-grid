#!/bin/sh
# Writes the apple-app-site-association file that each Universal Link
# domain in SWIFTTY_LINK_DOMAINS must serve (spec.inbox.md §4.4), then
# validates it.
#
# usage: Scripts/make-aasa.sh [-o path] <team-id> <bundle-id>...
#        Scripts/make-aasa.sh --check <path> [<team-id> <bundle-id>...]
#
#   -o path    write to path instead of stdout.
#   team-id    the 10-character Apple Developer Team ID.
#   bundle-id  each app accepting the links, e.g. com.chr33s.swiftty
#              (native macOS) and dev.chr33s.swiftty (the roaming
#              clients' shared universal-purchase ID).
#   --check    validate an existing file (JSON syntax with python3 and
#              plutil, the applinks structure, and, when given, that it
#              names exactly those app IDs).
#
# The file claims only /a/<locator> paths: a non-empty single path
# component, no query and no fragment. The apps still validate every link
# strictly (AttentionLink); this file only decides which URLs the system
# hands to the app instead of the browser. Serve it over HTTPS with no
# redirects at https://<domain>/.well-known/apple-app-site-association,
# as application/json.
set -eu

usage() {
  sed -n '6,7p' "$0" | sed 's/^# *//' >&2
  exit 64
}

# check <file> [team bundle...]: syntax with two parsers, then structure.
check() {
  file=$1
  shift
  /usr/bin/python3 -I -m json.tool "$file" >/dev/null
  plutil -convert xml1 -o /dev/null "$file" || { echo "plutil rejected $file" >&2; exit 65; }
  /usr/bin/python3 -I - "$file" "$@" <<'PY'
import json, re, sys
path, args = sys.argv[1], sys.argv[2:]
doc = json.load(open(path))
def fail(why):
    sys.exit(f"{path}: {why}")
if not isinstance(doc, dict) or set(doc) != {"applinks"}:
    fail("unexpected top-level structure (only applinks is used)")
applinks = doc["applinks"]
if not isinstance(applinks, dict) or set(applinks) - {"details", "apps"}:
    fail("applinks must hold details without matching defaults or substitutions")
if "apps" in applinks and applinks["apps"] != []:
    fail("legacy applinks.apps must be empty")
details = applinks.get("details")
if not isinstance(details, list) or len(details) != 1:
    fail("applinks.details must hold one entry")
entry = details[0]
if not isinstance(entry, dict) or set(entry) != {"appIDs", "components"}:
    fail("details entry must hold appIDs and components without matching defaults")
ids = entry.get("appIDs")
if not isinstance(ids, list) or not ids or not all(
    isinstance(i, str) and re.fullmatch(r"[A-Z0-9]{10}\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", i)
    for i in ids
):
    fail("appIDs must list <team>.<bundle-id> strings")
if args:
    expected = sorted(f"{args[0]}.{b}" for b in args[1:])
    if sorted(ids) != expected:
        fail(f"appIDs {sorted(ids)} != {expected}")
components = entry.get("components")
if not isinstance(components, list):
    fail("components must be a list")
rules = []
for component in components:
    if not isinstance(component, dict) or set(component) - {"/", "?", "#", "exclude", "comment"}:
        fail("component must be a supported matching dictionary")
    if "exclude" in component and not isinstance(component["exclude"], bool):
        fail("component exclude must be a Boolean")
    for key in ["/", "#", "comment"]:
        if key in component and not isinstance(component[key], str):
            fail(f"component {key} must be a string")
    if "?" in component:
        query = component["?"]
        if not isinstance(query, str) and not (
            isinstance(query, dict) and all(isinstance(v, str) for v in query.values())
        ):
            fail("component query must be a string or string-valued dictionary")
    rules.append({k: v for k, v in component.items() if k != "comment"})
includes = [(index, rule) for index, rule in enumerate(rules) if not rule.get("exclude", False)]
if len(includes) != 1 or {k: v for k, v in includes[0][1].items() if k != "exclude"} != {"/": "/a/?*"}:
    fail("the only inclusion must be /a/?* without query or fragment conditions")
# Apple evaluates components in order and the first match wins. Each
# unconditional required exclusion must precede the overlapping inclusion.
before = rules[:includes[0][0]]
for need in [
    {"/": "/a/*/*", "exclude": True},
    {"/": "/a/*", "?": "?*", "exclude": True},
    {"/": "/a/*", "#": "?*", "exclude": True},
]:
    if need not in before:
        fail(f"required exclusion {need} must appear before the inclusion")
PY
}

if [ "${1:-}" = "--check" ]; then
  [ $# -ge 2 ] || usage
  shift
  check "$@"
  echo "ok: $1" >&2
  exit 0
fi

output=""
if [ "${1:-}" = "-o" ]; then
  [ $# -ge 2 ] || usage
  output=$2
  shift 2
fi
[ $# -ge 2 ] || usage
team=$1
shift
case "$team" in
  [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
  *) echo "invalid team ID (10 uppercase letters or digits): $team" >&2; exit 64 ;;
esac
ids=""
for bundle in "$@"; do
  case "$bundle" in
    "" | .* | *. | *..* | *[!A-Za-z0-9.-]*)
      echo "invalid bundle ID: $bundle" >&2
      exit 64
      ;;
  esac
  ids="$ids${ids:+, }\"$team.$bundle\""
done

tmp=$(mktemp "${TMPDIR:-/tmp}/aasa.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<EOF
{
  "applinks": {
    "details": [
      {
        "appIDs": [$ids],
        "components": [
          { "/": "/a/*/*", "exclude": true, "comment": "one locator component only" },
          { "/": "/a/*", "?": "?*", "exclude": true, "comment": "no query" },
          { "/": "/a/*", "#": "?*", "exclude": true, "comment": "no fragment" },
          { "/": "/a/?*", "comment": "Swiftty attention locator" }
        ]
      }
    ]
  }
}
EOF
check "$tmp" "$team" "$@"
if [ -n "$output" ]; then
  cp "$tmp" "$output"
else
  cat "$tmp"
fi
