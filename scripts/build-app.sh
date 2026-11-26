#!/usr/bin/env bash
# Builds build/Taffy.app from the Swift package.
#
#   CONFIG=debug|release   build configuration (default: release)
#   UNIVERSAL=1            build an arm64 + x86_64 binary (needs full Xcode)
#   CODESIGN_IDENTITY=...  signing identity (default: "-", ad-hoc). Always signed with Hardened Runtime
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
VERSION="$(sed -n 's/.*current = "\(.*\)"/\1/p' Sources/Taffy/Version.swift)"

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Taffy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Taffy" "$APP/Contents/MacOS/Taffy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# 公証に必要な Hardened Runtime を有効にする（ad-hoc 署名でも同じ entitlement で動作を揃える）
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --options runtime --entitlements Resources/Taffy.entitlements --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Built $APP ($VERSION)"
