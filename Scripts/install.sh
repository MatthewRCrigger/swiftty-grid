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
#                      changed; its running sessions end
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
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) identity=$2; shift 2 ;;
    --dest) dest=$2; shift 2 ;;
    --roaming) roaming=1; shift ;;
    --host) host=$2; shift 2 ;;
    --bind) bind=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --replace-dev-agent) replace_dev=1; shift ;;
    --restart-agent) restart_agent=1; shift ;;
    -h | --help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 64 ;;
  esac
done

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
# with "Launch Constraint Violation" until the agent is re-registered.
agent_info=$(launchctl print "$domain/$label" 2>/dev/null || true)
registered_team=$(printf '%s\n' "$agent_info" \
  | sed -n 's/.*"team-identifier" => "\(.*\)".*/\1/p' | head -n 1)
new_team=$(team_of "$built/Contents/MacOS/swiftmux-agent")
reregister=0
if [ -n "$agent_info" ] && [ "$registered_team" != "$new_team" ]; then
  if printf '%s\n' "$agent_info" | grep -q 'state = running' \
    && [ "$restart_agent" -eq 0 ]; then
    echo "install.sh: the running SwiftMux agent is registered for team" \
      "'${registered_team:-none}', the new build is '${new_team:-none}'." >&2
    echo "  Re-run with --restart-agent (its running sessions end)." >&2
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
sudo_if_needed "$dest" rm -rf -- "$app"
sudo_if_needed "$dest" ditto "$built" "$app"
echo "installed $app"

if [ "$reregister" -eq 1 ]; then
  echo "re-registering the SwiftMux agent (team '${registered_team:-none}' -> '${new_team:-none}')"
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
    umask 077
    cat >"$roaming_config" <<EOF
{
  "bindAddress": "$bind",
  "port": $port,
  "advertisedHost": "$host"
}
EOF
    plutil -lint "$roaming_config" >/dev/null
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
