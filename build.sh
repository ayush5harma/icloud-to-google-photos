#!/usr/bin/env bash
# Build "Photo Sync.app" -- the menu-bar face of this pipeline -- from the
# Swift files in Sources/, and install it into /Applications (or wherever
# --dest says).
#
# NO XCODE PROJECT ON PURPOSE. Two `swiftc` invocations -- one for the app, one
# for the icon renderer that draws its artwork -- are the whole build; there is
# no .xcodeproj to drift, no signing identity to expire, and nothing to fetch.
# The Xcode Command Line Tools supply swiftc.
#
# IDEMPOTENT and mtime-guarded: it rebuilds only when something in Sources/ or
# this script is newer than the installed binary, so a login agent could call it
# every time for pennies. Pass --force to rebuild regardless.
#
#   ./build.sh                     build into /Applications
#   ./build.sh --dest /tmp/out     build into /tmp/out/Photo Sync.app
#   ./build.sh --force             rebuild even if nothing changed

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="${PHOTO_SYNC_APP_NAME:-Photo Sync}"
DEST="${PHOTO_SYNC_APP_DIR:-/Applications}"
FORCE=0
# --bin-dir records the directory holding the pipeline's commands in the bundle's
# Info.plist (AVDPhotosBinDir), BEFORE it is signed. That is how the app finds
# avd-photos-sync and avd-photos-status: it deliberately ignores the environment
# for that decision (a caller-set variable would choose what runs with the app's
# privacy grants), so a non-standard --prefix has to be recorded somewhere only
# an installer can write.
#
# A KEY, NOT A SYMLINK. The first version of this put Contents/Resources/bin in
# the bundle as a symlink to the install prefix, and `codesign --verify --strict`
# rejects that outright: "invalid destination for symbolic link in bundle". That
# matters more than tidiness here -- the bundle identity IS the TCC identity, so
# a seal that only passes the lax check is a grant that can evaporate at an OS
# update. A plist key is sealed like any other byte of Info.plist and verifies
# strictly.
BIN_LINK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --dest) shift; DEST="${1:-}"; [ -n "$DEST" ] || { echo "--dest needs a directory" >&2; exit 2; } ;;
    --bin-dir) shift; BIN_LINK="${1:-}"; [ -n "$BIN_LINK" ] || { echo "--bin-dir needs a directory" >&2; exit 2; } ;;
    *) echo "usage: ${0##*/} [--force] [--dest <dir>] [--bin-dir <dir>]" >&2; exit 2 ;;
  esac
  shift
done
APP_DIR="$DEST/${APP_NAME}.app"
BIN="$APP_DIR/Contents/MacOS/PhotoSync"

say() { printf '  %s\n' "$*"; }

# A path is not a compiler: /usr/bin/swiftc is a shim that exists on every Mac
# and fails until the Xcode Command Line Tools are installed, so the guard must
# RUN it. Exit 0 either way, so an installer that calls this can carry on and
# name the missing tools itself.
SWIFTC="$(command -v swiftc 2>/dev/null || xcrun --find swiftc 2>/dev/null)"
[ -n "$SWIFTC" ] && "$SWIFTC" --version >/dev/null 2>&1 \
  || { say "swiftc not usable — install the Xcode Command Line Tools (xcode-select --install)"; exit 0; }

# Skip when nothing in the source tree is newer than the installed binary. EVERY
# file counts, not just main.swift: a guard that watched that one alone let an
# edit to the icon renderer compile locally and never reach /Applications. A
# bundle with no icon also rebuilds, so a run that failed midway through the
# artwork retries.
if [ "$FORCE" -eq 0 ] && [ -x "$BIN" ] \
   && [ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ] \
   && [ "$(/usr/bin/plutil -extract AVDPhotosBinDir raw "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)" = "$BIN_LINK" ] \
   && [ -z "$(find "$SRC_DIR/Sources" "$SRC_DIR/build.sh" -type f ! -name '.*' -newer "$BIN" -print -quit)" ]; then
  say "$APP_NAME is up to date"
  exit 0
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" || exit 1

cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Photo Sync</string>
  <key>CFBundleDisplayName</key><string>Photo Sync</string>
  <key>CFBundleIdentifier</key><string>local.ayushsharma.icloud-to-google-photos</string>
  <key>CFBundleExecutable</key><string>PhotoSync</string>
  <!-- CFBundleIconFile is the pre-macOS-26 path (Resources/AppIcon.icns).
       CFBundleIconName, which points at the appearance-aware icon inside
       Assets.car, is added below only when actool actually produced one. -->
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Menu-bar only: no Dock tile, no app menu. Matches setActivationPolicy(.accessory). -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

say "compiling"
# Compile beside the target and rename into place: swiftc -o straight onto the
# installed path truncates the inode the RUNNING app has mapped, which can
# SIGBUS it mid-draw. A same-volume rename gives the new build a fresh inode and
# the old process keeps its pages until it exits.
if ! "$SWIFTC" -O -whole-module-optimization \
      -framework AppKit \
      -o "$BIN.new" "$SRC_DIR/Sources/main.swift" "$SRC_DIR/Sources/model.swift" \
      2>"$SRC_DIR/.build.log"; then
  say "BUILD FAILED — see $SRC_DIR/.build.log"
  tail -15 "$SRC_DIR/.build.log" | sed 's/^/      /'
  rm -f "$BIN.new"
  exit 1
