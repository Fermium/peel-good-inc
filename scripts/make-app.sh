#!/bin/zsh
# Builds "Peel Good Inc.app" (menu bar only) into ./build and signs it ad hoc.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product PeelGoodApp
swift build -c release --product peel-good-mcp
swift build -c release --product peelgood
app="build/Peel Good Inc.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/completions" "$app/Contents/Helpers"
cp .build/release/PeelGoodApp "$app/Contents/MacOS/PeelGood"
cp .build/release/peel-good-mcp "$app/Contents/MacOS/peel-good-mcp"
# The CLI goes to Contents/Helpers: "peelgood" and "PeelGood" collide on case-insensitive APFS.
cp .build/release/peelgood "$app/Contents/Helpers/peelgood"
# Man page and shell completions, generated from the CLI's own description of itself.
.build/release/peelgood man-page --release 0.1 > "$app/Contents/Resources/peelgood.1"
.build/release/peelgood completions zsh > "$app/Contents/Resources/completions/_peelgood"
.build/release/peelgood completions bash > "$app/Contents/Resources/completions/peelgood.bash"
.build/release/peelgood completions fish > "$app/Contents/Resources/completions/peelgood.fish"
cp Resources/*.wav Resources/PeelGood.icns docs/brand/icon.svg docs/brand/logo-light.png docs/brand/logo-dark.png LICENSE "$app/Contents/Resources/"
python3 scripts/make-sbom.py "$(git describe --tags --always 2>/dev/null || echo dev)" "$app/Contents/Resources/sbom.cdx.json"

# Share extension ("Peel Good Inc." in Share menus), built directly: SwiftPM can't make .appex bundles.
appex="$app/Contents/PlugIns/PeelGoodShare.appex"
mkdir -p "$appex/Contents/MacOS"
swiftc -O -parse-as-library -application-extension -module-name PeelGoodShare \
    -target "$(uname -m)-apple-macos15.0" -Xlinker -e -Xlinker _NSExtensionMain \
    Extensions/Share/ShareViewController.swift Sources/PeelGoodShared/AppIdentity.swift -o "$appex/Contents/MacOS/PeelGoodShare"

source scripts/info-plists.sh
write_info_plists "$app/Contents" "$appex/Contents"

codesign --force --sign - --entitlements Extensions/Share/Share.entitlements "$appex"
codesign --force --sign - "$app/Contents/MacOS/peel-good-mcp"
codesign --force --sign - --identifier com.fermium.peelgood.cli "$app/Contents/Helpers/peelgood"
codesign --force --sign - "$app"
pluginkit -a "$appex" || true
# Register Open With, the "Print as Label" service and the document types.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
/System/Library/CoreServices/pbs -update
echo "built $app"
