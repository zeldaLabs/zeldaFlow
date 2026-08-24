#!/bin/bash
# Build zeldaFlow.app with a direct swiftc invocation (Command Line Tools only).
#
# Why not `swift build`: the macOS 27 beta CLT ships a PackageDescription
# whose swiftinterface and dylib disagree (every _PackageDescription>=6 symbol
# is unresolvable), so ANY Package.swift fails to compile. The app has zero
# package dependencies, so we compile the sources directly instead.
#
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

# /usr/bin/swiftc is a shim that exists on every Mac — check for real
# developer tools via the active developer directory instead.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "error: no developer tools — install them with: xcode-select --install" >&2
  exit 1
fi
# Hardware check, not process arch — a Rosetta-translated shell reports x86_64
# on Apple Silicon.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]; then
  echo "error: zeldaFlow builds for Apple Silicon only." >&2
  exit 1
fi

CONF="${1:-release}"
APP="build/zeldaFlow.app"
FRAMEWORK_DIR="Vendor/whisper.xcframework/macos-arm64_x86_64"

OPT="-O"
[ "$CONF" = "debug" ] && OPT="-Onone -g"

# Macro-plugin dir differs between standalone CLT and full Xcode installs.
DEV_DIR="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
PLUGINS="$DEV_DIR/usr/lib/swift/host/plugins"
[ -d "$PLUGINS" ] || PLUGINS="$DEV_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"
PLUGIN_ARGS=()
[ -d "$PLUGINS" ] && PLUGIN_ARGS=(-plugin-path "$PLUGINS")

mkdir -p build

# --- Vendored FluidAudio (speaker diarization, ADR 31) -----------------------
# Compiled as its own Swift-6 static module: the vendored code is Swift-6-only
# while the app compiles -swift-version 5, and no Package.swift works on this
# CLT (see header) — so the SPM dependency is vendored under Vendor/FluidAudio
# (see VENDORED.md there) and archived once. Cached: rebuilt when a vendored
# source is newer than the archive, OR when the toolchain changed — a
# .swiftmodule is only readable by the compiler that wrote it, so a Swift
# upgrade otherwise fails the app build with "compiled module was created by
# an older version of the compiler" and no hint that the cache is the culprit.
FLUID_DIR="Vendor/FluidAudio/Sources"
FLUID_STAMP="build/.fluidaudio-toolchain"
FLUID_MAPS=(-Xcc -fmodule-map-file="$FLUID_DIR/FastClusterWrapper/include/module.modulemap"
            -Xcc -fmodule-map-file="$FLUID_DIR/MachTaskSelfWrapper/include/module.modulemap")
SWIFT_ID="$(swiftc --version 2>&1 | head -1)"
if [ -f build/libFluidAudio.a ] \
   && [ -z "$(find "$FLUID_DIR" -newer build/libFluidAudio.a -print -quit 2>/dev/null)" ] \
   && [ "$(cat "$FLUID_STAMP" 2>/dev/null)" = "$SWIFT_ID" ]; then
  echo "==> FluidAudio module up to date"
else
  [ -f build/libFluidAudio.a ] && [ "$(cat "$FLUID_STAMP" 2>/dev/null)" != "$SWIFT_ID" ] \
    && echo "==> toolchain changed — rebuilding FluidAudio module"
  rm -f build/libFluidAudio.a build/FluidAudio.swiftmodule "$FLUID_STAMP"
  echo "==> clang (FastClusterWrapper, MachTaskSelf)"
  clang++ -std=c++17 -O2 --target=arm64-apple-macos15.0 \
    -c "$FLUID_DIR/FastClusterWrapper/FastClusterWrapper.cpp" \
    -I"$FLUID_DIR/FastClusterWrapper/include" -o build/FastClusterWrapper.o
  clang -O2 --target=arm64-apple-macos15.0 \
    -c "$FLUID_DIR/MachTaskSelfWrapper/MachTaskSelf.c" \
    -I"$FLUID_DIR/MachTaskSelfWrapper/include" -o build/MachTaskSelf.o
  echo "==> swiftc (FluidAudio module)"
  # Always -O: vendored code is never what's being debugged, and the archive
  # is cached across debug/release anyway.
  # shellcheck disable=SC2046
  swiftc -O -swift-version 6 -target arm64-apple-macos15.0 \
    -module-name FluidAudio \
    -emit-module -emit-module-path build/FluidAudio.swiftmodule \
    -emit-library -static -o build/libFluidAudio.a \
    "${FLUID_MAPS[@]}" \
    $(find "$FLUID_DIR/FluidAudio" -name "*.swift" | sort)
  printf '%s' "$SWIFT_ID" > "$FLUID_STAMP"
