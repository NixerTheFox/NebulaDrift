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
cp Info.plist "$APP/Contents/"
xattr -cr "$APP" # Finder/iCloud metadata makes codesign fail
codesign --force --sign - "$APP"
echo "Built $APP"
