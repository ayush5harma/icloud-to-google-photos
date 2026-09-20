#!/usr/bin/env bash
# The one place every path, name and tunable of this pipeline is defined, and
# the one reader of ~/.config/avd-photos/config. Source via:
#   . "$LIB_DIR/config.sh"
#   ap_load_config
#
# PRECEDENCE is environment > config file > default, and it is implemented
# rather than assumed: `AVD_GPU=swiftshader_indirect avd-photos-setup --start`
# (what avd-signin does) must beat a GPU set in the config file, while the config
# file must beat the defaults below. ap_load_config snapshots the caller's
# environment for every known key, sources the config, then puts the snapshot
# back -- fifteen lines that make the rule true instead of accidental.
#
# NOTHING HERE READS A MACHINE-SPECIFIC PATH. Every location a deployment could
# want elsewhere is a key with a default, so the project runs from a clone on any
# Mac and a configuration manager can write the config file instead.

# Where the config, the arming sentinel, the ledgers and the logs live. These
# three are environment-only (a config file cannot move the file that defines
# them), so an automated test can point the whole pipeline at a scratch HOME.
CONFIG_DIR="${AVD_PHOTOS_CONFIG_DIR:-$HOME/.config/avd-photos}"
STATE_DIR="${AVD_PHOTOS_STATE_DIR:-$HOME/.cache/avd-photos}"
LOG_DIR="${AVD_PHOTOS_LOG_DIR:-$STATE_DIR/logs}"
CONFIG_FILE="$CONFIG_DIR/config"
# The pipeline is DORMANT until this file exists (avd-photos-arm creates it).
# Everything else can be installed, scheduled and running; nothing touches the
# photo library until a human arms it.
# shellcheck disable=SC2034  # read by the scripts that source this file
SENTINEL="$CONFIG_DIR/ENABLED"
# The launchd label prefix, in ONE place: the agents are <prefix>.sync, .setup,
# .bootstrap, .app and .menubar. install.sh renders the plists from it and the
# menu-bar app kickstarts <prefix>.sync by name, so changing it means changing
# Sources/main.swift too.
# shellcheck disable=SC2034  # read by the scripts that source this file
AP_LABEL_PREFIX="com.ayushsharma.icloud-to-google-photos"

# Every key the config file may set. Used for the precedence restore above, and
# it is the list the README documents.
AP_KEYS="ICLOUD_USERNAME ICLOUDPD STAGING ICLOUD_DIR SHARED_CACHE_DIR
         GOOGLE_ACCOUNT PHOTOS_BACKEND GPHOTOS_APP
         GPHOTOS_IPA_URL GPHOTOS_IPA_SHA256 IPA_INSTALL MAC_INBOX_MAX AVD_NAME AVD_SDK_ROOT AVD_ABI AVD_TAG AVD_DEVICE
         AVD_RES AVD_DPI AVD_RAM AVD_CORES AVD_DISK AVD_HEAP AVD_GPU AVD_SPOOF
         RECENT UNTIL_FOUND PUSH_CAP UPLOAD_WAIT ADB_TIMEOUT RECLAIM_TIMEOUT
         PRESENCE_CHECK PRESENCE_BUDGET
         DELETE_FROM_ICLOUD KEEP_ICLOUD_DAYS KEEP_ICLOUD_ADDED_DAYS
         KEEP_ICLOUD_ALBUMS_EXCLUDE KEEP_ICLOUD_SAVED_FROM_APPS
         PRUNE_DEVICE_AFTER_UPLOAD
         STOP_EMULATOR_WHEN_IDLE DEST_DCIM GITHUB_TOKEN"

