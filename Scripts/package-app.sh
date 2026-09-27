#!/bin/bash
# Builds Shotts.app and prints its path, the only thing on stdout; the build's output goes to
# stderr. CONFIG=release for a release build; the default is a debug build for local work.
# SCRATCH is the build folder (`.build` by default), for builds that must not share one.
#
# Every build, local ones included, is signed with the Developer ID (SIGN names another
# identity; SIGN=- signs ad hoc). Screen Recording permission is granted to a code signature:
# a stable identity keeps one grant across rebuilds, where ad-hoc signatures would ask again
# after every build and pile up entries in System Settings. A release build also signs with a
# secure timestamp, which notarization requires and which needs the network.
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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/Shotts" "$app/Contents/MacOS/Shotts"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$root/Support/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# Open Sans and its license; ATSApplicationFontsPath in Info.plist makes it Shotts' own font.
cp -R "$root/Support/Fonts" "$app/Contents/Resources/Fonts"

# Sparkle is a binary framework. SwiftPM links it from the build directory, so the app needs
# its own copy and an rpath that finds it.
sparkle="$(find "$scratch/artifacts" -type d -name Sparkle.framework -path '*macos-arm64*' 2>/dev/null | head -1)"
[ -n "$sparkle" ] || { echo "error: no Sparkle.framework for macos-arm64 under $scratch/artifacts" >&2; exit 1; }
cp -R "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Shotts"

# Every piece is signed with the same identity, inner components first, with the hardened
# runtime for a real identity (ad-hoc signatures cannot use it: library validation refuses a
# framework from no team).
sign="${SIGN:-Developer ID Application: Steve Shreeve (SD6N7Z8P9P)}"
options=()
if [ "$sign" != "-" ]; then options=(--options=runtime); fi
if [ "$sign" != "-" ] && [ "$config" = release ]; then options+=(--timestamp); fi
framework="$app/Contents/Frameworks/Sparkle.framework"
resign() { codesign --force --sign "$sign" ${options[@]+"${options[@]}"} "$@"; }
resign "$framework/Versions/B/XPCServices/Installer.xpc"
resign --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
resign "$framework/Versions/B/Autoupdate"
resign "$framework/Versions/B/Updater.app"
resign "$framework"
resign "$app"
codesign --verify --deep --strict "$app"
identifier=$( (codesign -dv "$app" 2>&1 || true) | sed -n 's/^Identifier=//p')
expected=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
[ "$identifier" = "$expected" ] || { echo "error: signed as '$identifier', not $expected" >&2; exit 1; }
echo "$app"
