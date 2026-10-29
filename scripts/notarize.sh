#!/bin/bash
# Submits a .zip/.dmg/.pkg to Apple's notary service with an App Store Connect API key, waits,
# prints the log on failure, and staples the ticket when the input is stapleable.
#
# Usage: scripts/notarize.sh <file.zip|file.dmg> [path-to-staple]
#   For an app: zip it first (ditto -c -k --keepParent X.app X.zip), pass X.app as path-to-staple.
#   For a DMG: pass the DMG alone; it is stapled in place.
# Env:   ASC_KEY_PATH (AuthKey_XXXX.p8), ASC_KEY_ID, ASC_ISSUER_ID
set -euo pipefail

FILE="${1:?usage: notarize.sh <file> [staple-target]}"
TARGET="${2:-$FILE}"
: "${ASC_KEY_PATH:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
auth=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")

out="$(mktemp)"
xcrun notarytool submit "$FILE" "${auth[@]}" --wait --timeout 30m --output-format json | tee "$out"
id="$(plutil -extract id raw -o - "$out" 2>/dev/null || true)"
status="$(plutil -extract status raw -o - "$out" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
  echo "notarization status: ${status:-unknown}" >&2
  [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" >&2 || true
  exit 1
fi
[[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" || true   # shows warnings, if any

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
