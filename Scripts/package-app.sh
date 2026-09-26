#!/bin/bash
# Builds Shotts.app and prints its path, the only thing on stdout; the build's output goes to
# stderr. CONFIG=release for a release build; the default is a debug build for local work.
# SCRATCH is the build folder (`.build` by default), for builds that must not share one.
#
# Every build, local ones included, is signed with the Developer ID (SIGN names another
# identity; SIGN=- signs ad hoc). Screen Recording permission is granted to a code signature:
# a stable identity keeps one grant across rebuilds, where ad-hoc signatures would ask again
# after every build and pile up entries in System Settings.
set -euo pipefail

scratch="${SCRATCH:-}"
[ -z "$scratch" ] || scratch="$(mkdir -p "$scratch" && cd "$scratch" && pwd)"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
scratch="${scratch:-$root/.build}"

config="${CONFIG:-debug}"
swift build -c "$config" --scratch-path "$scratch" >&2
bin_dir="$(swift build -c "$config" --scratch-path "$scratch" --show-bin-path)"
app="$scratch/Shotts.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Shotts" "$app/Contents/MacOS/Shotts"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
[ ! -f "$root/Support/AppIcon.icns" ] || cp "$root/Support/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

sign="${SIGN:-Developer ID Application: Steve Shreeve (SD6N7Z8P9P)}"
options=()
if [ "$sign" != "-" ]; then options=(--options=runtime); fi
codesign --force --sign "$sign" ${options[@]+"${options[@]}"} --entitlements "$root/Support/Shotts.entitlements" "$app"
codesign --verify --deep --strict "$app"
identifier=$( (codesign -dv "$app" 2>&1 || true) | sed -n 's/^Identifier=//p')
expected=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
[ "$identifier" = "$expected" ] || { echo "error: signed as '$identifier', not $expected" >&2; exit 1; }
echo "$app"
