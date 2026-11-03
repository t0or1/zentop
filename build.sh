#!/bin/bash
# Compile zentop into ./zentop. Run from anywhere.
# Needs: valac libgtk-3-dev libgee-0.8-dev libjson-glib-dev libfontconfig-dev
set -eo pipefail   # pipefail: a valac error must fail the build, not tee's exit 0
cd "$(dirname "$0")"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
rm -f zentop      # a failed build must not leave the previous binary looking fresh
valac --pkg gtk+-3.0 --pkg posix --pkg gee-0.8 --pkg json-glib-1.0 --pkg gmodule-2.0 \
    --Xcc=-D_GNU_SOURCE -X -O2 -X -lm -X -lfontconfig -X -w \
    -o zentop src/*.vala 2>&1 | tee "$log"
# valac can print CRITICALs (its own internal errors) and still exit 0;
# treat them as a failed build so they never slip into a release
if grep -q "CRITICAL" "$log"; then
    echo "Build produced valac CRITICAL messages (see above): treating it as failed."
    rm -f zentop
    exit 1
fi
echo "Built ./zentop -- run it with ./zentop, or install it with: bash install.sh"
