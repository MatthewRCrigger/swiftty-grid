#!/bin/sh
# Removes what Scripts/install.sh installed: Swiftty.app, its SwiftMux
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
    --dest) dest=$2; shift 2 ;;
    --purge) purge=1; shift ;;
    -y | --yes) yes=1; shift ;;
    -h | --help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown option $1" >&2; exit 64 ;;
  esac
done

label=com.chr33s.swiftty.swiftmux
bundle_id=com.chr33s.swiftty
app="$dest/Swiftty.app"
helper=/usr/local/libexec/swifttyd
dev_plist="$HOME/Library/LaunchAgents/$label.plist"

# Unregistering ends every pane, including the one running this script.
if [ "${TERM:-}" = swmux-256color ]; then
  echo "uninstall.sh: run this outside SwiftMux; it ends every SwiftMux pane" >&2
  exit 1
fi

if [ "$yes" -eq 0 ]; then
  printf 'This ends all running SwiftMux sessions. Continue? [y/N] '
  read -r answer
  case "$answer" in y | Y | yes) ;; *) echo "aborted"; exit 1 ;; esac
fi

# Quitting from a Swiftty window would end this script with it.
if [ "${TERM_PROGRAM:-}" = swiftty ]; then
  echo "note: quit Swiftty yourself; the app is removed from disk"
elif pgrep -xq swiftty; then
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  i=0
  while pgrep -xq swiftty && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
fi

if [ -x "$app/Contents/MacOS/swiftty" ]; then
  "$app/Contents/MacOS/swiftty" --swiftmux-agent unregister || true
fi
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
if [ -f "$dev_plist" ]; then
  rm -f -- "$dev_plist"
  echo "removed $dev_plist"
fi

if [ -d "$app" ]; then
  if [ -w "$dest" ]; then rm -rf -- "$app"; else sudo rm -rf -- "$app"; fi
  echo "removed $app"
fi
if [ -e "$helper" ]; then
  sudo rm -f -- "$helper"
  echo "removed $helper"
fi

if [ "$purge" -eq 1 ]; then
  rm -rf -- "$HOME/Library/Application Support/SwiftMux" "$HOME/.config/swmux"
  echo "removed SwiftMux state and settings"
fi
