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
  # The CLI lives in Contents/Helpers: "peelgood" and the app's "PeelGood" executable clash on APFS.
  binary "#{appdir}/Peel Good Inc.app/Contents/Helpers/peelgood"
  # The same command under a short name.
  manpage "#{appdir}/Peel Good Inc.app/Contents/Resources/peelgood.1"
  bash_completion "#{appdir}/Peel Good Inc.app/Contents/Resources/completions/peelgood.bash"
  zsh_completion "#{appdir}/Peel Good Inc.app/Contents/Resources/completions/_peelgood"
  fish_completion "#{appdir}/Peel Good Inc.app/Contents/Resources/completions/peelgood.fish"

  # Not notarized yet: clear the quarantine flag so Gatekeeper lets the ad hoc signed app open.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Peel Good Inc.app"],
        writable_paths: ["Peel Good Inc.app"],
        writable_base:  :appdir
  end

  # com.fermiumlabs.labelize and the Labelize folders: the old name, from before the rename.
  uninstall quit: [
    "com.fermium.peelgood",
    "com.fermiumlabs.labelize", # old name
  ]

  zap trash: [
    "~/Library/Application Support/Labelize", # old name
    "~/Library/Application Support/Peel Good",
    "~/Library/Caches/com.fermium.peelgood",
    "~/Library/Caches/com.fermiumlabs.labelize", # old name
    "~/Library/HTTPStorages/com.fermium.peelgood",
    "~/Library/HTTPStorages/com.fermiumlabs.labelize", # old name
    "~/Library/Logs/Labelize", # old name
    "~/Library/Logs/Peel Good",
    "~/Library/Preferences/com.fermium.peelgood.plist",
    "~/Library/Preferences/com.fermiumlabs.labelize.plist", # old name
    "~/Library/Saved Application State/com.fermium.peelgood.savedState",
    "~/Library/Saved Application State/com.fermiumlabs.labelize.savedState", # old name
  ]

  caveats <<~EOS
    Peel Good Inc. isn't notarized by Apple yet. This cask removes the quarantine
    flag after installing so the app opens normally.
  EOS
end
