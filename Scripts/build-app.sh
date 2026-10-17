#!/bin/zsh
# Builds LayoutFix.app (Apple Silicon, release) into ./build.
#   Scripts/build-app.sh            ad-hoc signed
#   SIGN_IDENTITY="Apple Development: …" Scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/LayoutFix.app"
IDENTITY="${SIGN_IDENTITY:--}"

echo "==> swift build (release, arm64)"
swift build -c release --arch arm64 --product LayoutFix
BIN="$(swift build -c release --arch arm64 --show-bin-path)/LayoutFix"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LayoutFix"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> signing (identity: $IDENTITY)"
# Not sandboxed: the App Sandbox does not allow controlling other apps through Accessibility.
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> done: $APP"
lipo -archs "$APP/Contents/MacOS/LayoutFix"
