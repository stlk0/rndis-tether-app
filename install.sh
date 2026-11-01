#!/bin/sh
# Installs or updates RNDIS Tether from the latest GitHub release:
#   /bin/sh -c "$(curl -fsSL https://raw.githubusercontent.com/stlk0/rndis-tether-app/main/install.sh)"
# Downloads one archive (the app for Apple silicon and Intel, with rndis-tether inside), checks
# its SHA-256, puts the app in Applications and opens it. The app then installs its background
# service behind the macOS password dialog. RNDIS_TETHER_APP_BASE replaces the download address.
set -eu

REPO=stlk0/rndis-tether-app
BASE=${RNDIS_TETHER_APP_BASE:-https://github.com/$REPO/releases/latest/download}
ARCHIVE=rndis-tether-app-macos.tar.gz
APP="RNDIS Tether.app"

major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$major" -lt 13 ]; then
    echo "RNDIS Tether needs macOS 13 Ventura or newer (this Mac has $(sw_vers -productVersion))." >&2
    exit 1
fi

# Applications when this account may write there (administrators), otherwise the user's own.
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading RNDIS Tether ..."
curl -fsSL "$BASE/$ARCHIVE" -o "$TMP/$ARCHIVE"
curl -fsSL "$BASE/$ARCHIVE.sha256" -o "$TMP/$ARCHIVE.sha256"
(cd "$TMP" && shasum -a 256 -c "$ARCHIVE.sha256" > /dev/null) || {
    echo "The download is damaged (checksum mismatch). Please try again." >&2
    exit 1
}
mkdir "$TMP/new"
tar -xzf "$TMP/$ARCHIVE" -C "$TMP/new"

# A running copy restarts into the new version by itself within a minute, as after brew upgrade.
running=no
pgrep -qf "$DEST/$APP/Contents/MacOS/" && running=yes
[ -e "$DEST/$APP" ] && mv "$DEST/$APP" "$TMP/old.app"
mv "$TMP/new/$APP" "$DEST/"
echo "Installed $DEST/$APP"
if [ "$running" = yes ]; then
    echo "RNDIS Tether switches to the new version within a minute."
else
    open "$DEST/$APP"
    echo "Opened RNDIS Tether. The first time, its window installs the background service."
fi
