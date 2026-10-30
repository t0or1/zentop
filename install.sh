#!/bin/bash
# Installs zentop for the current user: no root needed.
#   bash install.sh                build if needed, install, add the menu entry
#   bash install.sh --uninstall    remove all of it (settings in ~/.config stay)
#   bash install.sh --rapl         let your user read the RAPL power counters
#                                  (CPU package, cores, DRAM); asks for sudo once
#   bash install.sh --remove-rapl  undo --rapl
set -e
cd "$(dirname "$0")"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST="$DATA/zentop"
BIN="$HOME/.local/bin/zentop"
DESKTOP="$DATA/applications/zentop.desktop"
RULE=/etc/udev/rules.d/70-zentop-rapl.rules
ME="${SUDO_USER:-$USER}"

# Since 2020 (the PLATYPUS side-channel fix) the kernel makes RAPL energy
# counters root-only. This udev rule hands them to a "rapl" group at every
# boot and adds you to it: readable by you, still not by everyone.
if [ "$1" = "--rapl" ]; then
    getent group rapl >/dev/null || sudo groupadd --system rapl
    sudo usermod -aG rapl "$ME"
    sudo tee "$RULE" >/dev/null << 'RULES'
# zentop: let the "rapl" group read the RAPL energy counters (root-only by default)
ACTION=="add", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*|intel-rapl-mmio:*", RUN+="/usr/bin/chgrp rapl /sys%p/energy_uj", RUN+="/usr/bin/chmod g+r /sys%p/energy_uj"
RULES
    # an older hand-made rule doing the same thing would only duplicate this one
    if [ -f /etc/udev/rules.d/70-intel-rapl.rules ] && grep -q "chgrp rapl" /etc/udev/rules.d/70-intel-rapl.rules; then
        sudo rm /etc/udev/rules.d/70-intel-rapl.rules
        echo "Replaced /etc/udev/rules.d/70-intel-rapl.rules with $RULE."
    fi
    # apply now, without a reboot (if udev isn't running, the next boot applies it)
    if sudo udevadm control --reload 2>/dev/null && \
       sudo udevadm trigger --subsystem-match=powercap --action=add 2>/dev/null; then
        echo "RAPL is readable by the rapl group, and $ME is in it."
        echo "Log out and back in once, so your session picks up the group."
    else
        echo "Rule installed and $ME added to the rapl group. Reboot once to apply it."
    fi
    exit 0
fi

if [ "$1" = "--remove-rapl" ]; then
    sudo rm -f "$RULE"
    sudo gpasswd -d "$ME" rapl 2>/dev/null || true
    sudo udevadm control --reload 2>/dev/null || true
    echo "RAPL access removed; the counters go back to root-only at the next reboot."
    exit 0
fi

if [ "$1" = "--uninstall" ]; then
    rm -rf "$DEST" "$BIN" "$DESKTOP"
    echo "zentop removed."
    [ -f "$RULE" ] && echo "RAPL access is still set up; undo it with: bash install.sh --remove-rapl"
    exit 0
fi

# a release package ships the binary; a source checkout builds it
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
echo "Installed zentop $("$DEST/zentop" --version | cut -d' ' -f2) in $DEST"
echo "Run it from your app menu, or with: zentop  (needs ~/.local/bin in PATH)"

# RAPL counters present but root-only, and not set up yet: offer it once.
# Only when someone is at the keyboard; scripts and pipes just get the tip.
rapl_locked=false
for f in /sys/class/powercap/intel-rapl:*/energy_uj; do
    [ -e "$f" ] && [ ! -r "$f" ] && rapl_locked=true && break
done
if $rapl_locked && [ ! -f "$RULE" ]; then
    if [ -t 0 ]; then
        echo
        echo "CPU power readings (RAPL) are root-only on this kernel."
        read -r -p "Let your user read them? Asks for sudo once. [y/N] " answer
        case "$answer" in
            [yY]*) exec bash "$0" --rapl ;;
            *) echo "Skipped. You can do it later with: bash install.sh --rapl" ;;
        esac
    else
        echo "Tip: bash install.sh --rapl lets zentop show CPU power (RAPL) without sudo."
    fi
fi
