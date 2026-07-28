#!/bin/bash
# Builds "Claude Usage.app" from the SwiftPM executable.
#
#   ./build.sh           build + assemble + sign into ./build
#   ./build.sh install   the above, then replace /Applications/Claude Usage.app and launch it
#
# Signing identity
# ----------------
# Defaults to ad-hoc ("-"), which is enough to run but gives the binary a new
# identity on every rebuild. The app reads the Claude Code keychain item through
# /usr/bin/security, so that does not cause prompts — but if you ever switch to
# the SecItemCopyMatching path, or want a stable identity for other reasons,
# create a self-signed code-signing certificate in Keychain Access and build with:
#
#   SIGN_ID="My Self-Signed Cert" ./build.sh install
#
# The app is intentionally NOT sandboxed and ships no entitlements: it needs to
# spawn /usr/bin/security and reach the login keychain.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Usage"
BUNDLE_ID="com.aucentiq.ClaudeUsage"
EXECUTABLE="ClaudeUsage"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"
SIGN_ID="${SIGN_ID:--}"

echo "==> Building release binary"
swift build -c release --arch arm64
BINARY="$(swift build -c release --arch arm64 --show-bin-path)/${EXECUTABLE}"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp "${BINARY}" "${APP}/Contents/MacOS/${EXECUTABLE}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

echo "==> Signing with identity: ${SIGN_ID}"
codesign --force --sign "${SIGN_ID}" --identifier "${BUNDLE_ID}" "${APP}"
codesign --verify --verbose "${APP}"

echo "==> Built ${APP}"

if [[ "${1:-}" == "install" ]]; then
	echo "==> Installing to /Applications"
	killall "${EXECUTABLE}" 2>/dev/null || true
	rm -rf "/Applications/${APP_NAME}.app"
	ditto "${APP}" "/Applications/${APP_NAME}.app"
	open "/Applications/${APP_NAME}.app"
	echo "==> Installed and launched"
fi
