# Releasing and updates

Shotts ships as an app signed with a Developer ID and notarized by Apple, installed with Homebrew
from `shreeve/homebrew-tap`, and updated in place through [Sparkle](https://sparkle-project.org),
with GitHub Releases as the only host. There is no server and no CI step. The repository must
stay public: Homebrew and Sparkle download release files without signing in, and `release.sh`
refuses to publish from a private one.

## How it fits together

| Piece | Where | Does |
| --- | --- | --- |
| Install | `shreeve/homebrew-tap` → `Casks/shotts.rb` | `brew install --cask shreeve/tap/shotts` downloads the release's `Shotts-X.Y.Z.zip` into `/Applications`. `auto_updates true` leaves updating to Sparkle; `livecheck` reads the same feed. |
| Build | `Scripts/package-app.sh` | Builds the app (`CONFIG=release` for releases) in `.build` or the folder `SCRATCH` names, embeds Sparkle, signs everything with the Developer ID, inner pieces first (a release build adds a secure timestamp), and prints the app's path, the only thing on stdout. Fails unless the bundle signs as `com.github.shreeve.shotts`. |
| Release | `Scripts/release.sh` | Stamps the version, builds, notarizes and staples, zips, writes and signs the feed with the version's notes from `CHANGELOG.md`, drafts the release, commits, tags, pushes, and publishes; undoes itself when a step fails. |
| Cask | `Scripts/update-cask.sh` | Writes the cask for a published version with the archive's sha256 and opens the tap's pull request. |
| Feed | `appcast.xml` on each release | Sparkle's list of the newest version, its download URL, and its EdDSA signature. |
| App | `Support/Info.plist` | `SUFeedURL` points at the latest release's `appcast.xml`; `SUPublicEDKey` is the key updates must be signed with; `SUEnableAutomaticChecks` makes Sparkle, a SwiftPM dependency, check once a day without asking first. **Check for Updates…** is in the menu bar menu and the app menu. |

Two signatures, for two jobs:

- **Gatekeeper** judges a file marked as downloaded from the internet, as Homebrew marks it, on
  first launch. It accepts an app signed with a Developer ID and notarized: Apple has scanned it
  and issued a ticket, which the release staples into the bundle so the check works offline.
- **Sparkle** accepts an update when its code signature is valid and its EdDSA signature matches
  `SUPublicEDKey`.

Screen Recording permission is granted to a code signature, so a copy installed from a release
keeps its grant across updates, as local builds do across rebuilds: every build signs with the
same Developer ID.

## One-time setup: the Developer ID and notarization

Releases are signed with the Developer ID Application certificate of the individual team
`SD6N7Z8P9P`, the same one local builds use. Only the account holder can create it: Xcode →
Settings → Apple Accounts → the team → Manage Certificates… → + → Developer ID Application.
Its private key lives in the login keychain; to release from another Mac, export the certificate
with its key from Keychain Access and import it there. Check with:

```bash
security find-identity -v -p codesigning   # must list "Developer ID Application: Steve Shreeve (SD6N7Z8P9P)"
```

Notarization signs in through a notarytool keychain profile named `notary-tool`, stored once per
Mac and shared with Transfer and Lyte:

```bash
xcrun notarytool store-credentials notary-tool   # Apple ID, an app-specific password, team SD6N7Z8P9P
xcrun notarytool history --keychain-profile notary-tool
```

## One-time setup: the update signing key

Updates are signed with an ed25519 key of Shotts' own, under the keychain account `shotts`
(Transfer uses the default account and Lyte `lyte`; never mix them, and never delete or export a
key by service alone, which would take all three). The private half lives in the login keychain,
where Sparkle's `generate_keys` created it; the public half is `SUPublicEDKey` in
`Support/Info.plist`. Sparkle's tools are in `.build/artifacts/sparkle/Sparkle/bin` after any
`swift build`.

```bash
bin=.build/artifacts/sparkle/Sparkle/bin
$bin/generate_keys --account shotts -p                    # prints the public key; it must equal SUPublicEDKey
$bin/generate_keys --account shotts -x /tmp/shotts-key    # exports the private key for a backup
$bin/generate_keys --account shotts -f /tmp/shotts-key    # imports it on another Mac
```

Keep a backup of the private key in a password manager, and delete any exported file afterwards.
Never commit it or leave it on disk. Losing it strands every installed copy on its version,
because an app only trusts the key it shipped with. Anyone who has it can sign an update every
installed copy will accept.

## Cutting a release

First turn the `## Unreleased` section of `CHANGELOG.md` into `## X.Y.Z — <date>` and land it:
the section becomes the GitHub release notes and the notes Sparkle shows in the update dialog,
and a release without one is refused. Then, from `main`, clean and in step with `origin/main`:

```bash
Scripts/release.sh X.Y.Z --notes     # prints the notes it would publish, and nothing else
Scripts/release.sh X.Y.Z --dry-run
Scripts/release.sh X.Y.Z
Scripts/update-cask.sh X.Y.Z         # opens the tap's pull request; merge it
```

Versions are `major.minor.patch` and must go up: Sparkle orders updates by `CFBundleVersion`,
which the script sets to the version, as it does `CFBundleShortVersionString`.

The release script:

1. Refuses to run unless the keychain holds the Developer ID, the notary profile signs in, and
   the keychain's `shotts` update key matches `SUPublicEDKey`. A real release also refuses unless
   it is on a clean `main` that matches `origin/main` after a fetch, `gh` is signed in, the repo is
   public, no tag `vX.Y.Z` exists locally or on `origin`, no release for it exists (a draft
   included), the version is higher than the latest `v*` tag, and `CHANGELOG.md` has its section.
2. Writes the version into `Support/Info.plist`. From here on a failure undoes what the run did.
3. Builds with `CONFIG=release Scripts/package-app.sh` and checks the bundle's version.
4. Sends the app to Apple's notary service and waits (usually a few minutes), prints Apple's log
   and stops if it is not accepted, staples the ticket, and checks that Gatekeeper accepts the
   app as Notarized Developer ID.
5. Zips the stapled app with `ditto` as `feed/Shotts-X.Y.Z.zip` under `release-X.Y.Z` in the
   build folder, and puts the notes beside it.
6. Writes `appcast.xml` with Sparkle's `generate_appcast`, signing with the keychain key and
   embedding the notes, and stops if the feed came out unsigned or without notes.
7. Creates the GitHub release as a draft with `Shotts-X.Y.Z.zip` and `appcast.xml`; commits
   `Shotts X.Y.Z`, tags `vX.Y.Z`, pushes `main` and the tag in one atomic push; then publishes
   the draft as the latest release.

A failure before the push deletes the draft, removes the commit and the tag, and puts
`Info.plist` back, leaving the repo as it was. If only publishing the pushed draft fails, the
script prints the `gh release edit … --draft=false --latest --verify-tag` command that finishes it.

`--dry-run` does steps 1 to 6 without the release-only checks, warns instead of refusing a
version that is not higher or has no notes, and puts `Info.plist` back, publishing nothing; it
still submits the app to Apple, which makes nothing public. Look in `.build/release-X.Y.Z/`.

The cask script downloads the published archive, writes `Casks/shotts.rb` with its sha256 in the
tap checkout beside this repo (`TAP` names another), commits it on a branch `shotts-X.Y.Z` from
the tap's `main`, pushes, and opens the pull request. Merge it, and the version is installable.

## Verifying a release

```bash
gh release view vX.Y.Z
curl -fsSL https://github.com/shreeve/shotts/releases/latest/download/appcast.xml | grep sparkle:version
brew update && brew install --cask shreeve/tap/shotts
plutil -extract CFBundleShortVersionString raw /Applications/Shotts.app/Contents/Info.plist
```

The feed must list the new version, and the installed app must report it.

## Testing an update before shipping it

To watch Sparkle update an older build without publishing anything:

1. Dry-run an older version and unzip `.build/release-<old>/feed/Shotts-<old>.zip` somewhere
   with `ditto -x -k`; a dry run is signed and notarized.
2. Dry-run the newer version, put its zip in a folder as `Shotts-<new>.zip`, and write a feed for
   it: `.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account shotts --download-url-prefix http://127.0.0.1:8765/ <folder>`.
3. Serve that folder: `python3 -m http.server 8765 --bind 127.0.0.1`.
4. Point Shotts at it: `defaults write com.github.shreeve.shotts SUFeedURL http://127.0.0.1:8765/appcast.xml`.
   A user default overrides `SUFeedURL` in `Info.plist`.
5. Quit any running Shotts, open the old copy, and choose **Check for Updates…**, then
   **Install Update**. It relaunches as the new version.
6. Clean up: `defaults delete com.github.shreeve.shotts SUFeedURL`, stop the server, delete the folders.

## If something goes wrong

- **The script says the keys do not match.** Compare `generate_keys --account shotts -p` with
  `SUPublicEDKey`; import the right key with `generate_keys --account shotts -f`.
- **Notarization is refused.** The script prints Apple's log, which names each file and the
  problem: usually a piece signed without the hardened runtime or a secure timestamp, or a new
  executable that `package-app.sh` does not sign.
- **A rerun is refused because a release exists.** A run killed before it could clean up may leave
  a draft: `gh release delete vX.Y.Z --repo shreeve/shotts`. A pushed tag whose release is still a
  draft is finished with the command the failed run printed.
- **Installed copies do not see the new version.** The release must be the repo's latest
  (`gh api repos/shreeve/shotts/releases/latest --jq .tag_name`), since `SUFeedURL` reads the
  latest release's feed, and its `CFBundleVersion` must be higher than theirs.
- **A bad release is out.** Publish a fixed, higher version. Sparkle only moves forward; deleting
  a release does not roll anyone back.
