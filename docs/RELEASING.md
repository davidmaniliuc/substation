# Releasing Substation

Substation is **alpha**. Releases exist so people can try it, not because it
is finished, and every release says so.

## Cutting a release

A release is a **tag**. On an up-to-date master:

```sh
tools/release.sh            # the next patch: v0.9.0 first, then v0.9.1, v0.9.2...
tools/release.sh 0.10       # start a new series at v0.10.0
tools/release.sh 1.0.0      # exactly this version
```

The script checks that HEAD is a clean master that GitHub already has, shows
the version, build and commit, and asks before it tags and pushes. Tagging
by hand works the same (`git tag -a v0.9.1 -m "Substation 0.9.1" && git push
origin v0.9.1`); the script only saves picking the number. Pushing a
`vMAJOR.MINOR.PATCH` tag runs `.github/workflows/release.yml`, which, on an
`xcode-27` runner (Xcode 27, the version the app is developed on):

1. refuses a tag that is not `vMAJOR.MINOR.PATCH` or not on master,
2. installs Zig (the version `build.zig.zon` pins) and the Metal toolchain,
3. runs `zig build macos` with the tag's version stamped in,
4. packs `zig-out/Substation.app` into `Substation-<version>.dmg` with
   `ps1-macos/package-dmg.sh`,
5. publishes a GitHub release on the tag carrying the DMG and its `.sha256`,
6. publishes the release to the in-app update feed, if the Sparkle keys are
   stored (below), and
7. bumps the Homebrew cask, if the tap is set up (below).

A pushed tag that fails the build publishes nothing: delete it
(`git push origin :v0.9.1 && git tag -d v0.9.1`), fix master, and tag again.

**Versions.** A release is titled with its version and its commit:
**Substation 0.9.0 (a3f91c2)**. The About window shows three lines:

| Line    | Comes from                                    | Example   |
| ------- | --------------------------------------------- | --------- |
| Version | the tag (`CFBundleShortVersionString`)        | `0.9.0`   |
| Build   | the commit count, `git rev-list --count HEAD` | `1000`    |
| Commit  | the short hash, linked to GitHub              | `a3f91c2` |

The build number (`CFBundleVersion`) is what Sparkle compares, and the commit
count only ever goes up along master, which is why a release tag must be on
master and why master's history must never be rewritten again. The version
has to be three integers: `CFBundleShortVersionString` allows nothing else,
and a version that sorts is what tells Homebrew which build is newer.

`Info.plist` expands `$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)` and
`$(SUBSTATION_COMMIT)`, and `ps1-macos/build.sh` sets them. A local build
keeps the project's `MARKETING_VERSION` (`0.9.0`) and still stamps the build
and the commit, marked `-dirty` for a tree with uncommitted changes; set
`SUBSTATION_VERSION` to override the version. Raise `MARKETING_VERSION` when
a new series starts, so local builds read as the series they belong to.

**Without releasing.** *Actions ▸ Release ▸ Run workflow* builds a DMG named
`Substation-<version>-dev.<build>.dmg` and attaches it to the run as an
artifact. Nothing is tagged or published.

**Locally.** `zig build macos && ps1-macos/package-dmg.sh` writes
`zig-out/Substation-<version>.dmg`.

## The Homebrew tap

The cask lives in the tap, not in this repo: `Casks/substation.rb` in
`davidmaniliuc/homebrew-tap`. Edit it there. On each release the workflow
rewrites only its `version` and `sha256` lines, so everything else in it is
yours and survives every release. One-time setup:

1. Create the public repo **`davidmaniliuc/homebrew-tap`** (the `homebrew-`
   prefix is what makes `brew tap davidmaniliuc/tap` find it).
2. Commit the cask to it as **`Casks/substation.rb`**. Its `version` and
   `sha256` values can be anything to begin with; the first release fills
   them in. The job fails, rather than skipping, if the file is missing.
3. Create a fine-grained personal access token with **Contents: Read and
   write** on that repo only.
