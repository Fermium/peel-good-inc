#!/bin/bash
# Packs a (signed, ideally already stapled) .app into a compressed DMG with an
# /Applications symlink and a laid-out Finder window (background picture, icon
# positions), then signs the DMG. Uses only hdiutil, osascript/Finder and bless
# (no create-dmg/dmgbuild deps).
#
# The window layout is stored in the volume's .DS_Store, which only Finder writes.
# Finder scripting can fail on headless CI (AppleEvent timeouts, no Automation
# consent); in that case the layout step is skipped with a warning and the DMG is
# still built (plain icon view, same contents). Set DMG_LAYOUT_STRICT=1 to fail
# instead.
#
# Usage: scripts/make-dmg.sh "<path/to/Peel Good Inc.app>" <out.dmg> [volume name]
# Env:   SIGN_IDENTITY      Developer ID Application identity; "-" or empty = leave DMG unsigned
#        KEYCHAIN           optional keychain for codesign
#        DMG_BACKGROUND     background image (default Resources/dmg-background.tiff)
#        DMG_LAYOUT         0 = skip the Finder layout step entirely
#        DMG_LAYOUT_STRICT  1 = fail if the Finder layout step fails
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <out.dmg> [volname]}"
DMG="${2:?usage: make-dmg.sh <app> <out.dmg> [volname]}"
VOLNAME="${3:-Peel Good Inc.}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKGROUND="${DMG_BACKGROUND:-$ROOT/Resources/dmg-background.tiff}"
DMG_LAYOUT="${DMG_LAYOUT:-1}"
DMG_LAYOUT_STRICT="${DMG_LAYOUT_STRICT:-0}"

# Window geometry, in points. Must match docs/brand/dmg-background.svg.
WIN_W=660 WIN_H=400 WIN_X=200 WIN_Y=120
TITLEBAR_H=28          # Finder's bounds include the title bar
ICON_SIZE=128
APP_POS="165, 190"     # icon centers
APPS_POS="495, 190"

[[ -d "$APP" ]] || { echo "no such app: $APP" >&2; exit 1; }
APP_NAME="$(basename "$APP")"
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"

WORK="$(mktemp -d)"
MNT=""
cleanup() {
  if [[ -n "$MNT" && -d "$MNT" ]]; then
    hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

warn() { echo "warning: $*" >&2; }

# Retries a command; hdiutil is occasionally flaky on CI ("Resource busy").
retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    "$@" && return 0
    [[ $attempt == 5 ]] && return 1
    echo "$1 failed (attempt $attempt), retrying..." >&2
    sleep $((attempt * 3))
  done
}

