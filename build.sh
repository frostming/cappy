#!/bin/bash
# Builds build/Cappy.app. Set CAPPY_SIGN_ID to a signing identity to keep the
# screen-recording permission across rebuilds (ad-hoc signing resets it).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

if [ ! -f Resources/AppIcon.icns ]; then
    tmp=$(mktemp -d)
    swift Scripts/make_icon.swift "$tmp/icon.png"
    mkdir "$tmp/AppIcon.iconset"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
    rm -rf "$tmp"
fi

APP=build/Cappy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Cappy "$APP/Contents/MacOS/Cappy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${CAPPY_SIGN_ID:--}" "$APP"
echo "Built $APP"
