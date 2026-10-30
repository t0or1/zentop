#!/bin/bash
# Builds a release package: dist/zentop-<version>-linux-x86_64.tar.gz + .sha256
# The version comes from src/version.vala. Run from anywhere: bash release.sh
set -e
cd "$(dirname "$0")"
VERSION=$(sed -n 's/.*ZENTOP_VERSION = "\(.*\)".*/\1/p' src/version.vala)
[ -n "$VERSION" ] || { echo "No version in src/version.vala"; exit 1; }
ARCH=$(uname -m)
NAME="zentop-$VERSION-linux-$ARCH"

rm -f zentop
bash build.sh
strip zentop                                    # drop debug symbols: ~1/3 smaller
[ "$(./zentop --version)" = "zentop $VERSION" ] || { echo "Built binary reports the wrong version"; exit 1; }

STAGE=$(mktemp -d)
mkdir -p "$STAGE/$NAME"
cp -r zentop themes fonts install.sh README.md LICENSE "$STAGE/$NAME/"
chmod 644 "$STAGE/$NAME/LICENSE" "$STAGE/$NAME/README.md"
[ -f CHANGELOG.md ] && cp CHANGELOG.md "$STAGE/$NAME/"
chmod 755 "$STAGE/$NAME/zentop" "$STAGE/$NAME/install.sh" "$STAGE/$NAME/fonts/get-fonts.sh"
mkdir -p dist
tar -C "$STAGE" --owner=0 --group=0 -czf "dist/$NAME.tar.gz" "$NAME"
rm -rf "$STAGE"
(cd dist && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "dist/$NAME.tar.gz ($(du -h "dist/$NAME.tar.gz" | cut -f1))"
cat "dist/$NAME.tar.gz.sha256"