ap_defaults() {
  # ── Identity and sources ───────────────────────────────────────────────────
  # The Apple ID icloudpd downloads as. No default: the sync refuses to run
  # without it rather than guessing at someone's account.
  ICLOUD_USERNAME="${ICLOUD_USERNAME-}"
  # The icloudpd command. `uv tool install icloudpd` puts it in ~/.local/bin,
  # which ap_seed_path puts first on PATH.
  ICLOUDPD="${ICLOUDPD:-icloudpd}"
  # WHERE DOWNLOADED ORIGINALS LAND, and the only local copy of them until
  # Google Photos has confirmed the upload. Any directory works. It must NOT be
  # a cache directory (those are prunable by design) and it should be somewhere
  # with its own backup, because for the minutes-to-hours between "downloaded"
  # and "confirmed in Google Photos" it is the only copy outside iCloud's
  # Recently Deleted. A synced cloud folder (this pipeline was built against a
  # Google Drive folder in stream mode) gives that for free: the bytes leave the
  # disk again once uploaded. The cost of that choice is documented in the
  # README -- a cloud mount is permission-gated, which is why the sync runs as a
  # child of the app bundle.
  STAGING="${STAGING:-$HOME/Pictures/icloud-photos-staging}"
  # iCloud Drive's root, used for ONE thing: the default home of the shared
  # cache below, so a second Mac with the same iCloud account skips the 2.7 GB
  # Play Store extraction.
  ICLOUD_DIR="${ICLOUD_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs}"
  SHARED_CACHE_DIR="${SHARED_CACHE_DIR:-$ICLOUD_DIR/avd-photos}"
  # The Google account the emulator signs in as. Unset by default; it is only
  # printed, as a reminder of which account to register the device under.
  GOOGLE_ACCOUNT="${GOOGLE_ACCOUNT-}"

  # ── Which Google Photos does the uploading ─────────────────────────────────
  # mac = the iPhone/iPad Google Photos running natively on an Apple silicon Mac
  #       (converted by ipa-install-on-mac), uploading through the GoToHP engine
  #       of the Gunshot tweak with ios/gp-bridge.m linked in. No emulator, no
  #       root, no device registration: the tweak asks for the Pixel XL
  #       original-quality profile itself (2026-09-16).
  # avd = the rooted Android emulator below. The only choice on an Intel Mac,
  #       which cannot run iOS apps.
  case "$(uname -m)" in arm64) _ap_backend=mac ;; *) _ap_backend=avd ;; esac
  PHOTOS_BACKEND="${PHOTOS_BACKEND:-$_ap_backend}"
  # Where ipa-install-on-mac puts the app: --dest /Applications, named after
  # the IPA's bundle. The folder the bridge watches is NOT a key beside it --
  # lib/mac.sh has the one definition and the reason.
  GPHOTOS_APP="${GPHOTOS_APP:-/Applications/GooglePhotos.app}"
  # The IPA gphotos-mac-setup installs: Google Photos 7.92.0 with the Gunshot
  # tweak's GunshotJailed.dylib already injected (the tweak's own supported
  # sideload shape). The hash is checked before anything is installed.
  GPHOTOS_IPA_URL="${GPHOTOS_IPA_URL:-https://github.com/ayush5harma/icloud-to-google-photos/releases/download/google-photos-7.92.0/GooglePhotos-7.92.0-gunshot.ipa}"
  GPHOTOS_IPA_SHA256="${GPHOTOS_IPA_SHA256:-65a968d3619ba472392b3ba504a9f7ed65577956d4fb3540c82b8fd348ee8303}"
  # The converter. On PATH when installed (a Nix flake or a clone's bin/);
  # otherwise gphotos-mac-setup fetches the pinned revision below into the
  # state directory.
  IPA_INSTALL="${IPA_INSTALL:-ipa-install-on-mac}"
  # Files waiting in the upload folder at once. The engine copies each file
  # into the app's container while it uploads, so a backlog costs its size
  # twice over; a few hundred photos is a few GB.
  MAC_INBOX_MAX="${MAC_INBOX_MAX:-300}"

  # ── The emulator ───────────────────────────────────────────────────────────
  AVD_NAME="${AVD_NAME:-gphotos-tablet}"
  # DELIBERATELY NOT a system-wide Android SDK: rooting rewrites ramdisk.img IN
  # PLACE, so any read-only or package-managed SDK can never be rooted. This
  # root is writable and owned by the pipeline (it is also what ANDROID_HOME is
  # set to when the emulator and avdmanager are invoked).
  AVD_SDK_ROOT="${AVD_SDK_ROOT:-$HOME/.local/share/android-avd-sdk}"
  # The image must match the host CPU: HVF runs arm64 guests on Apple silicon
  # only, and an Intel Mac runs x86_64 ones (under Hypervisor.framework too).
  case "$(uname -m)" in arm64) _ap_abi=arm64-v8a ;; *) _ap_abi=x86_64 ;; esac
  AVD_ABI="${AVD_ABI:-$_ap_abi}"
  # google_apis, never google_apis_playstore: the certified image is a `user`
  # build with adb root disabled and stronger verified boot, which resists
  # ramdisk patching and defeats device spoofing outright. google_apis is
  # userdebug, which is exactly why it can be rooted -- and it ships Google
  # Photos preinstalled at /product/app/Photos.
  AVD_TAG="${AVD_TAG:-google_apis}"
  AVD_DEVICE="${AVD_DEVICE:-pixel_tablet}"
  # Resolution is the single biggest rendering cost. 2560x1440 at 210dpi gives
  # a 1097dp smallest width, which is well above Android's 600dp tablet
  # threshold, so Photos renders its dense tablet layout with the left nav rail.
  # Raising dpi yields FEWER dp (dp = px / (dpi/160)), so >=385dpi on this panel
  # would flip it to the phone UI -- the opposite of the intuition.
  AVD_RES="${AVD_RES:-2560x1440}"
  AVD_DPI="${AVD_DPI:-210}"
  AVD_RAM="${AVD_RAM:-6144}"        # guest RSS sits around 4 GB
  AVD_CORES="${AVD_CORES:-8}"       # the performance-core count on an M2 Pro
  AVD_DISK="${AVD_DISK:-16384M}"
  # Per-app Dalvik heap. The emulator default (192M) is phone-class and makes
  # Google Photos garbage-collect continuously on large originals.
  AVD_HEAP="${AVD_HEAP:-512M}"
  # GPU MODE IS A TRADE-OFF and the failure is silent. `host` routes guest GLES
  # through ANGLE/MoltenVK onto Metal and is the fast default, but it cannot
  # render Google's account sign-in (a Chromium WebView that stalls forever on
  # the Play Services splash under `host` and hard-crashes under `auto`). Only
  # software GL paints the login form, so sign-in has its own mode: avd-signin.
  AVD_GPU="${AVD_GPU:-host}"
  # module = the GPhotosUnlimited Magisk module (verified working, the default);
  # vector = the Vector Xposed framework plus PixelifyPhotos, kept as a fallback
  # if a future Photos build stops honouring the module. Never both: they hook
  # the same process and the second one wins unpredictably.
  AVD_SPOOF="${AVD_SPOOF:-module}"
  # PUSH INTO DCIM/Camera, NOT a folder of your own: every other device folder
  # is opt-in under "Back up device folders" (that preference starts EMPTY), so
  # a tidy DCIM/iCloudImport looks perfect at every measurable layer -- file on
  # device, row in MediaStore -- while Photos uploads nothing.
  DEST_DCIM="${DEST_DCIM:-/sdcard/DCIM/Camera}"

  # ── Pacing ─────────────────────────────────────────────────────────────────
  RECENT="${RECENT:-2000}"          # how many of the newest iCloud items a run walks
  UNTIL_FOUND="${UNTIL_FOUND:-50}"  # icloudpd stops after this many already-downloaded items
  PUSH_CAP="${PUSH_CAP:-1000}"      # files handed to the emulator per run (~58 files/min)
  # A FLOOR on the wait for Google Photos, not a deadline -- an expiry is not a
  # failure, the next run re-checks. The verify step adds 2 s per file on the
  # device on top of this.
  UPLOAD_WAIT="${UPLOAD_WAIT:-900}"
  ADB_TIMEOUT="${ADB_TIMEOUT:-120}"
  RECLAIM_TIMEOUT="${RECLAIM_TIMEOUT:-1800}"

  # ── Ask before uploading (the mac backend) ─────────────────────────────────
  # Look each new staged file up in Google Photos' OWN database before handing
  # it over (lib/presence.sh): a library the phone backed up years ago is
  # already there, and this backend cannot tell on its own, because its
  # confirmation is the reply to its own upload. 0 turns the check off and
  # every file is uploaded as before.
  PRESENCE_CHECK="${PRESENCE_CHECK:-1}"
  # SECONDS PER TICK, not a file count: the check reads every candidate's bytes
  # (measured 36 ms per file over this project's own staging tree, 2026-09-20),
  # so a first run against a large library would otherwise spend the whole tick
  # hashing. Whatever it does not reach is handed over the way it always was.
  PRESENCE_BUDGET="${PRESENCE_BUDGET:-300}"

  # ── iCloud space reclaim ───────────────────────────────────────────────────
  # ON by default, because freeing the iCloud plan is what the pipeline is for,
  # and the gate is confirmation: an asset leaves iCloud only after Google
  # Photos' own database holds its dedup_key. iCloud keeps it in Recently
  # Deleted for 30 days. Set to 0 to keep everything in iCloud.
  DELETE_FROM_ICLOUD="${DELETE_FROM_ICLOUD:-1}"
  # A FIRST-TIMER'S NET, and the reason it is not 0: the first armed runs are
  # exactly when a mis-set staging path, a half-finished sign-in or a
  # misunderstanding of what "confirmed" means will show up, and seven days is
  # long enough to notice before the newest photos can leave iCloud. Set it to 0
  # to reclaim as soon as a photo is confirmed. `KEEP_ICLOUD_DAYS=` (empty) also
  # means no floor -- the `-` form below substitutes only when it is UNSET, so a
  # config that clears it keeps it cleared.
  KEEP_ICLOUD_DAYS="${KEEP_ICLOUD_DAYS-7}"
  # ── The keep list ──────────────────────────────────────────────────────────
  # CONFIRMED IN GOOGLE PHOTOS IS NOT THE SAME AS "SAFE TO LOSE FROM iCLOUD".
  # An asset can be confirmed and still be one a human would be upset to find
  # only in Google Photos: a favourite, something they filed into an album by
  # hand, something an app saved into the library last week. The reclaim keeps
  # every one of those, whatever the pending list says.
  #
  # ADDED, NOT TAKEN. The floor above (KEEP_ICLOUD_DAYS) is measured from the
  # capture date, which says nothing about how long the asset has been in the
  # library: a photo re-imported from Google Photos carries its original
  # capture date and is older than any floor the moment it arrives. This one is
  # measured from the CloudKit record's addedDate. 0 turns it off.
  KEEP_ICLOUD_ADDED_DAYS="${KEEP_ICLOUD_ADDED_DAYS:-30}"
  # Album names NOT to treat as a reason to keep, one per line or separated by
  # commas. Empty by default: every album a human made keeps its members. The
  # smart albums (Favorites, Live, Videos, Screenshots, Bursts, Panoramas,
  # Slo-mo, Time-lapse, Hidden, Recently Deleted) are never in this rule at
  # all -- membership of them is automatic and would keep the whole library.
  KEEP_ICLOUD_ALBUMS_EXCLUDE="${KEEP_ICLOUD_ALBUMS_EXCLUDE-}"
  # Keep anything another app saved into the photo library -- what Photos shows
  # as "Recently Saved" (measured 2026-09-20: the album itself is not exposed
  # over CloudKit, but the CPLMaster record behind every asset carries the
  # importer, so the set is resolvable). On a library that receives a lot from
  # Messages or WhatsApp this rule alone can keep most of it; 0 turns it off
  # and leaves those assets to the other rules.
  KEEP_ICLOUD_SAVED_FROM_APPS="${KEEP_ICLOUD_SAVED_FROM_APPS:-1}"
  PRUNE_DEVICE_AFTER_UPLOAD="${PRUNE_DEVICE_AFTER_UPLOAD:-1}"
  STOP_EMULATOR_WHEN_IDLE="${STOP_EMULATOR_WHEN_IDLE:-1}"

  # Optional. Raises the GitHub API's unauthenticated 60-requests-per-hour limit
  # for the release lookups; the pipeline works without it (see gh_latest in
  # avd-photos-setup, which falls back to the cached answer and says so).
  GITHUB_TOKEN="${GITHUB_TOKEN-}"
}

