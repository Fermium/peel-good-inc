#!/bin/zsh
# Builds Labelize.app (menu bar only) into ./build and signs it ad hoc.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product LabelizeApp
app="build/Peel Good Inc.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/LabelizeApp "$app/Contents/MacOS/Labelize"
cp Resources/*.wav Resources/Labelize.icns "$app/Contents/Resources/"

# Share extension ("Peel Good Inc." in Share menus), built directly: SwiftPM can't make .appex bundles.
appex="$app/Contents/PlugIns/LabelizeShare.appex"
mkdir -p "$appex/Contents/MacOS"
swiftc -O -parse-as-library -application-extension -module-name LabelizeShare \
    -target "$(uname -m)-apple-macos15.0" -Xlinker -e -Xlinker _NSExtensionMain \
    Extensions/Share/ShareViewController.swift -o "$appex/Contents/MacOS/LabelizeShare"
cat > "$appex/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LabelizeShare</string>
    <key>CFBundleDisplayName</key><string>Peel Good Inc.</string>
    <key>CFBundleIdentifier</key><string>com.fermiumlabs.labelize.share</string>
    <key>CFBundleExecutable</key><string>LabelizeShare</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
        <key>NSExtensionPrincipalClass</key><string>ShareViewController</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>NSExtensionActivationRule</key>
            <dict>
                <key>NSExtensionActivationSupportsFileWithMaxCount</key><integer>20</integer>
                <key>NSExtensionActivationSupportsImageWithMaxCount</key><integer>20</integer>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Peel Good Inc.</string>
    <key>CFBundleDisplayName</key><string>Peel Good Inc.</string>
    <key>CFBundleIdentifier</key><string>com.fermiumlabs.labelize</string>
    <key>CFBundleExecutable</key><string>Labelize</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>Labelize</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Printable label source</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string><string>public.svg-image</string><string>public.image</string></array>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Print as Label</string></dict>
            <key>NSMessage</key><string>printAsLabel</string>
            <key>NSPortName</key><string>Peel Good Inc.</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key>
            <array><string>com.adobe.pdf</string><string>public.svg-image</string><string>public.image</string></array>
            <key>NSSendTypes</key>
            <array><string>com.adobe.pdf</string><string>public.png</string><string>public.tiff</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - --entitlements Extensions/Share/Share.entitlements "$appex"
codesign --force --sign - "$app"
pluginkit -a "$appex" || true
# Register Open With, the "Print as Label" service and the document types.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
/System/Library/CoreServices/pbs -update
echo "built $app"
