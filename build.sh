#!/bin/zsh
# Builds "build/Nebula Drift.app".
set -e
cd "$(dirname "$0")"
APP="build/Nebula Drift.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/NebulaDrift" Sources/*.swift
cp Sources/Shaders.metal "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
xattr -cr "$APP" # Finder/iCloud metadata makes codesign fail
codesign --force --sign - "$APP"
echo "Built $APP"