# Runs a command, killing it after N seconds (macOS has no coreutils timeout).
run_with_timeout() {
  local secs=$1; shift
  "$@" &
  local pid=$! watcher rc=0
  ( sleep "$secs" && kill -TERM "$pid" ) 2>/dev/null &
  watcher=$!
  wait "$pid" || rc=$?
  pkill -P "$watcher" 2>/dev/null || true
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# 1. Stage contents.
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME"      # ditto keeps signatures, xattrs, stapled tickets
ln -s /Applications "$STAGE/Applications"
HAVE_BG=0
if [[ "$DMG_LAYOUT" != 0 ]]; then
  if [[ -f "$BACKGROUND" ]]; then
    mkdir -p "$STAGE/.background"
    cp "$BACKGROUND" "$STAGE/.background/background.${BACKGROUND##*.}"
    HAVE_BG=1
  else
    warn "background not found ($BACKGROUND); laying out without it"
  fi
fi

# 2. Read-write image with some headroom for .DS_Store.
RW="$WORK/rw.dmg"
size_mb=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
retry hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
  -format UDRW -size "${size_mb}m" -ov "$RW" >/dev/null \
  || { echo "hdiutil create failed" >&2; exit 1; }

# 3. Finder layout.
layout() {
  local out
  out="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen)" || return 1
  MNT="$(printf '%s\n' "$out" | grep -o '/Volumes/.*$' | head -n 1)"
  [[ -n "$MNT" && -d "$MNT" ]] || { warn "could not find mount point"; return 1; }

  local bg=""
  [[ $HAVE_BG == 1 ]] && bg="$(find "$MNT/.background" -maxdepth 1 -type f | head -n 1)"

  cat > "$WORK/layout.applescript" <<'APPLESCRIPT'
on run argv
  set mnt to item 1 of argv
  set appName to item 2 of argv
  set bgPath to item 3 of argv
  set wx to (item 4 of argv) as integer
  set wy to (item 5 of argv) as integer
  set ww to (item 6 of argv) as integer
  set wh to (item 7 of argv) as integer
  set tb to (item 8 of argv) as integer
  set iconSize to (item 9 of argv) as integer
  set ax to (item 10 of argv) as integer
  set ay to (item 11 of argv) as integer
  set px to (item 12 of argv) as integer
  set py to (item 13 of argv) as integer
  with timeout of 60 seconds
    tell application "Finder"
      set vol to (POSIX file mnt) as alias
      open vol
      set cw to container window of vol
      set current view of cw to icon view
      set toolbar visible of cw to false
      set statusbar visible of cw to false
      set bounds of cw to {wx, wy, wx + ww, wy + wh + tb}
      set opts to icon view options of cw
      set arrangement of opts to not arranged
      set icon size of opts to iconSize
      set text size of opts to 13
      set shows item info of opts to false
      set shows icon preview of opts to true
      if bgPath is not "" then set background picture of opts to ((POSIX file bgPath) as alias)
      set position of item appName of vol to {ax, ay}
      set position of item "Applications" of vol to {px, py}
      close cw
      open vol
      update vol without registering applications
      delay 2
      try
        close (container window of vol)
      on error
        try
          close (every window whose name is (name of vol))
        end try
      end try
    end tell
  end timeout
end run
APPLESCRIPT

  local ok=0 attempt
  for attempt in 1 2 3; do
    if run_with_timeout 90 osascript "$WORK/layout.applescript" "$MNT" "$APP_NAME" "$bg" \
         "$WIN_X" "$WIN_Y" "$WIN_W" "$WIN_H" "$TITLEBAR_H" "$ICON_SIZE" \
         "${APP_POS%%,*}" "${APP_POS##*, }" "${APPS_POS%%,*}" "${APPS_POS##*, }"; then
      ok=1; break
    fi
    warn "Finder layout failed (attempt $attempt)"
    sleep $((attempt * 2))
  done
  [[ $ok == 1 ]] || return 1

  # Finder writes .DS_Store asynchronously.

  for _ in $(seq 1 20); do
    [[ -f "$MNT/.DS_Store" ]] && break
    sleep 0.5
  done
  [[ -f "$MNT/.DS_Store" ]] || { warn "Finder did not write .DS_Store"; return 1; }
  return 0
}

if [[ "$DMG_LAYOUT" != 0 ]]; then
  if ! layout; then
    [[ "$DMG_LAYOUT_STRICT" == 1 ]] && { echo "Finder layout failed (DMG_LAYOUT_STRICT=1)" >&2; exit 1; }
    warn "skipping DMG window layout; the DMG will open in a plain Finder window"
  fi
  if [[ -z "$MNT" ]]; then
    out="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse)"
    MNT="$(printf '%s\n' "$out" | grep -o '/Volumes/.*$' | head -n 1)"
  fi
  # Open the window when mounted (best effort: --openfolder is unsupported on some
  # Apple Silicon setups). Drop Finder/Spotlight litter.
  bless --folder "$MNT" --openfolder "$MNT" >/dev/null 2>&1 \
    || bless --folder "$MNT" >/dev/null 2>&1 || warn "bless failed (ignored)"
  rm -rf "$MNT/.fseventsd" "$MNT/.Trashes" 2>/dev/null || true
  if [[ -d "$MNT/.background" ]] && command -v SetFile >/dev/null; then
    SetFile -a V "$MNT/.background" || true   # dot-dirs are hidden anyway
  fi
  chmod -Rf go-w "$MNT" 2>/dev/null || true
  sync
  retry hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
  MNT=""
fi

# 4. Compress.
retry hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null \
  || { echo "hdiutil convert failed" >&2; exit 1; }

# 5. Sign.
if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  kc=()
  [[ -n "${KEYCHAIN:-}" ]] && kc=(--keychain "$KEYCHAIN")
  codesign --force --sign "$SIGN_IDENTITY" --timestamp ${kc[@]+"${kc[@]}"} "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

hdiutil verify "$DMG"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
