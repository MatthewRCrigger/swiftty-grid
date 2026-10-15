#!/bin/sh
# Builds, signs and installs Swiftty.app, registers its bundled SwiftMux
# LaunchAgent (SMAppService) and, with --roaming, installs the swifttyd
# bootstrap helper and writes the roaming configuration (spec.inbox.md §1).
# Remote Login and firewall policy are reported, never changed.
#
# usage: Scripts/install.sh [options]
#   --identity ID      signing identity; default: match a running agent,
#                      else the first Developer ID identity or ad-hoc. See
#                      Scripts/package-swiftmux.sh for NOTARY_PROFILE etc.
#   --dest DIR         install directory (default /Applications)
#   --roaming          also set up remote clients:
#     --host NAME      advertised host (default `scutil --get LocalHostName`.local)
#     --bind ADDR      QUIC/UDP bind address (default 0.0.0.0)
#     --port N         UDP port (default 51222)
#   --replace-dev-agent  remove a `swmux agent install` LaunchAgent first;
#                      its running sessions end
#   --restart-agent    re-register a running agent whose signing team
#                      changed, or (ad-hoc builds) whose binary changed;
#                      its running sessions end
#   --team TEAM        team for the iOS/iPadOS app (default: the Mac build's
#                      signing team); see Scripts/install-ios.sh
#   --no-devices       skip installing the iOS/iPadOS app on iPhones and
#                      iPads connected by USB
#
# Safe to run inside Swiftty: the running app is replaced in place, not quit.
set -eu
cd "$(dirname "$0")/.."

identity=""
dest=/Applications
roaming=0
host=""
bind=0.0.0.0
port=51222
replace_dev=0
restart_agent=0
team=""
devices=1
while [ $# -gt 0 ]; do
  case "$1" in
    # --option=value is the same as --option value.
    --identity=* | --dest=* | --host=* | --bind=* | --port=* | --team=*)
      value=${1#*=}
      option=${1%%=*}
      shift
      set -- "$option" "$value" "$@"
      continue ;;
    --identity | --dest | --host | --bind | --port | --team)
      option=$1
      if [ $# -lt 2 ]; then
        echo "install.sh: $option requires a value" >&2; exit 64
      fi
      case "$2" in
        --* | -h) echo "install.sh: $option requires a value" >&2; exit 64 ;;
      esac
      case "$option" in
        --identity) identity=$2 ;;
        --dest) dest=$2 ;;
        --host) host=$2 ;;
        --bind) bind=$2 ;;
        --port) port=$2 ;;
        --team) team=$2 ;;
      esac
      shift 2 ;;
    --roaming) roaming=1; shift ;;
    --replace-dev-agent) replace_dev=1; shift ;;
    --restart-agent) restart_agent=1; shift ;;
    --no-devices) devices=0; shift ;;
    -h | --help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 64 ;;
  esac
done

case "$dest" in
  '' | -*) echo "install.sh: --dest must name a directory" >&2; exit 64 ;;
esac

# Validate before building, installing or changing a running agent. A
# canonical decimal port also keeps the generated JSON number unambiguous.
case "$port" in
  '' | *[!0-9]* | 0*)
    echo "install.sh: --port must be an integer from 1 to 65535" >&2; exit 64 ;;
