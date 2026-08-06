#!/bin/bash
# Builds "Maxima.app" from the SwiftPM executable.
#
#   ./build.sh           build + assemble + sign into ./build
#   ./build.sh install   the above, then replace /Applications/Maxima.app and launch it
#   ./build.sh dmg       the above, then package dist/Maxima-<version>.dmg
#
# Signing identity
# ----------------
# SIGN_ID defaults to ad-hoc ("-"), which is enough to run locally but gives the
# binary a new identity on every rebuild. The app reads the Claude Code keychain
# item through /usr/bin/security, so that does not cause prompts — but if you ever
# switch to the SecItemCopyMatching path, or want a stable identity for other
# reasons, create a self-signed code-signing certificate in Keychain Access and
# build with:
#
#   SIGN_ID="My Self-Signed Cert" ./build.sh install
#
# Release builds pass a real Developer ID identity, which also enables the
# hardened runtime and a secure timestamp — both required for notarization.
#
# Version
# -------
# VERSION overrides the marketing and build version stamped into the bundle. The
# release workflow derives it from the git tag; leave it unset locally and the
# committed Info.plist value is used as-is.
#
#   VERSION=1.2.3 SIGN_ID="Developer ID Application: …" ./build.sh dmg
#
# The app is intentionally NOT sandboxed and ships no entitlements: it needs to
# spawn /usr/bin/security and reach the login keychain.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Maxima"
BUNDLE_ID="com.aucentiq.Maxima"
EXECUTABLE="Maxima"
BUILD_DIR="build"
DIST_DIR="dist"
APP="${BUILD_DIR}/${APP_NAME}.app"
SIGN_ID="${SIGN_ID:--}"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

echo "==> Building release binary"
swift build -c release --arch arm64
BINARY="$(swift build -c release --arch arm64 --show-bin-path)/${EXECUTABLE}"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp "${BINARY}" "${APP}/Contents/MacOS/${EXECUTABLE}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

if [[ -n "${VERSION:-}" ]]; then
	echo "==> Stamping version ${VERSION}"
	"${PLIST_BUDDY}" -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
	"${PLIST_BUDDY}" -c "Set :CFBundleVersion ${VERSION}" "${APP}/Contents/Info.plist"
fi
APP_VERSION="$("${PLIST_BUDDY}" -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")"

echo "==> Signing with identity: ${SIGN_ID}"
# --options runtime and --timestamp are prerequisites for notarization. An ad-hoc
# signature cannot carry either, so they are only added for a real identity.
CODESIGN_FLAGS=(--force --sign "${SIGN_ID}" --identifier "${BUNDLE_ID}")
if [[ "${SIGN_ID}" != "-" ]]; then
	CODESIGN_FLAGS+=(--options runtime --timestamp)
fi
codesign "${CODESIGN_FLAGS[@]}" "${APP}"
codesign --verify --verbose "${APP}"

echo "==> Built ${APP} (${APP_VERSION})"

case "${1:-}" in
install)
	echo "==> Installing to /Applications"
	killall "${EXECUTABLE}" 2>/dev/null || true
	rm -rf "/Applications/${APP_NAME}.app"
	ditto "${APP}" "/Applications/${APP_NAME}.app"
	open "/Applications/${APP_NAME}.app"
	echo "==> Installed and launched"
	;;
dmg)
	DMG="${DIST_DIR}/${APP_NAME}-${APP_VERSION}.dmg"
	echo "==> Packaging ${DMG}"
	mkdir -p "${DIST_DIR}"
	rm -f "${DMG}"

	# Plain hdiutil rather than create-dmg: the drag-to-Applications layout only
	# needs the bundle and a symlink side by side, and this keeps third-party
	# tooling out of the release path. ditto (not cp) so the signature survives.
	STAGING="$(mktemp -d)"
	trap 'rm -rf "${STAGING}"' EXIT
	ditto "${APP}" "${STAGING}/${APP_NAME}.app"
	ln -s /Applications "${STAGING}/Applications"

	hdiutil create \
		-volname "${APP_NAME}" \
		-srcfolder "${STAGING}" \
		-format UDZO \
		-quiet \
		"${DMG}"

	if [[ "${SIGN_ID}" != "-" ]]; then
		echo "==> Signing ${DMG}"
		codesign --force --sign "${SIGN_ID}" --timestamp "${DMG}"
		codesign --verify --verbose "${DMG}"
	fi

	echo "==> Packaged ${DMG}"
	;;
esac
