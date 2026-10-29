#!/bin/bash
# Compile zentop. Run from the project root (same folder as this script).
set -e
valac --pkg gtk+-3.0 --pkg posix --pkg gee-0.8 --pkg glib-2.0 --pkg gio-2.0 --pkg json-glib-1.0 \
    --Xcc=-D_GNU_SOURCE -X -lm \
    -o zentop src/process_scan.vala src/config.vala src/native.vala src/main.vala
echo "Built ./zentop -- run it with: ./zentop"
