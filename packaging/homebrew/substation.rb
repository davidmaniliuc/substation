# Template for the cask published to davidmaniliuc/homebrew-tap as
# Casks/substation.rb. The release workflow fills in @VERSION@ and @SHA256@
# and pushes the result; edit THIS file, never the tap's copy, or the next
# release overwrites the change.
cask "substation" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/davidmaniliuc/substation/releases/download/v#{version}/Substation-#{version}.dmg"
  name "Substation"
  desc "PlayStation emulator (alpha)"
  homepage "https://github.com/davidmaniliuc/substation"

  livecheck do
    url :url
    strategy :github_releases
  end

  # The Zig core is built for the host architecture only and the recompiler
  # emits arm64; the app's deployment target is macOS 26.
  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Substation.app"

  # The app is ad-hoc signed, not notarized, so Gatekeeper refuses to open a
  # quarantined copy. Drop this block once releases are signed with a
  # Developer ID and notarized (docs/RELEASING.md).
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Substation.app"]
  end

  zap trash: [
    "~/Library/Application Support/Substation",
    "~/Library/Preferences/dev.substation.app.plist",
    "~/Library/Saved Application State/dev.substation.app.savedState",
  ]

  caveats <<~EOS
    Substation is ALPHA software: expect crashes, missing features and
    resume states that a later release may not load.

    No BIOS is included. Point the app at a folder holding your own
    PlayStation BIOS dump on first launch.

    `brew uninstall --zap substation` also deletes your memory cards and
    resume states.
  EOS
end
