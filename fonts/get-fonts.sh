#!/bin/sh
# Downloads the four Inter weights zentop uses (SIL OFL 1.1) into this folder.
# Without them zentop falls back to Noto Sans / Ubuntu.
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/inter.zip" https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip
for w in Regular SemiBold Bold ExtraBold; do
    unzip -jo "$TMP/inter.zip" "extras/otf/Inter-$w.otf" -d .
done
unzip -jo "$TMP/inter.zip" LICENSE.txt -d . && mv -f LICENSE.txt OFL.txt
rm -rf "$TMP"
echo "Inter installed in $(pwd)"