# ap_load_config: defaults, then the config file, then the caller's environment
# back on top. Safe to call more than once.
#
# The snapshot tests whether the caller SET each key, not whether it is non-empty
# (`${k+x}`), so an explicitly empty value survives: `KEEP_ICLOUD_DAYS= ` on the
# command line means "no floor for this run" and must beat the config's 7, the
# same way an empty value in the config file beats the default.
ap_load_config() {
  local k v
  for k in $AP_KEYS; do
    eval "v=\${$k+set}"
    if [ "$v" = set ]; then
      eval "AP_ENV_SET_$k=1; AP_ENV_$k=\${$k}"
    else
      eval "AP_ENV_SET_$k=0"
    fi
  done
  ap_defaults
  # shellcheck disable=SC1090
  [ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  for k in $AP_KEYS; do
    eval "v=\${AP_ENV_SET_$k-0}"
    [ "$v" = 1 ] && eval "$k=\${AP_ENV_$k}"
  done
  # Deliberately NOT a second ap_defaults pass here: every key already has a
  # value, and a re-run would overwrite a key the config file set to an empty
  # string (KEEP_ICLOUD_DAYS= means "no floor", not "use the default").
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" 2>/dev/null
  return 0
}

# ap_seed_path [extra-dir ...]: launchd hands a job a sparse PATH that has
# neither ~/.local/bin nor the usual package-manager locations. ~/.local/bin goes
# FIRST because `uv tool install icloudpd` puts the binary there: without this
# line every scheduled run for five days hit the "icloudpd missing" guard and
# skipped, while the one interactive run of those five days (a shell PATH) worked
# -- a pipeline that looked healthy and had done nothing (measured 2026-09-05).
# The system tail is appended once, at the end, so /usr/bin, /bin, /usr/sbin and
# /sbin are always reachable.
ap_seed_path() {
  local _extra="" _d
  for _d in "$@"; do _extra="$_extra:$_d"; done
  local _tail="/usr/bin:/bin:/usr/sbin:/sbin"
  case "$PATH" in
    *"$_tail") ;;                 # a second call in the same shell
    *) PATH="$PATH:$_tail" ;;
  esac
  export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin${_extra}:$PATH"
}

