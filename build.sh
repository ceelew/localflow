#!/bin/zsh
# Builds LocalFlow and wraps it in a menu-bar .app so macOS can grant it Microphone and Accessibility access.
#
# This calls swiftc directly instead of `swift build`, because the SwiftPM in some Command Line Tools
# installs is broken. FluidAudio is compiled once from vendor/ and cached in .build-manual/.
# FluidAudio's optional prebuilt NemoTextProcessing binary (used only for text-to-speech) is not used.
set -euo pipefail
cd "$(dirname "$0")"

FLUID_VERSION=0.17.7
F="vendor/FluidAudio-$FLUID_VERSION/Sources"
O=.build-manual
TARGET=arm64-apple-macos15

# Use the newest SDK that the installed compiler can actually read.
if [[ -z "${SDKROOT:-}" ]]; then
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk | sort -rV); do
    if echo 'print(1)' | swiftc -sdk "$sdk" -typecheck - 2>/dev/null; then export SDKROOT="$sdk"; break; fi
  done
fi
echo "Using SDK: $SDKROOT"

if [[ ! -d "$F" ]]; then
  echo "Fetching FluidAudio $FLUID_VERSION source…"
  mkdir -p vendor
  curl -fsL "https://github.com/FluidInference/FluidAudio/archive/refs/tags/v$FLUID_VERSION.tar.gz" | tar -xz -C vendor
fi

MODULE_FLAGS=(
  -Xcc -fmodule-map-file=$F/MachTaskSelfWrapper/include/module.modulemap
  -Xcc -fmodule-map-file=$F/FastClusterWrapper/include/module.modulemap
  -I $F/MachTaskSelfWrapper/include -I $F/FastClusterWrapper/include
)

mkdir -p $O/shim
if [[ ! -f $O/libFluidAudio.a ]]; then
  echo "Compiling FluidAudio (about a minute, first build only)…"
  cat > $O/shim/BundleModule.swift <<'EOF'
import Foundation
// SwiftPM normally generates this. LocalFlow doesn't use FluidAudio's TTS resources, so point it at the main bundle.
extension Foundation.Bundle { static let module = Bundle.main }
EOF
  clang -c -O2 -target $TARGET -I $F/MachTaskSelfWrapper/include $F/MachTaskSelfWrapper/MachTaskSelf.c -o $O/MachTaskSelf.o
  clang++ -c -O2 -std=c++17 -target $TARGET -I $F/FastClusterWrapper/include $F/FastClusterWrapper/FastClusterWrapper.cpp -o $O/FastCluster.o
  swiftc -O -wmo -parse-as-library -swift-version 6 -target $TARGET -module-name FluidAudio \
    -emit-module -emit-module-path $O/FluidAudio.swiftmodule -emit-library -static -o $O/libFluidAudio.a \
    $MODULE_FLAGS $(find $F/FluidAudio -name "*.swift") $O/shim/BundleModule.swift
fi

echo "Compiling LocalFlow…"
swiftc -O -swift-version 5 -target $TARGET -module-name LocalFlow \
  -I $O -L $O -lFluidAudio $O/MachTaskSelf.o $O/FastCluster.o -lc++ $MODULE_FLAGS \
  Sources/LocalFlow/*.swift -o $O/LocalFlow

APP="build/LocalFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp $O/LocalFlow "$APP/Contents/MacOS/LocalFlow"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.localflow</string>
  <key>CFBundleName</key><string>LocalFlow</string>
  <key>CFBundleExecutable</key><string>LocalFlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>LocalFlow listens while you hold the hotkey and transcribes on this Mac.</string>
</dict>
</plist>
PLIST

# Sign with the local "LocalFlow Code Signing" certificate when it exists, so the app keeps the same identity
# across rebuilds and macOS keeps its Microphone/Accessibility permissions. Otherwise fall back to ad-hoc signing,
# which macOS treats as a new app on every build.
IDENTITY="LocalFlow Code Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier local.localflow "$APP"
else
  echo "warning: '$IDENTITY' certificate not found; ad-hoc signing (permissions reset on every rebuild)"
  codesign --force --sign - --identifier local.localflow "$APP"
fi
echo "Built $APP"
