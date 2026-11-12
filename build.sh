#!/bin/bash
# Builds build/Cappy.app. Set CAPPY_SIGN_ID to a signing identity (e.g. a
# "Developer ID Application: …" certificate) to sign for distribution and to
# keep the screen-recording permission across rebuilds; without it the app is
# ad-hoc signed and the permission resets on every build.
set -euo pipefail
cd "$(dirname "$0")"

# CAPPY_UNIVERSAL=1 builds for both Apple silicon and Intel (used for releases).
if [ "${CAPPY_UNIVERSAL:-0}" = "1" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Cappy"

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
cp "$BIN" "$APP/Contents/MacOS/Cappy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${CAPPY_SIGN_ID:-}" ]; then
    # A real identity: hardened runtime + secure timestamp, as notarization requires.
    codesign --force --options runtime --timestamp --sign "$CAPPY_SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
