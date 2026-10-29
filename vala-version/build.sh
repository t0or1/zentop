#!/bin/bash
# Compile zentop. Run from this folder.
# Needs: valac libgtk-3-dev libgee-0.8-dev libjson-glib-dev libfontconfig-dev
set -e
cd "$(dirname "$0")"
valac --pkg gtk+-3.0 --pkg posix --pkg gee-0.8 --pkg json-glib-1.0 \
    --Xcc=-D_GNU_SOURCE -X -O2 -X -lm -X -lfontconfig -X -w \
    -o zentop \
    native.vala config.vala proc_reader.vala process_scan.vala resources_data.vala filesystems_data.vala \
    util.vala theme.vala graphs.vala widgets.vala \
    process_feed.vala process_actions.vala tab_processes.vala tab_resources.vala \
    tab_pie.vala tab_filesystems.vala tab_themes.vala window.vala main.vala
echo "Built ./zentop -- run it with: ./zentop"
