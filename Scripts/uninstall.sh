#!/bin/sh
# Removes what Scripts/install.sh installed: Swiftty GRID.app, its SwiftMux
# LaunchAgent registration (or a `swmux agent install` development agent)
# and the swifttyd bootstrap helper. Unregistering the agent ends every
# SwiftMux session, so it asks first.
#
# usage: Scripts/uninstall.sh [options]
#   --dest DIR   install directory (default /Applications)
#   --purge      also delete SwiftMux state (~/Library/Application Support/SwiftMux,
#                including the roaming configuration) and ~/.config/swmux
#   -y, --yes    do not ask before ending sessions
set -eu

dest=/Applications
purge=0
yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dest)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "uninstall.sh: --dest requires a directory" >&2; exit 64
      fi
      case "$2" in
        --* | -h | -y) echo "uninstall.sh: --dest requires a directory" >&2; exit 64 ;;
      esac
      dest=$2; shift 2 ;;
    --purge) purge=1; shift ;;
    -y | --yes) yes=1; shift ;;
    -h | --help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown option $1" >&2; exit 64 ;;
  esac
done

label=com.chr33s.swiftty.swiftmux
bundle_id=com.chr33s.swiftty
app="$dest/Swiftty GRID.app"
helper=/usr/local/libexec/swifttyd
dev_plist="$HOME/Library/LaunchAgents/$label.plist"

fail() { echo "uninstall.sh: $*" >&2; exit 1; }

command_runner="$(dirname "$0")/uninstall-command.py"
run_command() { python3 "$command_runner" "$@"; }

# Quitting the app or unregistering its agent can end the invoking terminal.
if [ "${TERM:-}" = swmux-256color ] || [ "${TERM_PROGRAM:-}" = swiftty ]; then
  echo "uninstall.sh: run this outside Swiftty and SwiftMux" >&2
  exit 1
fi

if [ "$yes" -eq 0 ]; then
  printf 'This ends all running SwiftMux sessions. Continue? [y/N] '
  read -r answer
  case "$answer" in y | Y | yes) ;; *) echo "aborted"; exit 1 ;; esac
fi

command -v python3 >/dev/null 2>&1 || fail "python3 is required for bounded shutdown commands"
[ -r "$command_runner" ] || fail "missing uninstall command runner: $command_runner"

app_running() {
  if run_command pgrep -xq swiftty; then return 0; else process_status=$?; fi
  [ "$process_status" -eq 1 ] || fail "cannot inspect running Swiftty processes (status $process_status)"
  return 1
}

if app_running; then
  run_command osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null \
    || fail "could not request Swiftty to quit"
  run_command --wait-app-exit >/dev/null \
    || fail "Swiftty did not quit; installation files preserved"
fi

if [ -x "$app/Contents/MacOS/swiftty" ]; then
  agent_status=$(run_command "$app/Contents/MacOS/swiftty" --swiftmux-agent status) \
    || fail "cannot inspect bundled agent registration: $agent_status"
  case "$agent_status" in
    notRegistered | notFound) ;;
    enabled | requiresApproval)
      agent_status=$(run_command "$app/Contents/MacOS/swiftty" --swiftmux-agent unregister) \
        || fail "bundled agent unregister failed: $agent_status; installation files preserved"
      case "$agent_status" in
        notRegistered | notFound) ;;
        *) fail "bundled agent remains registered ($agent_status); installation files preserved" ;;
      esac ;;
    *) fail "unknown bundled agent registration ($agent_status)" ;;
  esac
fi
user_id=$(run_command id -u)
case "$user_id" in *[!0-9]*|'') fail "invalid user ID" ;; esac
service="gui/$user_id/$label"
bootout_status=0
run_command launchctl bootout "$service" >/dev/null || bootout_status=$?
if [ "$bootout_status" -ge 124 ]; then
  fail "LaunchAgent bootout did not complete (status $bootout_status); files preserved"
fi
probe_status=0
run_command launchctl print "$service" >/dev/null || probe_status=$?
case "$probe_status" in
  113) ;; # Explicit "Could not find specified service", including repeat uninstall.
  0) fail "LaunchAgent remains loaded after bootout (status $bootout_status); files preserved" ;;
  *) fail "cannot verify LaunchAgent removal (status $probe_status); files preserved" ;;
esac
if [ -e "$dev_plist" ] || [ -L "$dev_plist" ]; then
  [ -f "$dev_plist" ] || [ -L "$dev_plist" ] || fail "development plist is not a file: $dev_plist"
  rm -f -- "$dev_plist"
  echo "removed $dev_plist"
fi

if [ -d "$app" ]; then
  if [ -w "$dest" ]; then rm -rf -- "$app"; else sudo rm -rf -- "$app"; fi
  echo "removed $app"
fi
if [ -e "$helper" ] || [ -L "$helper" ]; then
  sudo rm -f -- "$helper"
  echo "removed $helper"
fi

if [ "$purge" -eq 1 ]; then
  rm -rf -- "$HOME/Library/Application Support/SwiftMux" "$HOME/.config/swmux"
  echo "removed SwiftMux state and settings"
fi