# ap_write_default_config [path]: the commented default config. Never overwrites
# (the caller decides), and it is the ONE definition of that file -- both
# avd-photos-config and the setup script's first run print it from here.
#
# 0600, because this file holds an Apple ID and may hold a GITHUB_TOKEN. The
# umask is set for the write itself rather than chmod'ed afterwards, so the
# secret is never on disk world-readable, not even for the width of one syscall.
ap_write_default_config() {
  local out="${1:-$CONFIG_FILE}" old
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
  old="$(umask)"; umask 077
  cat >"$out" <<'CFGEOF'
# icloud-to-google-photos configuration. Shell syntax, sourced by every script;
# values are plain assignments. Anything left commented out keeps its default.
#
# QUOTE ANY PATH WITH A SPACE OR A BRACKET IN IT. Unquoted, `STAGING=/a/[05] b`
# parses as an assignment plus a bogus command and the value is silently lost.

# ── Required ────────────────────────────────────────────────────────────────
# The Apple ID icloudpd downloads with. The sync refuses to run without it.
ICLOUD_USERNAME=

# ── Where photos are staged ─────────────────────────────────────────────────
# Downloaded originals land here and stay until Google Photos has confirmed
# them, so for that window this is the only copy outside iCloud's Recently
# Deleted. Any directory works. Do not use a cache directory. A synced cloud
# folder in stream mode gives the staging tree its own backup and lets the bytes
# leave the local disk once uploaded, which is why this pipeline was built
# against one -- see "Staging" in the README for the permission that costs.
#STAGING="$HOME/Pictures/icloud-photos-staging"

# ── Google Photos for Mac (Apple silicon) ───────────────────────────────────
# THE DEFAULT ON AN APPLE SILICON MAC, and the section that applies to you
# there; the emulator below is the Intel path. mac = the iPhone/iPad Google
# Photos app running natively, uploading through the Gunshot tweak's engine.
#PHOTOS_BACKEND=mac
# Where gphotos-mac-setup installs the app. The converter names it after the
# IPA's bundle, so change this only together with the IPA.
#GPHOTOS_APP=/Applications/GooglePhotos.app
# The IPA to install and the hash it must have before anything is installed.
# Point these at your own build to stop using this repo's release asset.
#GPHOTOS_IPA_URL=
#GPHOTOS_IPA_SHA256=
# The IPA-to-Mac converter. On PATH when installed; otherwise a pinned
# revision is fetched into the state directory.
#IPA_INSTALL=ipa-install-on-mac
# Files waiting in the upload folder at once. The engine keeps its own copy of
# each file while it uploads, so a backlog costs its size twice over.
#MAC_INBOX_MAX=300
# The upload folder itself is NOT configurable: the bridge inside the app
# hardcodes ~/Pictures/Google Photos Upload, which is all its sandbox reaches.

# ── The emulator (Intel) ────────────────────────────────────────────────────
#AVD_NAME=gphotos-tablet
# The pipeline's own writable Android SDK (its ANDROID_HOME). It must be
# writable: rooting rewrites the system image's ramdisk.img in place.
#AVD_SDK_ROOT="$HOME/.local/share/android-avd-sdk"
# host = Metal, fast, and CANNOT render Google's sign-in page. Use avd-signin
# (software GL) for the one-time sign-in and leave this alone.
#AVD_GPU=host
# Guest tuning. Defaults are sized for an 8-performance-core, 16 GB Mac.
#AVD_RAM=6144
#AVD_CORES=8
#AVD_DISK=16384M
#AVD_HEAP=512M
#AVD_RES=2560x1440
#AVD_DPI=210

# ── Accounts ────────────────────────────────────────────────────────────────
# The Google account the emulator signs in as. Only ever printed, as a reminder
# of which account to register the device under.
#GOOGLE_ACCOUNT=

# ── Pacing ──────────────────────────────────────────────────────────────────
#RECENT=2000          # newest iCloud items each run walks
#UNTIL_FOUND=50       # stop after this many already-downloaded items
#PUSH_CAP=1000        # files handed to the emulator per run
#UPLOAD_WAIT=900      # floor on the wait for Google Photos, plus 2 s per file

# ── iCloud space reclaim ────────────────────────────────────────────────────
# 1 (the default) deletes an asset from iCloud only after Google Photos' own
# database holds its dedup_key AND the last verify pass confirmed cleanly.
# 0 keeps everything in iCloud.
#DELETE_FROM_ICLOUD=1
# Never delete anything created within the last N days, whatever its state.
# The default is 7: a net for the first armed runs, which is when a mis-set
# staging path or a half-finished sign-in shows up. 0 reclaims a photo as soon
# as it is confirmed.
#KEEP_ICLOUD_DAYS=7

# ── Optional ────────────────────────────────────────────────────────────────
# Raises the GitHub API's 60-per-hour unauthenticated limit for the release
# lookups. The pipeline works without it.
#GITHUB_TOKEN=
CFGEOF
  local rc=$?
  # `>` truncates but KEEPS an existing file's mode, so the umask above does
  # nothing when the file was already there: chmod as well.
  chmod 600 "$out" 2>/dev/null
  umask "$old"
  return "$rc"
}

# ap_secure_config [path]: make an existing config 0600. For an installer or a
# configuration manager that wrote one itself.
ap_secure_config() {
  local out="${1:-$CONFIG_FILE}"
  [ -f "$out" ] || return 0
  case "$(/usr/bin/stat -f %Lp "$out" 2>/dev/null)" in
    600) return 0 ;;
    *) chmod 600 "$out" 2>/dev/null && return 10 ;;   # 10 = "it was looser, now fixed"
  esac
}