4. Store it in this repo as the Actions secret **`HOMEBREW_TAP_TOKEN`**.
5. Once in-app updates are on, add **`auto_updates true`** to the cask (as
   WhatsApp's has). It tells Homebrew the app updates itself, so
   `brew upgrade` leaves it alone instead of fighting Sparkle over it.

Until the secret exists the `homebrew` job is skipped, not failed. Users then
install with:

```sh
brew install --cask davidmaniliuc/tap/substation
```

## In-app updates (Sparkle)

The app updates itself through [Sparkle](https://sparkle-project.org), the
framework most Mac apps outside the App Store use, added as a Swift package
(pinned in `PS1.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`).
It checks automatically, once a day, from the first launch
(`SUEnableAutomaticChecks`, so Sparkle never asks first), and *Substation ▸
Check for Updates…* checks by hand. A found update is SHOWN, not installed:
Sparkle's window offers Install and a checkbox to download and install future
updates on its own (`SUAutomaticallyUpdate`, left to the player).

**How it fits together.** The release workflow signs the DMG with an EdDSA
private key and writes a one-item feed, `appcast.xml`, to the orphan
**`appcast`** branch, which the app reads from
`raw.githubusercontent.com/davidmaniliuc/substation/appcast/appcast.xml`
(`SUFeedURL`). The app carries the matching public key (`SUPublicEDKey`) and
installs only an update that key verifies. Sparkle compares the feed's
`sparkle:version`, the build number (the commit count), with the installed
`CFBundleVersion`. No Apple certificate is involved: Sparkle accepts an
ad-hoc-signed update whose identity differs from the installed copy's
because its EdDSA signature validated, and it clears the quarantine flag on
what it installs.

**Only release builds update themselves.** The public key reaches the app
through `build.sh` only when the workflow sets it, so a local build has none,
never starts Sparkle and has no *Check for Updates…* item: a dev build never
offers to replace itself with the latest release.

**One-time setup**, on your Mac:

1. Download Sparkle's tools (`Sparkle-<version>.tar.xz` from
   [its releases](https://github.com/sparkle-project/Sparkle/releases)) and
   run **`./bin/generate_keys`**. It stores the private key in your login
   keychain and prints the public key.
2. Store the public key in this repo as the Actions **variable**
   (not secret) **`SPARKLE_PUBLIC_ED_KEY`**.
3. Run **`./bin/generate_keys -x sparkle_private_key`**, store that file's
   contents as the Actions **secret** **`SPARKLE_PRIVATE_KEY`**, then delete
   the file.

The workflow checks that the two halves match before it builds anything.
With neither stored it builds an app without updates and says so; with only
one stored it fails.

**Never lose the private key, and never change it.** Every installed copy
trusts only the key it shipped with: a release signed with another key is
rejected, and those users can only update by downloading a new DMG by hand.
It is in your keychain; keep a copy somewhere safe as well.

## Signing and Gatekeeper

The app is **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`) and **not
notarized**. That is enough to run on Apple silicon, but macOS refuses to open
a downloaded copy: the user must click *Open Anyway* in System Settings ▸
Privacy & Security, or strip the quarantine attribute. The release notes say
so. The tap's cask strips it in a `postflight` block, the same bypass AeroSpace's
cask uses, so a Homebrew install opens with no prompt; the README and the
cask's caveats disclose this. The block runs with `must_succeed: false`,
because the attribute is absent after `--no-quarantine` or a reinstall and a
failing `xattr` would otherwise fail the install.

Proper distribution needs an Apple Developer Program membership. When there is
one, the work is:

- sign with a **Developer ID Application** certificate, with the hardened
  runtime on (`ENABLE_HARDENED_RUNTIME = YES`);
- add an entitlements file carrying **`com.apple.security.cs.allow-jit`**: the
  recompiler maps its code buffer `MAP_JIT`, which the hardened runtime
  refuses without it;
- notarize the DMG (`xcrun notarytool submit --wait`) and staple it
  (`xcrun stapler staple`), with the certificate and an app-specific password
  stored as Actions secrets;
- delete the cask's `postflight` quarantine strip and the release notes'
  *Open Anyway* paragraph.

## Not done (yet)

- **The official `homebrew/cask` repo**, which requires a notarized app and a
  project with some traction.