fi

echo "==> swiftc ($CONF)"
# main.swift must be listed for top-level code; order of the rest is irrelevant.
SOURCES=$(find Sources/zeldaFlow -name "*.swift" | sort)
# shellcheck disable=SC2086
swiftc $OPT \
  -swift-version 5 \
  -target arm64-apple-macos15.0 \
  ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} \
  -F "$FRAMEWORK_DIR" \
  -framework whisper \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -framework Carbon -framework ServiceManagement \
  -framework CoreAudio -framework AudioToolbox \
  -framework CoreML -framework Accelerate \
  -I build "${FLUID_MAPS[@]}" \
  -L build -lFluidAudio build/FastClusterWrapper.o build/MachTaskSelf.o -lc++ \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o build/zeldaFlow \
  $SOURCES

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp build/zeldaFlow "$APP/Contents/MacOS/zeldaFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Brand images (menu-bar wave mark, …)
cp Resources/*.png "$APP/Contents/Resources/" 2>/dev/null || true

# Embed the whisper dynamic framework (binary links @rpath/whisper.framework/...).
cp -R "$FRAMEWORK_DIR/whisper.framework" "$APP/Contents/Frameworks/"

# Signing identity: ZELDAFLOW_SIGN_ID env var, else a "zeldaFlow Dev" cert if
# present in the keychain (see scripts/make-cert.sh), else ad-hoc.
# NOTE: ad-hoc identity changes on every rebuild, so macOS drops the app's
# Accessibility/Microphone grants after each rebuild — re-grant in System
# Settings. A stable cert avoids that.
SIGN_ID="${ZELDAFLOW_SIGN_ID:-}"
# NOTE: deliberately NOT `find-identity -v`. A self-signed certificate is
# reported CSSMERR_TP_NOT_TRUSTED and hidden by -v, yet codesign accepts it
# perfectly well — and that is all we need. Using -v here used to send every
# user down a pointless "trust it in Keychain Access" detour, and silently
# fall back to ad-hoc signing (which loses TCC grants on every rebuild) when
# they skipped it.
if [ -z "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q "zeldaFlow Dev"; then
  SIGN_ID="zeldaFlow Dev"
fi
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="-"
  cat >&2 <<'WARN'

  ┌─────────────────────────────────────────────────────────────────────┐
  │  WARNING: ad-hoc signing — permissions will NOT survive rebuilds.    │
  │                                                                     │
  │  macOS ties Accessibility/Microphone grants to the code signature,   │
  │  and an ad-hoc signature is different every single build. After      │
  │  each rebuild the Fn key silently stops working, and System          │
  │  Settings still shows zeldaFlow ticked — you have to REMOVE the      │
  │  entry and add it back.                                             │
  │                                                                     │
  │  Fix it once, permanently:                                          │
  │      scripts/make-cert.sh        (then trust it in Keychain Access)  │
  │      scripts/install.sh                                             │
  └─────────────────────────────────────────────────────────────────────┘

WARN
fi

echo "==> codesign ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/whisper.framework/Versions/A"
codesign --force --sign "$SIGN_ID" --identifier com.zeldalabs.zeldaflow "$APP"
codesign -v "$APP"

# Keep the build artifact out of Launch Services AND out of the Spotlight
# index — otherwise Spotlight/Launchpad list it as a second installed
# zeldaFlow next to the real one in /Applications.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
touch build/.metadata_never_index

echo "==> built $APP"
