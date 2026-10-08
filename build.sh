#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/VoiceSidecar.app"
BIN="$APP/Contents/MacOS/VoiceSidecar"

# Resolve compiler and SDK through the same selected Xcode installation.
unset SDKROOT TOOLCHAINS
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Explicit deployment target matches LSMinimumSystemVersion in Info.plist.
xcrun --sdk macosx swiftc -O -swift-version 5 -parse-as-library \
  -sdk "$SDK" -target "${ARCH}-apple-macosx13.0" \
  -framework Foundation -framework AppKit -framework SwiftUI \
  -framework Combine -framework AVFoundation -framework IOKit \
  -framework ApplicationServices -framework CoreGraphics \
  "$ROOT"/Sources/*.swift -o "$BIN"
chmod +x "$BIN"
# An ad-hoc signature allows macOS to identify the local app; no Apple ID is needed.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --identifier local.voicesidecar.mac "$APP"
fi
echo
echo "Built $APP"
echo "Start with: open '$APP'"
echo "Grant Mic, Input Monitoring and Accessibility, then restart the app if prompted."
