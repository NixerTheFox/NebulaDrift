#!/usr/bin/env bash
# Builds "Nebula_Drift-<arch>.AppImage" in linux/build/.
# Needs: cmake, a C++17 compiler, and the SDL2, Cairo and FreeType development packages
# (Debian/Ubuntu: sudo apt install cmake g++ libsdl2-dev libcairo2-dev libfreetype-dev libgl-dev).
# linuxdeploy is downloaded on first use.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
BUILD="build"
APPDIR="$BUILD/AppDir"
TOOLS="$BUILD/tools"

cmake -S . -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$BUILD" -j"$(nproc)"
rm -rf "$APPDIR"
DESTDIR="$PWD/$APPDIR" cmake --install "$BUILD"

mkdir -p "$TOOLS"
LINUXDEPLOY="$TOOLS/linuxdeploy-$ARCH.AppImage"
if [ ! -x "$LINUXDEPLOY" ]; then
    curl -fL -o "$LINUXDEPLOY" \
        "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage"
    chmod +x "$LINUXDEPLOY"
fi

# Bundles SDL2, Cairo and their dependencies. Graphics drivers, glibc and the sound server's client
# library (loaded at runtime) come from the host, as they must.
export APPIMAGE_EXTRACT_AND_RUN=1 # works without FUSE (containers, CI)
export LDAI_OUTPUT="$BUILD/Nebula_Drift-$ARCH.AppImage"
export ARCH
"$LINUXDEPLOY" --appdir "$APPDIR" \
    --desktop-file packaging/nebuladrift.desktop \
    --icon-file packaging/nebuladrift.png \
    --output appimage

echo "Built $LDAI_OUTPUT"
