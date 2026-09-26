#!/bin/bash
# Regenerates Support/AppIcon.icns. There is no artwork file: Scripts/lib/render-app-icon.swift
# draws the icon with AppKit (the menu bar's camera.viewfinder symbol on a gradient tile, with
# a glass lens) into an iconset, and iconutil packs it. Run it after changing the renderer and
# commit the .icns with it; package-app.sh only copies the file. LENS=cool draws a blue lens
# instead of the warm one.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/shotts-app-icon.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

iconset="$scratch/AppIcon.iconset"
mkdir "$iconset"
swift "$root/Scripts/lib/render-app-icon.swift" "$iconset"
iconutil -c icns -o "$root/Support/AppIcon.icns" "$iconset"
echo "wrote $root/Support/AppIcon.icns"
