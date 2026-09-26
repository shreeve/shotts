#!/bin/bash
#
# update-cask.sh — point the Homebrew cask at a published release.
#
#   Scripts/update-cask.sh 0.1.0
#
# Writes Casks/shotts.rb in the shreeve/homebrew-tap checkout (TAP names another; the default is
# the tap beside this repo) with the release's archive and its sha256, commits it on a branch
# shotts-<version> from the tap's main, pushes, and opens the pull request. Merging it is the
# last step of a release; `brew install --cask shreeve/tap/shotts` then installs the version.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "error: $*" >&2; exit 1; }

version="${1:?usage: Scripts/update-cask.sh <version>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, not $version"
repo="shreeve/shotts"
tap="${TAP:-$root/../homebrew-tap}"
[ -d "$tap/Casks" ] || fail "no tap checkout at $tap (git clone https://github.com/shreeve/homebrew-tap there, or set TAP)"
url="https://github.com/$repo/releases/download/v$version/Shotts-$version.zip"

# The archive as published, so the sum matches what Homebrew downloads.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/Shotts.zip" "$url" || fail "cannot download $url; is v$version published?"
sha=$(shasum -a 256 "$tmp/Shotts.zip" | cut -d' ' -f1)

cask="$tap/Casks/shotts.rb"
new=1; [ ! -f "$cask" ] || new=0
cat > "$cask" <<CASK
cask "shotts" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/Shotts-#{version}.zip"
  name "Shotts"
  desc "Screenshots with annotations: press a key, select, mark up, paste"
  homepage "https://github.com/$repo"

  livecheck do
    url "https://github.com/$repo/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "Shotts.app"

  zap trash: [
    "~/Library/Application Support/Shotts",
    "~/Library/Caches/com.github.shreeve.shotts",
    "~/Library/HTTPStorages/com.github.shreeve.shotts",
    "~/Library/Preferences/com.github.shreeve.shotts.plist",
  ]
end
CASK

cd "$tap"
[ -z "$(git status --porcelain --untracked-files=no -- . ':!Casks/shotts.rb')" ] || fail "the tap checkout has other changes"
git fetch -q origin main
branch="shotts-$version"
git checkout -q -B "$branch" origin/main
git add Casks/shotts.rb
if [ "$new" = 1 ]; then title="Add shotts $version"; else title="Update shotts to $version"; fi
git commit -q -m "$title"
git push -q -u origin "$branch"
gh pr create --title "$title" --body "Points the cask at https://github.com/$repo/releases/tag/v$version." | tail -1
git checkout -q main
