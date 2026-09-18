#!/bin/bash
# Build Pull and wrap it into a signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d "/Applications/Xcode-beta.app" ]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

echo "==> Compiling (release)..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Pull"
APP="build/Pull.app"

echo "==> Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pull"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Real signing identity keeps TCC/Gatekeeper happy across rebuilds.
# Hardened runtime blocks DYLD injection into the app (which would inherit
# its folder-access grants). No entitlements: sandboxing would break
# spawning Homebrew binaries and writing to a user-chosen folder.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [ -n "${IDENTITY}" ] && codesign --force --options runtime --timestamp --sign "${IDENTITY}" "$APP" 2>/dev/null; then
  echo "==> Code-signed (hardened runtime) with: ${IDENTITY}"
else
  echo "==> No usable Apple Development identity — ad-hoc signing"
  codesign --force --options runtime --sign - "$APP"
fi

echo "==> Done.  open ${APP}"
