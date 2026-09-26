#!/bin/bash
# Regenerates Support/AppIcon.icns from the vector master Support/AppIcon.svg:
# Scripts/lib/render-app-icon.swift rasterizes it with AppKit and adds the Dock shadow, and
# iconutil packs the result. Run it after editing the SVG and commit the .icns with it;
# package-app.sh only copies the file.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/shotts-app-icon.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

iconset="$scratch/AppIcon.iconset"
mkdir "$iconset"
swift "$root/Scripts/lib/render-app-icon.swift" "$root/Support/AppIcon.svg" "$iconset"
iconutil -c icns -o "$root/Support/AppIcon.icns" "$iconset"
echo "wrote $root/Support/AppIcon.icns"
