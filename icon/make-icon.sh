#!/bin/bash
# Renders icon/maxima.svg into Resources/Maxima.icns.
#
# Only needed when the artwork changes. The .icns is committed so that an
# ordinary build — and the release workflow — needs no extra tooling.
#
# Requires rsvg-convert (brew install librsvg). iconutil ships with macOS.
#
# To change the design itself, edit the constants in generate.py and re-run:
#
#   python3 generate.py maxima.svg && ./make-icon.sh

set -euo pipefail

cd "$(dirname "$0")"

command -v rsvg-convert > /dev/null || {
	echo "rsvg-convert not found — brew install librsvg" >&2
	exit 1
}

STAGING="$(mktemp -d)"
ICONSET="${STAGING}/Maxima.iconset"
mkdir -p "${ICONSET}"
trap 'rm -rf "${STAGING}"' EXIT

# name                  px
render() {
	rsvg-convert -w "$2" -h "$2" maxima.svg -o "${ICONSET}/$1"
}

render icon_16x16.png      16
render icon_16x16@2x.png   32
render icon_32x32.png      32
render icon_32x32@2x.png   64
render icon_128x128.png    128
render icon_128x128@2x.png 256
render icon_256x256.png    256
render icon_256x256@2x.png 512
render icon_512x512.png    512
render icon_512x512@2x.png 1024

iconutil --convert icns "${ICONSET}" --output ../Resources/Maxima.icns

echo "==> Wrote Resources/Maxima.icns ($(du -h ../Resources/Maxima.icns | cut -f1))"
