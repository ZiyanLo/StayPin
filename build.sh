#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-build/StayPin.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICON_WORK_DIR="build/icon-build"
mkdir -p "$ICON_WORK_DIR/AppIcon.iconset"
swift Resources/RenderIcon.swift "$ICON_WORK_DIR/AppIcon.iconset"
iconutil -c icns "$ICON_WORK_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 main.swift HandoffController.swift OverlayPolicy.swift WindowFrameCrop.swift CapturedWindowFrame.swift OverlayPair.swift PresentationGeometry.swift StatusButtonController.swift HoverActivationMonitor.swift -o "$APP/Contents/MacOS/WindowPin" -framework Cocoa -framework Carbon -framework ApplicationServices -framework ScreenCaptureKit -framework AVFoundation
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowPin</string>
<key>CFBundleIdentifier</key><string>local.windowpin.lite</string>
<key>CFBundleName</key><string>StayPin</string>
<key>CFBundleDisplayName</key><string>StayPin</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>10</string>
<key>CFBundleShortVersionString</key><string>2.7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
