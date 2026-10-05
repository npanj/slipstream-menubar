#!/bin/sh
#
# Slipstream Menubar installer for Apple Silicon Macs.
#
#   curl -fsSL https://github.com/npanj/slipstream-menubar/raw/main/install.sh | sh
#
# Downloads the app from a GitHub release, verifies it against the release's
# SHA256SUMS.<version>.txt, installs it into /Applications (or ~/Applications when
# /Applications is not writable), clears the quarantine mark so macOS opens it
# without asking (the app is signed ad hoc, not notarized), and starts it. A running
# copy is quit first; a running Slipstream server keeps running. On its first start
# the app sets up Slipstream and a model.
#
# Environment:
#   SLIPSTREAM_MENUBAR_TAG   install this release tag instead of the newest, e.g. v26.10.4
#   SLIPSTREAM_MENUBAR_DIR   the folder the app goes into (default /Applications)
#   SLIPSTREAM_MENUBAR_REPO  owner/repo to install from (default npanj/slipstream-menubar)
#   SLIPSTREAM_MENUBAR_OPEN  0: install without starting the app
#
# POSIX sh, so it runs from a pipe into whatever /bin/sh is.
set -eu

REPO="${SLIPSTREAM_MENUBAR_REPO:-npanj/slipstream-menubar}"
APP_NAME="Slipstream Menubar.app"
BUNDLE_ID="local.slipstream.menubar"

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -eu/p' "$0" 2>/dev/null | sed '$d; s/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

[ "$(uname -s)" = Darwin ] || die "Slipstream Menubar runs on macOS only (this is $(uname -s))"
case "$(uname -m)" in
  arm64|aarch64) ;;
  *) die "Slipstream Menubar needs an Apple Silicon Mac (this CPU is $(uname -m))" ;;
esac
MACOS=$(sw_vers -productVersion)
[ "${MACOS%%.*}" -ge 15 ] || die "Slipstream Menubar needs macOS 15 or later (this is $MACOS)"
need curl
need ditto
need shasum
need awk
info "Detected macOS $MACOS on Apple Silicon"

# The asset names carry the version, so the newest release's tag is looked up.
if [ -n "${SLIPSTREAM_MENUBAR_TAG:-}" ]; then
  TAG="$SLIPSTREAM_MENUBAR_TAG"
else
  TAG=$(curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1) \
    || die "could not look up the latest release of $REPO"
  [ -n "$TAG" ] || die "$REPO has no published release"
fi
VERSION="${TAG#v}"
ZIP="Slipstream-Menubar.app.$VERSION.zip"
SUMS="SHA256SUMS.$VERSION.txt"
BASE="https://github.com/$REPO/releases/download/$TAG"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

info "Downloading Slipstream Menubar $VERSION"
curl -fsSL --retry 3 -o "$TMP/$SUMS" "$BASE/$SUMS" || die "could not download $SUMS from release $TAG of $REPO"
curl -fL --retry 3 --progress-bar -o "$TMP/$ZIP" "$BASE/$ZIP" || die "could not download $ZIP"

info "Verifying checksum"
EXPECTED=$(awk -v name="$ZIP" '$2 == name { print $1 }' "$TMP/$SUMS")
[ -n "$EXPECTED" ] || die "$SUMS lists no checksum for $ZIP"
ACTUAL=$(shasum -a 256 "$TMP/$ZIP" | awk '{ print $1 }')
[ "$ACTUAL" = "$EXPECTED" ] || die "checksum mismatch for $ZIP
  expected: $EXPECTED
  actual:   $ACTUAL"

ditto -x -k "$TMP/$ZIP" "$TMP/unpacked" || die "could not unpack $ZIP"
[ -d "$TMP/unpacked/$APP_NAME" ] || die "$ZIP does not contain $APP_NAME"

# /Applications is writable for administrators; others get ~/Applications.
DIR="${SLIPSTREAM_MENUBAR_DIR:-/Applications}"
if [ -z "${SLIPSTREAM_MENUBAR_DIR:-}" ] && [ ! -w /Applications ]; then
  DIR="$HOME/Applications"
fi
mkdir -p "$DIR" || die "could not create $DIR"
TARGET="$DIR/$APP_NAME"

# Quit a running copy; the Slipstream server it may have started keeps running.
if pgrep -x SlipstreamMenubar >/dev/null 2>&1; then
  info "Quitting the running Slipstream Menubar"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  i=0
  while pgrep -x SlipstreamMenubar >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
    sleep 0.5
    i=$((i + 1))
  done
  pkill -x SlipstreamMenubar 2>/dev/null || true
fi

info "Installing into $TARGET"
rm -rf "$TARGET"
ditto "$TMP/unpacked/$APP_NAME" "$TARGET" || die "could not copy the app into $DIR"
# Ad hoc signed, not notarized: without this, macOS asks for Open Anyway first.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if [ "${SLIPSTREAM_MENUBAR_OPEN:-1}" != 0 ]; then
  info "Starting Slipstream Menubar"
  open "$TARGET"
  echo "Slipstream Menubar $VERSION is in your menu bar. On its first start it sets up Slipstream and a model."
else
  echo "Slipstream Menubar $VERSION is installed in $TARGET."
fi
