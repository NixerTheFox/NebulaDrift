#!/bin/zsh
# Builds "build/Nebula Drift.app".
set -e
cd "$(dirname "$0")"
APP="build/Nebula Drift.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# A universal binary (Apple silicon and Intel) for macOS 14.2, the first with Core Audio process taps.
for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.2" -o "build/NebulaDrift-$ARCH" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/NebulaDrift" build/NebulaDrift-arm64 build/NebulaDrift-x86_64
rm build/NebulaDrift-arm64 build/NebulaDrift-x86_64
cp Sources/Shaders.metal "$APP/Contents/Resources/"
# The app icon, in every size macOS asks for, from one 1024-pixel image.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z $((SIZE * 2)) $((SIZE * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
cp Info.plist "$APP/Contents/"
xattr -cr "$APP" # Finder/iCloud metadata makes codesign fail
codesign --force --sign - "$APP"
echo "Built $APP"