fi
chmod +x "$BIN.new"
mv -f "$BIN.new" "$BIN"
rm -f "$SRC_DIR/.build.log"

# ── App icon ─────────────────────────────────────────────────────────────────
# Drawn from Sources/icon.swift at build time, so no binary asset lives in the
# repo. TWO products from that one source: an Icon Composer .icon package, which
# actool compiles into an Assets.car carrying separate light and dark artwork
# (the .icns format has no notion of appearance, so this is the only way to get a
# dark variant at all), and a legacy AppIcon.icns for everything before macOS 26.
# actool ships inside Xcode.app and NOT with the Command Line Tools, so a
# bootstrapping Mac that has only the CLT falls back to the icns alone --
# iconutil does ship with them.
build_icon() {
  local work res plist
  work="$1"
  res="$APP_DIR/Contents/Resources"
  plist="$APP_DIR/Contents/Info.plist"

  if ! "$SWIFTC" -O -framework AppKit -o "$work/iconrender" "$SRC_DIR/Sources/icon.swift" \
        2>"$work/icon.log"; then
    say "the icon renderer FAILED to compile"
    sed 's/^/      /' "$work/icon.log" | tail -10
    return 1
  fi
  "$work/iconrender" "$work" || { say "the icon renderer FAILED to draw"; return 1; }

  if xcrun --find actool >/dev/null 2>&1; then
    # actool refuses to create its own output directory ("The output directory
    # ... does not exist"), so make it first.
    mkdir -p "$work/car"
    # --standalone-icon-behavior all is load-bearing: by default actool writes an
    # .icns holding only the 16 and 128 pt tiles, and Get Info, the Dock and
    # Finder's larger views all want the rest.
    if xcrun actool "$work/AppIcon.icon" --compile "$work/car" \
          --platform macosx --minimum-deployment-target 26.0 \
          --app-icon AppIcon --standalone-icon-behavior all \
          --output-partial-info-plist "$work/partial.plist" \
          --output-format human-readable-text --errors >"$work/actool.log" 2>&1 \
       && [ -s "$work/car/Assets.car" ] && [ -s "$work/car/AppIcon.icns" ]; then
      cp -f "$work/car/Assets.car" "$res/Assets.car"
      cp -f "$work/car/AppIcon.icns" "$res/AppIcon.icns"
      /usr/bin/plutil -replace CFBundleIconName -string AppIcon "$plist" >/dev/null 2>&1
      say "icon: Assets.car (light + dark) and AppIcon.icns"
      return 0
    fi
    say "actool could not compile the .icon — using the legacy icns alone"
    sed 's/^/      /' "$work/actool.log" | tail -10
  fi

  # Legacy path. Drop any CFBundleIconName an earlier build left behind, or the
  # plist would point at an Assets.car that is no longer in the bundle.
  rm -f "$res/Assets.car"
  /usr/bin/plutil -remove CFBundleIconName "$plist" >/dev/null 2>&1 || true
  iconutil -c icns -o "$res/AppIcon.icns" "$work/AppIcon.iconset" \
    || { say "iconutil FAILED"; return 1; }
  say "icon: AppIcon.icns (no actool — light appearance only)"
}

ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/photo-sync-icon.XXXXXX")"
build_icon "$ICON_WORK" || say "the icon build failed — the bundle keeps the icon it had"
rm -rf "$ICON_WORK"

# The command directory, recorded BEFORE signing so the seal covers it. An
# earlier build of this project wrote a Resources/bin symlink here; remove it, or
# a bundle upgraded in place keeps failing --strict for a link nothing reads.
rm -f "$APP_DIR/Contents/Resources/bin"
if [ -n "$BIN_LINK" ]; then
  /usr/bin/plutil -replace AVDPhotosBinDir -string "$BIN_LINK" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 \
    && say "commands: AVDPhotosBinDir = $BIN_LINK" \
    || say "could not record AVDPhotosBinDir — the app will fall back to ~/.local/bin"
else
  # No --bin-dir: drop a value an earlier build recorded, so the bundle never
  # points at a prefix that is no longer there.
  /usr/bin/plutil -remove AVDPhotosBinDir "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
fi

# Ad-hoc sign so macOS does not kill it for having no signature at all. This is a
# locally built tool, so a real identity buys nothing here. It runs AFTER the
# icon lands: the signature covers Contents/Resources, so writing the icns or the
# car afterwards would invalidate it.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
/usr/bin/xattr -cr "$APP_DIR" 2>/dev/null || true
# Bump the bundle's mtime and re-index it. LaunchServices caches an app's icon
# against the bundle, and a Finder window already showing the old (or blank) one
# keeps showing it until something invalidates that cache; these two are what
# does it without asking anyone to killall Finder.
touch "$APP_DIR"
/usr/bin/mdimport "$APP_DIR" >/dev/null 2>&1 || true
say "built $APP_DIR"

# The launchd agent (KeepAlive) is still running the OLD binary; kick it so the
# menu bar shows this build now rather than after the next logout. Guarded: no
# agent (a fresh machine, mid-install) is not an error.
LABEL="com.ayushsharma.icloud-to-google-photos.menubar"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null \
    && say "restarted the menu-bar agent" || true
fi
exit 0
