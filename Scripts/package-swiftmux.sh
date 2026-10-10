#!/bin/sh
# Assembles Swiftty.app with the SwiftMux LaunchAgent, PTY launcher and
# swmux client, then signs it. SMAppService registers the bundled agent
# when the app first enables SwiftMux.
#
# usage: Scripts/package-swiftmux.sh [signing-identity] [output-dir]
#   signing-identity  Developer ID identity, or "-" for ad-hoc (default).
#                     Ad-hoc builds only get the same-user peer check.
set -eu

identity=${1:--}
out=${2:-.build/package}
label=com.chr33s.swiftty.swiftmux
bundle_id=com.chr33s.swiftty

swift build -c release
bin=$(swift build -c release --show-bin-path)

app="$out/Swiftty.app"
rm -rf -- "${app:?}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
  "$app/Contents/Library/LaunchAgents"

for exe in swiftty swiftmux-agent swmux-launcher swmux; do
  cp "$bin/$exe" "$app/Contents/MacOS/$exe"
done
cp -R "$bin/swiftty_SwifttyCore.bundle" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>Swiftty</string>
  <key>CFBundleExecutable</key><string>swiftty</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# On demand through its Mach service; no KeepAlive or pressured exit.
cat > "$app/Contents/Library/LaunchAgents/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>BundleProgram</key><string>Contents/MacOS/swiftmux-agent</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$bundle_id</string></array>
  <key>MachServices</key><dict><key>$label</key><true/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnablePressuredExit</key><false/>
</dict>
</plist>
EOF

# Sign nested code first, then the app (no --deep).
for exe in swiftmux-agent swmux-launcher swmux; do
  codesign --force --options runtime --timestamp=none --sign "$identity" \
    --identifier "$bundle_id.$exe" "$app/Contents/MacOS/$exe"
done
codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
codesign --verify --strict --verbose=1 "$app"
echo "$app"
