cask "peel-good-inc" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/fermium/peel-good-inc/releases/download/v#{version}/PeelGoodInc-#{version}.dmg"
  name "Peel Good Inc."
  desc "Menu bar app that prints any PDF, SVG or image as a thermal printer label"
  homepage "https://github.com/fermium/peel-good-inc"

  livecheck do
    url :url
    strategy :github_latest
  
  caveats <<~EOS
    Peel Good Inc. isn't notarized by Apple yet. This cask removes the quarantine
    flag after installing so the app opens normally.
  EOS
end

  depends_on macos: :sequoia

  app "Peel Good Inc.app"
  # CLI shipped inside the app bundle (Contents/Helpers avoids a case clash with Contents/MacOS/Labelize).
  # The `labelize` command keeps its name.
  binary "#{appdir}/Peel Good Inc.app/Contents/Helpers/labelize"

  # Not notarized yet: clear the quarantine flag so Gatekeeper lets the ad hoc signed app open.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Peel Good Inc.app"]
  
  caveats <<~EOS
    Peel Good Inc. isn't notarized by Apple yet. This cask removes the quarantine
    flag after installing so the app opens normally.
  EOS
end

  uninstall quit: "com.fermiumlabs.labelize"

  zap trash: [
    "~/Library/Application Support/Labelize",
    "~/Library/Caches/com.fermiumlabs.labelize",
    "~/Library/HTTPStorages/com.fermiumlabs.labelize",
    "~/Library/Logs/Labelize",
    "~/Library/Preferences/com.fermiumlabs.labelize.plist",
    "~/Library/Saved Application State/com.fermiumlabs.labelize.savedState",
  ]

  caveats <<~EOS
    Peel Good Inc. isn't notarized by Apple yet. This cask removes the quarantine
    flag after installing so the app opens normally.
  EOS
end
