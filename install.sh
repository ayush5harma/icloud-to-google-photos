#!/usr/bin/env bash
# Install (or remove) the pipeline: the commands on PATH, the menu-bar app, and
# the launchd agents.
#
# NOTHING IT INSTALLS DOES ANYTHING YET. The sync agent is loaded but the sync
# itself is dormant until `avd-photos-arm` creates the arming sentinel, so a
# freshly installed machine downloads nothing and deletes nothing.
#
#   ./install.sh                     symlink bin/ into ~/.local/bin, build the
#                                    app into /Applications, load the agents
#   ./install.sh --prefix <dir>      somewhere other than ~/.local
#   ./install.sh --app-dir <dir>     somewhere other than /Applications
#   ./install.sh --copy              install a self-contained copy, so the
#                                    checkout can be deleted afterwards
#   ./install.sh --no-agents         no launchd agents (run things by hand)
#   ./install.sh --no-app            skip the menu-bar app
#   ./install.sh --uninstall         undo all of the above
#
# UNINSTALL KEEPS YOUR DATA: the config, the ledgers, the logs, the staging tree
# and the emulator are left exactly where they are. It prints where they live so
# you can remove them deliberately.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SRC_DIR/lib/config.sh"

PREFIX="$HOME/.local"
APP_PARENT="/Applications"
APP_NAME="Photo Sync"
MODE=install
WANT_AGENTS=1
WANT_APP=1
LINK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) shift; PREFIX="${1:-}" ;;
    --app-dir) shift; APP_PARENT="${1:-}" ;;
    --copy) LINK=0 ;;
    --no-agents) WANT_AGENTS=0 ;;
    --no-app) WANT_APP=0 ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  [ $# -gt 0 ] && shift
done
[ -n "$PREFIX" ] && [ -n "$APP_PARENT" ] || { echo "--prefix and --app-dir need a directory" >&2; exit 2; }

BIN_DIR="$PREFIX/bin"
# --copy installs bin/ and lib/ TOGETHER under libexec and symlinks the commands
# from there, rather than scattering the two: every script resolves its library
# as ../lib from its own real path, so the pair has to stay adjacent.
LIBEXEC="$PREFIX/libexec/avd-photos"
APP_DIR="$APP_PARENT/$APP_NAME.app"
APP_BIN="$APP_DIR/Contents/MacOS/PhotoSync"
AGENT_DIR="$HOME/Library/LaunchAgents"
# label suffix -> template name
AGENTS="sync setup bootstrap app menubar"

say()  { printf '  %s\n' "$*"; }
head2() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

ap_load_config     # for CONFIG_FILE, STATE_DIR, LOG_DIR, AP_LABEL_PREFIX, STAGING

# ── Uninstall ────────────────────────────────────────────────────────────────
if [ "$MODE" = uninstall ]; then
  head2 "Agents"
  for a in $AGENTS; do
    label="$AP_LABEL_PREFIX.$a"
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 \
      && say "unloaded $label" || say "$label was not loaded"
    rm -f "$AGENT_DIR/$label.plist"
  done
  head2 "Commands"
  for f in "$SRC_DIR"/bin/*; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"
    t="$BIN_DIR/$n"
    [ -e "$t" ] || [ -L "$t" ] || continue
    # ONLY WHAT WE INSTALLED. An install writes symlinks and nothing else, so
    # anything that is not a symlink resolving INTO this checkout or into our own
    # libexec belongs to someone else -- a package manager's binary of the same
    # name, a script the user wrote -- and removing it would be this installer
    # deleting a stranger's file.
    if [ -L "$t" ]; then
      r="$(readlink -f "$t" 2>/dev/null || true)"
      case "$r" in
        "$SRC_DIR"/*|"$LIBEXEC"/*) rm -f "$t"; say "removed $t" ;;
        *) say "left $t (a symlink to ${r:-nowhere}, not ours)" ;;
      esac
    else
      say "left $t (not a symlink we created)"
    fi
  done
  if [ -d "$LIBEXEC" ]; then rm -rf "$LIBEXEC"; say "removed $LIBEXEC"; fi
  head2 "App"
  if [ -d "$APP_DIR" ]; then rm -rf "$APP_DIR"; say "removed $APP_DIR"; fi
  # The Dock launcher lives beside the menu-bar app, so --app-dir governs both
  # and an uninstall aimed at a scratch directory can never reach /Applications.
  if [ -d "$APP_PARENT/Google Photos (AVD).app" ]; then
    rm -rf "$APP_PARENT/Google Photos (AVD).app"
    say "removed the Google Photos (AVD) launcher (its Dock tile clears at the next login)"
  fi
  cat <<EOF

Left in place, deliberately — remove them by hand if you mean to:
  config     $CONFIG_DIR
  state      $STATE_DIR   (ledgers: what was pushed, confirmed and reclaimed)
  logs       $LOG_DIR
  staging    $STAGING
  emulator   $HOME/.android/avd/$AVD_NAME.avd
  SDK        $AVD_SDK_ROOT
EOF
  exit 0
fi

# ── Install ──────────────────────────────────────────────────────────────────
head2 "Requirements"
missing=""
for t in adb sdkmanager jq curl python3 uv; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
command -v "$ICLOUDPD" >/dev/null 2>&1 || missing="$missing icloudpd"
if [ -n "$missing" ]; then
  say "MISSING:$missing"
  say "See 'Requirements' in the README. Install them and re-run; nothing below needs them yet."
else
  say "all present"
fi

head2 "Commands -> $BIN_DIR"
mkdir -p "$BIN_DIR" || exit 1
SOURCE_BIN="$SRC_DIR/bin"
if [ "$LINK" -eq 0 ]; then
  rm -rf "$LIBEXEC"
  mkdir -p "$LIBEXEC" || exit 1
  cp -R "$SRC_DIR/bin" "$SRC_DIR/lib" "$LIBEXEC/" || exit 1
  SOURCE_BIN="$LIBEXEC/bin"
  say "copied bin/ and lib/ to $LIBEXEC"
fi
n_cmds=0
for f in "$SOURCE_BIN"/*; do
  # Files only: a stray __pycache__ from a local `py_compile` is not a command.
  [ -f "$f" ] || continue
  chmod +x "$f" 2>/dev/null
  ln -sfn "$f" "$BIN_DIR/$(basename "$f")"
  n_cmds=$((n_cmds+1))
done
say "linked $n_cmds commands into $BIN_DIR"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "NOTE: $BIN_DIR is not on your PATH — add it to your shell profile." ;;
esac

head2 "Config"
if [ -f "$CONFIG_FILE" ]; then
  say "keeping $CONFIG_FILE"
else
  ap_write_default_config && say "wrote $CONFIG_FILE"
fi
# It holds an Apple ID and may hold a GITHUB_TOKEN, whoever wrote it.
ap_secure_config
[ $? -eq 10 ] && say "tightened $CONFIG_FILE to 0600 (it holds an Apple ID)"
[ -n "$ICLOUD_USERNAME" ] || say "SET ICLOUD_USERNAME in $CONFIG_FILE before arming."

if [ "$WANT_APP" -eq 1 ]; then
  head2 "Menu-bar app"
  bash "$SRC_DIR/build.sh" --dest "$APP_PARENT" || say "the app build failed — the pipeline still works without it, but the sync agent needs it"
fi

if [ "$WANT_AGENTS" -eq 1 ]; then
  head2 "Agents -> $AGENT_DIR"
  mkdir -p "$AGENT_DIR" "$LOG_DIR" || exit 1
  for a in $AGENTS; do
    label="$AP_LABEL_PREFIX.$a"
    src="$SRC_DIR/launchd/$a.plist.template"
    dst="$AGENT_DIR/$label.plist"
    [ -f "$src" ] || { say "missing template $src"; continue; }
    # The two agents that ARE the app: without it there is nothing to load, and
    # the sync in particular must run as the app (that is what gives it the
    # file-provider grant), so loading it here would only schedule a job that
    # waits for a binary nobody is going to build.
    if [ "$WANT_APP" -eq 0 ] && { [ "$a" = "sync" ] || [ "$a" = "menubar" ]; }; then
      say "skipping $label (--no-app: it runs the app bundle)"
      rm -f "$dst"
      continue
    fi
    # The placeholders are substituted with `|` as the sed delimiter, so a path
    # containing `/` needs no escaping; a path containing `|` would, and none of
    # these can (they are directories under $HOME or /Applications).
    sed -e "s|__LABEL__|$label|g" \
        -e "s|__BIN_DIR__|$BIN_DIR|g" \
        -e "s|__APP_BIN__|$APP_BIN|g" \
        -e "s|__LOG_DIR__|$LOG_DIR|g" \
        "$src" > "$dst" || { say "could not write $dst"; continue; }
    # bootout first so a re-install reloads the new definition rather than
    # silently keeping the old one.
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
    if launchctl bootstrap "gui/$(id -u)" "$dst" 2>/dev/null; then say "loaded $label"
    else say "could not load $label (plist written to $dst)"; fi
  done
fi

cat <<EOF

Installed. NOTHING SYNCS YET — the pipeline is dormant until you arm it.

Next, in order:
  1. avd-photos-config          check the config; set ICLOUD_USERNAME
  2. icloudpd --username <your apple id> --directory "$STAGING" --recent 1
                                the one-time Apple login (two-factor, interactive)
  3. avd-photos-setup           build the rooted emulator (long, downloads GBs)
  4. avd-signin                 boot it in software GL and sign in to Google;
                                register the device id the setup printed at
                                https://www.google.com/android/uncertified/
  5. avd-photos-check           confirm Magisk, Zygisk, the spoof and Photos
  6. avd-photos-arm             ARM IT. From here the sync downloads, uploads,
                                verifies and reclaims iCloud space on its own.

Watch it: the menu-bar ring, \`avd-photos-status | jq\`, or
  tail -f $LOG_DIR/sync.log
EOF
