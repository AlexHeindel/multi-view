#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
target="$(uname -m)-apple-macosx14.0"
if [[ "${1:-}" == "test" || "${1:-}" == "stress" ]]; then
    xcrun swiftc -swift-version 5 -target "$target" -g -D CHECKS -module-cache-path .build/module-cache \
        Sources/*.swift Tests/Checks.swift -o .build/checks
    .build/checks "${1:-test}"
    exit
fi
app="build/Plot Viewer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -target "$target" -O -module-cache-path .build/module-cache \
    Sources/*.swift -o "$app/Contents/MacOS/PlotViewer"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>PlotViewer</string>
    <key>CFBundleIdentifier</key><string>local.plotviewer</string>
    <key>CFBundleName</key><string>Plot Viewer</string>
    <key>CFBundleDisplayName</key><string>Plot Viewer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf 'Built %s/%s\n' "$PWD" "$app"
