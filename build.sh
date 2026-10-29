#!/bin/bash
# Compile zentop into ./zentop. Run from anywhere.
# Needs: valac libgtk-3-dev libgee-0.8-dev libjson-glib-dev libfontconfig-dev
set -e
cd "$(dirname "$0")"
valac --pkg gtk+-3.0 --pkg posix --pkg gee-0.8 --pkg json-glib-1.0 --pkg gmodule-2.0 \
    --Xcc=-D_GNU_SOURCE -X -O2 -X -lm -X -lfontconfig -X -w \
    -o zentop src/*.vala
echo "Built ./zentop -- run it with ./zentop, or install it with: bash install.sh"
