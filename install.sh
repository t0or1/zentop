#!/bin/bash
# Installs zentop for the current user: no root needed.
#   bash install.sh              build if needed, install, add the menu entry
#   bash install.sh --uninstall  remove all of it (settings in ~/.config stay)
set -e
cd "$(dirname "$0")"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST="$DATA/zentop"
BIN="$HOME/.local/bin/zentop"
DESKTOP="$DATA/applications/zentop.desktop"

if [ "$1" = "--uninstall" ]; then
    rm -rf "$DEST" "$BIN" "$DESKTOP"
    echo "zentop removed."
    exit 0
fi

[ -x ./zentop ] || bash build.sh
mkdir -p "$DEST" "$(dirname "$BIN")" "$(dirname "$DESKTOP")"
install -m 755 zentop "$DEST/zentop"
rm -rf "$DEST/themes" "$DEST/fonts"
cp -r themes fonts "$DEST/"
ln -sf "$DEST/zentop" "$BIN"
cat > "$DESKTOP" << DESK
[Desktop Entry]
Type=Application
Name=zentop
GenericName=System Monitor
Comment=Processes, resources, power, temperatures and disks
Exec=$DEST/zentop
Icon=utilities-system-monitor
Categories=System;Monitor;GTK;
Keywords=task;process;cpu;memory;temperature;power;
Terminal=false
StartupNotify=true
DESK
echo "Installed in $DEST"
echo "Run it from your app menu, or with: zentop  (needs ~/.local/bin in PATH)"
