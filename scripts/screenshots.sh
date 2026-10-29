#!/bin/zsh
# Renders every Labelize window and popover, light and dark at 2x, into a folder (default ./screenshots).
# Runs offscreen: no Screen Recording permission, nothing shown, no focus taken, nothing printed.
# Settings, history and the log come from a throwaway home, so personal data stays out of the images.
set -euo pipefail
cd "${0:A:h}/.."
out="${1:-screenshots}"
mkdir -p "$out"
out="${out:A}"
# Plain build, no make-app.sh: that also registers the app and Share extension with LaunchServices.
swift build -c release --product LabelizeApp
home=$(mktemp -d /tmp/labelize-shots-home.XXXXXX)
trap 'rm -rf "$home"' EXIT
CFFIXED_USER_HOME="$home" .build/release/LabelizeApp -screenshots "$out"