esac
if [ ${#port} -gt 5 ] || [ "$port" -gt 65535 ]; then
  echo "install.sh: --port must be an integer from 1 to 65535" >&2; exit 64
fi

label=com.chr33s.swiftty.swiftmux
bundle_id=com.chr33s.swiftty
app="$dest/Swiftty.app"
helper=/usr/local/libexec/swifttyd
dev_plist="$HOME/Library/LaunchAgents/$label.plist"
roaming_dir="$HOME/Library/Application Support/SwiftMux/roaming"
roaming_config="$roaming_dir/config.json"
domain="gui/$(id -u)"

team_of() {
  codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | sed 's/^not set$//'
}
cdhash_of() {
  codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'
}
agent_info=$(launchctl print "$domain/$label" 2>/dev/null || true)
registered_team=$(printf '%s\n' "$agent_info" \
  | sed -n 's/.*"team-identifier" => "\(.*\)".*/\1/p' | head -n 1)

# By SHA-1, so duplicate certificates with one name stay unambiguous.
if [ -z "$identity" ]; then
  if [ "$restart_agent" -eq 0 ] \
    && printf '%s\n' "$agent_info" | grep -q 'state = running'; then
    if [ -z "$registered_team" ]; then
      identity=-
    else
      identity=$(security find-identity -v -p codesigning \
        | awk -v team="$registered_team" \
          '/"Developer ID Application/ && index($0, "(" team ")") { print $2; exit }')
      if [ -z "$identity" ]; then
        echo "install.sh: no Developer ID identity for the running agent's team '$registered_team'." >&2
        echo "  Use --identity with a matching identity, or --restart-agent (its running sessions end)." >&2
        exit 1
      fi
    fi
  else
    identity=$(security find-identity -v -p codesigning \
      | awk '/"Developer ID Application/ { print $2; exit }')
  fi
  [ -n "$identity" ] || identity=-
fi
echo "signing with ${identity}"

# The dev agent and the bundled one share a label and Mach service.
if [ -f "$dev_plist" ]; then
  if [ "$replace_dev" -eq 0 ]; then
    echo "install.sh: a development SwiftMux agent is installed ($dev_plist)." >&2
    echo "  Re-run with --replace-dev-agent (its running sessions end)." >&2
    exit 1
  fi
  launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -f -- "$dev_plist"
  echo "removed development agent $dev_plist"
fi

Scripts/package-swiftmux.sh "$identity" .build/package
built=.build/package/Swiftty.app
bin=$(swift build -c release --show-bin-path)

# launchd pins the registered agent to the signing team it had when
# registered (a launch constraint); a different team is killed at spawn
# with "Launch Constraint Violation" until the agent is re-registered. An
# ad-hoc build has no team and is pinned to its agent's cdhash instead,
# which changes with every build: launchd then refuses to spawn it
# (EX_CONFIG, "needs LWCR update") once the running agent exits.
agent_info=$(launchctl print "$domain/$label" 2>/dev/null || true)
registered_team=$(printf '%s\n' "$agent_info" \
  | sed -n 's/.*"team-identifier" => "\(.*\)".*/\1/p' | head -n 1)
new_team=$(team_of "$built/Contents/MacOS/swiftmux-agent")
installed_agent="$app/Contents/MacOS/swiftmux-agent"
reason=""
if [ -n "$agent_info" ]; then
  if [ "$registered_team" != "$new_team" ]; then
    reason="registered for team '${registered_team:-none}', the new build is '${new_team:-none}'"
  elif [ -z "$new_team" ] && { [ ! -f "$installed_agent" ] \
    || [ "$(cdhash_of "$installed_agent")" != "$(cdhash_of "$built/Contents/MacOS/swiftmux-agent")" ]; }; then
    reason="an ad-hoc build, pinned to the previous agent binary"
  fi
fi
reregister=0
if [ -n "$reason" ]; then
  if printf '%s\n' "$agent_info" | grep -q 'state = running' \
    && [ "$restart_agent" -eq 0 ]; then
    echo "install.sh: the running SwiftMux agent is $reason." >&2
    echo "  Re-run with --restart-agent (its running sessions end), or sign" >&2
    echo "  with a Developer ID identity (--identity) to keep it across builds." >&2
    exit 1
  fi
  reregister=1
fi

running=0
pgrep -xq swiftty && running=1

sudo_if_needed() {
  if [ -w "$1" ]; then shift; "$@"; else shift; sudo "$@"; fi
}
mkdir -p "$dest" 2>/dev/null || sudo mkdir -p "$dest"
sudo_if_needed "$dest" /usr/bin/python3 -I Scripts/install-app.py "$built" "$app" "$new_team"
echo "installed $app"

if [ "$reregister" -eq 1 ]; then
  echo "re-registering the SwiftMux agent ($reason)"
  "$app/Contents/MacOS/swiftty" --swiftmux-agent unregister >/dev/null || true
  launchctl bootout "$domain/$label" 2>/dev/null || true
fi
status=$("$app/Contents/MacOS/swiftty" --swiftmux-agent register || true)
echo "SwiftMux agent: $status"
case "$status" in
  *requiresApproval*)
    echo "  Allow \"Swiftty\" in System Settings > General > Login Items." ;;
  *enabled*) ;;
  *) echo "install.sh: agent registration failed" >&2; exit 1 ;;
