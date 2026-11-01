# Sourced (not run) by make-app.sh (zsh) and release-build.sh (bash): plain POSIX-style shell only.
# The app's and the Share extension's Info.plist, written once for both builds: make-app.sh (development)
# and release-build.sh. Source it, then call write_info_plists with the two Contents folders.
# Reads APP_NAME, BUNDLE_ID, VERSION, BUILD_NUMBER and MIN_OS (defaults are the development values).

write_info_plists() {
  local APP_CONTENTS="$1" APPEX_CONTENTS="$2"
  local APP_NAME="${APP_NAME:-Peel Good Inc.}" BUNDLE_ID="${BUNDLE_ID:-com.fermium.peelgood}"
  local VERSION="${VERSION:-0.1}" BUILD_NUMBER="${BUILD_NUMBER:-1}" MIN_OS="${MIN_OS:-15.0}"

  cat > "$APPEX_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PeelGoodShare</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID.share</string>
    <key>CFBundleExecutable</key><string>PeelGoodShare</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
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

  cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>PeelGood</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Fermium LABS</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Peel Good Inc. looks for Zebra label printers on your network and prints to them directly.</string>
    <key>CFBundleIconFile</key><string>PeelGood</string>
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
            <key>NSPortName</key><string>PeelGood</string>
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

  plutil -lint "$APP_CONTENTS/Info.plist" "$APPEX_CONTENTS/Info.plist" >/dev/null
}
