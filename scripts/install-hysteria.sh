#!/bin/bash
set -euo pipefail

# Runs ON the target host. Installs a pinned Hysteria 2 arm64 release with
# sha256 verification. Override with HYSTERIA_VERSION=vX.Y.Z.

VERSION="${HYSTERIA_VERSION:-app/v2.14.0}"
VER_NUM="${VERSION#app/}"
DEST=/usr/local/bin/hysteria
BASE="https://github.com/apernet/hysteria/releases/download/$VERSION"

if [ -x "$DEST" ] && "$DEST" version 2>/dev/null | grep -q "$VER_NUM"; then
    echo "hysteria $VER_NUM already installed"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/build"

echo "Downloading hysteria $VER_NUM (linux-arm64)..."
curl -fsSL "$BASE/hysteria-linux-arm64" -o "$TMP/build/hysteria-linux-arm64"
curl -fsSL "$BASE/hashes.txt" -o "$TMP/hashes.txt"

echo "Verifying sha256..."
(cd "$TMP" && grep 'build/hysteria-linux-arm64$' hashes.txt | sha256sum -c -)

install -m 0755 "$TMP/build/hysteria-linux-arm64" "$DEST"
"$DEST" version
