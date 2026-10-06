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
5. bumps the Homebrew cask, if the tap is set up (below).

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

Until the secret exists the `homebrew` job is skipped, not failed. Users then
install with:

```sh
brew install --cask davidmaniliuc/tap/substation
```

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

- **Intel Macs.** The Zig archives are built for the host only and the JIT is
  arm64; a universal app needs two `zig build` runs and a `lipo`.
- **In-app updates** (Sparkle). Homebrew users get `brew upgrade`; DMG users
  re-download.
- **The official `homebrew/cask` repo**, which requires a notarized app and a
  project with some traction.
