#!/bin/bash
# Packs a (signed, ideally already stapled) .app into a compressed DMG with an
# /Applications symlink, then signs the DMG. Uses only hdiutil (no create-dmg/dmgbuild deps).
#
# Usage: scripts/make-dmg.sh "<path/to/Peel Good Inc.app>" <out.dmg> [volume name]
# Env:   SIGN_IDENTITY  Developer ID Application identity; "-" or empty = leave DMG unsigned
#        KEYCHAIN       optional keychain for codesign
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <out.dmg> [volname]}"
DMG="${2:?usage: make-dmg.sh <app> <out.dmg> [volname]}"
VOLNAME="${3:-Peel Good Inc.}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

[[ -d "$APP" ]] || { echo "no such app: $APP" >&2; exit 1; }
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"      # ditto keeps signatures, xattrs, stapled tickets
ln -s /Applications "$STAGE/Applications"

# hdiutil is occasionally flaky on CI ("Resource busy"); retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
       -format UDZO -imagekey zlib-level=9 -ov "$DMG"; then
    break
  fi
  [[ $attempt == 5 ]] && { echo "hdiutil failed" >&2; exit 1; }
  echo "hdiutil failed (attempt $attempt), retrying..." >&2
  sleep $((attempt * 3))
done

if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  kc=()
  [[ -n "${KEYCHAIN:-}" ]] && kc=(--keychain "$KEYCHAIN")
  codesign --force --sign "$SIGN_IDENTITY" --timestamp ${kc[@]+"${kc[@]}"} "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

hdiutil verify "$DMG"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