esac

if [ "$roaming" -eq 1 ]; then
  # Sign as this user (the identity lives in the login keychain), then
  # install the signed copy as root.
  signed=.build/package/swifttyd
  cp "$bin/swifttyd" "$signed"
  if [ "$identity" = "-" ]; then timestamp=--timestamp=none; else timestamp=--timestamp; fi
  codesign --force --options runtime "$timestamp" --sign "$identity" \
    --identifier "$bundle_id.swifttyd" "$signed"
  codesign --verify --strict --verbose=1 "$signed"
  # A bare executable cannot be stapled; Gatekeeper fetches its ticket online.
  if [ -n "${NOTARY_PROFILE:-}" ] && [ "$identity" != "-" ]; then
    zip=.build/package/swifttyd-notarize.zip
    rm -f -- "$zip"
    ditto -c -k "$signed" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
  sudo mkdir -p "$(dirname "$helper")"
  sudo install -m 0755 -o root -g wheel "$signed" "$helper"
  codesign --verify --strict "$helper"
  echo "installed $helper"

  # The control directory must be owner-only (ControlDirectory).
  mkdir -p "$roaming_dir"
  chmod 0700 "$roaming_dir"
  if [ -f "$roaming_config" ]; then
    echo "kept existing $roaming_config"
  else
    [ -n "$host" ] || host="$(scutil --get LocalHostName).local"
    (
      umask 077
      temporary=$(mktemp "$roaming_dir/.config.XXXXXX")
      trap 'rm -f "$temporary"' EXIT
      trap 'exit 1' HUP INT TERM
      # Pass strings as values: plutil escapes JSON quotes, backslashes and
      # control characters. Publish only the completed configuration.
      plutil -create xml1 "$temporary"
      plutil -insert bindAddress -string "$bind" "$temporary"
      plutil -insert port -integer "$port" "$temporary"
      plutil -insert advertisedHost -string "$host" "$temporary"
      plutil -lint "$temporary" >/dev/null
      plutil -convert json "$temporary"
      mv "$temporary" "$roaming_config"
    )
    echo "wrote $roaming_config ($host, $bind:$port/udp)"
  fi

  # The agent reads the configuration at launch; restarting it would end
  # running shells, so an already running agent is left alone.
  if launchctl print "$domain/$label" 2>/dev/null | grep -q 'state = running'; then
    echo "note: the SwiftMux agent is running; roaming starts the next time it launches"
  fi
  if ! nc -z localhost 22 >/dev/null 2>&1; then
    echo "note: Remote Login looks off; enable it in System Settings > General > Sharing"
  fi
  echo "note: allow UDP $port through any firewall yourself; nothing is changed"
fi

if [ "$running" -eq 1 ]; then
  echo "Swiftty is running the previous build; quit and reopen it to update."
else
  open "$app"
fi
if [ "$roaming" -eq 1 ]; then
  i=0
  until "$helper" status 2>/dev/null || [ $i -ge 50 ]; do sleep 0.2; i=$((i + 1)); done
  "$helper" status || echo "note: roaming is not serving yet; enable SwiftMux in the app"
fi

# The iOS/iPadOS app, on iPhones and iPads connected by USB. The Mac
# install above is complete whether or not this succeeds.
if [ "$devices" -eq 1 ]; then
  [ -n "$team" ] || team=$new_team
  if [ -z "$team" ]; then
    echo "note: skipping iPhone/iPad install: an ad-hoc build has no team; pass --team"
  elif ! Scripts/install-ios.sh --team "$team"; then
    echo "install.sh: the Mac app is installed, but the iPhone/iPad install failed" >&2
    exit 1
  fi
fi
