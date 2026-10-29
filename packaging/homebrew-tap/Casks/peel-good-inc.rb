cask "peel-good-inc" do
  version "0.1.0"
  sha256 "de601464c8e26562751b1f35005c849266a7bf5b4abfadecc4fed5da489d78c0"

  url "https://github.com/fermium/peel-good-inc/releases/download/v#{version}/PeelGoodInc-#{version}.dmg"
  name "Peel Good Inc."
  desc "Menu bar app that prints any PDF, SVG or image as a thermal printer label"
  homepage "https://github.com/fermium/peel-good-inc"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Peel Good Inc.app"
  # The CLI lives in Contents/Helpers: "labelize" and the app's "Labelize" executable clash on APFS.
  binary "#{appdir}/Peel Good Inc.app/Contents/Helpers/labelize"

  # Not notarized yet: clear the quarantine flag so Gatekeeper lets the ad hoc signed app open.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Peel Good Inc.app"],
        writable_paths: ["Peel Good Inc.app"],
        writable_base:  :appdir
  end

  uninstall quit: "com.fermiumlabs.labelize"

  zap trash: [
    "~/Library/Application Support/Labelize",
    "~/Library/Application Support/Peel Good",
    "~/Library/Caches/com.fermiumlabs.labelize",
    "~/Library/HTTPStorages/com.fermiumlabs.labelize",
    "~/Library/Logs/Labelize",
    "~/Library/Logs/Peel Good",
    "~/Library/Preferences/com.fermiumlabs.labelize.plist",
    "~/Library/Saved Application State/com.fermiumlabs.labelize.savedState",
  ]

  caveats <<~EOS
    Peel Good Inc. isn't notarized by Apple yet. This cask removes the quarantine
    flag after installing so the app opens normally.
  EOS
end
