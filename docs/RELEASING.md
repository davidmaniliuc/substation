# Releasing Substation

Substation is **alpha**. Releases exist so people can try it, not because it
is finished, and every release says so.

## Cutting a release

Releases are cut by hand: **Actions ▸ Release ▸ Run workflow**, on the branch
to release. Nothing is tagged or typed beforehand, and a push never releases
anything. `.github/workflows/release.yml` then, on a `macos-26` runner:

1. installs Zig (the version `build.zig.zon` pins) and the Metal toolchain,
2. runs `zig build macos` with the version stamped in,
3. packs `zig-out/Substation.app` into `Substation-<version>.dmg` with
   `ps1-macos/package-dmg.sh`,
4. tags the commit `v<version>` and publishes a GitHub release carrying the
   DMG and its `.sha256`, and
5. publishes the release to the in-app update feed, if the Sparkle keys are
   stored (below), and
6. bumps the Homebrew cask, if the tap is set up (below).

**Versions.** A release is `SERIES.N`, titled with its commit:
**Substation 0.1.42 (a3f91c2)**. `N` is the workflow's run number, so it only
ever goes up and is never typed; a gap is a run that did not publish.
`SERIES` (`0.1`) and `PRERELEASE` (`true`: every release is a GitHub
pre-release while the app is alpha) sit at the top of the workflow; change
them there by hand when the app moves on. The number rather than the bare
hash is what macOS and Homebrew need: `CFBundleShortVersionString` must be
three integers, and a version that sorts is what tells anyone which of two
builds is newer.

`Info.plist` expands `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`;
the release sets them to `SERIES.N` and `N`. A local build keeps the
project's own values (`0.1.0`, build `1`); set `SUBSTATION_VERSION` /
`SUBSTATION_BUILD` to override them through `ps1-macos/build.sh`.

**Without releasing.** Untick *publish* in the Run workflow dialog: the DMG is
built and attached to the run as an artifact, and nothing is tagged.

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
`sparkle:version`, the build number `N`, with the installed
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
