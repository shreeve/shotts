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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$app/Contents/Helpers"
cp "$bin_dir/Shotts" "$app/Contents/MacOS/Shotts"
# `shotts`, the command line, which asks the running Shotts to capture. Built as ShottsCLI:
# beside Shotts in the build folder, a file named shotts would be Shotts on a disk that
# ignores case.
cp "$bin_dir/ShottsCLI" "$app/Contents/Helpers/shotts"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$root/Support/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# Open Sans and its license; ATSApplicationFontsPath in Info.plist makes it Shotts' own font.
cp -R "$root/Support/Fonts" "$app/Contents/Resources/Fonts"

# Sparkle is a binary framework. SwiftPM links it from the build directory, so the app needs
# its own copy and an rpath that finds it.
sparkle="$(find "$scratch/artifacts" -type d -name Sparkle.framework -path '*macos-arm64*' 2>/dev/null | head -1)"
[ -n "$sparkle" ] || { echo "error: no Sparkle.framework for macos-arm64 under $scratch/artifacts" >&2; exit 1; }
framework="$app/Contents/Frameworks/Sparkle.framework"
cp -R "$sparkle" "$framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Shotts"
# Sparkle ships universal, with headers for building against it: Shotts runs on Apple silicon
# only and builds against the copy in the build folder, so the app keeps the arm64 slices and
# none of the headers. Its XPC services and translations stay: an update needs them.
for binary in "$framework/Versions/B/Sparkle" "$framework/Versions/B/Autoupdate" \
              "$framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
              "$framework"/Versions/B/XPCServices/*.xpc/Contents/MacOS/*; do
    if lipo -archs "$binary" 2>/dev/null | grep -q x86_64; then lipo -thin arm64 "$binary" -output "$binary"; fi
done
rm -rf "$framework/Headers" "$framework/PrivateHeaders" "$framework/Modules" \
       "$framework/Versions/B/Headers" "$framework/Versions/B/PrivateHeaders" "$framework/Versions/B/Modules"

# A release ships without local symbols, about a third of the binary; the dSYM made first, kept
# beside the app and never shipped, turns a crash log's addresses back into names.
if [ "$config" = release ]; then
    dsymutil "$app/Contents/MacOS/Shotts" -o "$scratch/Shotts.app.dSYM" >&2
    strip -x "$app/Contents/MacOS/Shotts"
    strip -x "$app/Contents/Helpers/shotts"
fi

# Every piece is signed with the same identity, inner components first, with the hardened
# runtime for a real identity (ad-hoc signatures cannot use it: library validation refuses a
# framework from no team).
sign="${SIGN:-Developer ID Application: Steve Shreeve (SD6N7Z8P9P)}"
options=()
if [ "$sign" != "-" ]; then options=(--options=runtime); fi
if [ "$sign" != "-" ] && [ "$config" = release ]; then options+=(--timestamp); fi
resign() { codesign --force --sign "$sign" ${options[@]+"${options[@]}"} "$@"; }
resign "$framework/Versions/B/XPCServices/Installer.xpc"
resign --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
resign "$framework/Versions/B/Autoupdate"
resign "$framework/Versions/B/Updater.app"
resign "$framework"
resign --identifier com.github.shreeve.shotts.cli "$app/Contents/Helpers/shotts"
# The hardened runtime keeps the microphone from an app that does not claim it; the
# entitlement is the claim, and macOS still asks the user the first time.
resign --entitlements "$root/Support/Shotts.entitlements" "$app"
codesign --verify --deep --strict "$app"
identifier=$( (codesign -dv "$app" 2>&1 || true) | sed -n 's/^Identifier=//p')
expected=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
[ "$identifier" = "$expected" ] || { echo "error: signed as '$identifier', not $expected" >&2; exit 1; }
echo "$app"
