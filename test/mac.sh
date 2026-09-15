#!/usr/bin/env bash
# The Mac backend's bookkeeping, judged by effect on a scratch state: lib/mac.sh
# sourced the way avd-photos-sync sources it (set -uo pipefail), with the
# sync's own helpers stubbed and a bridge ledger written by hand. No Google
# Photos, no network. Covers what the two reviews of 2026-09-16 found by
# reading: the first-run seed under pipefail, the give-up rule, a legacy
# two-column ledger line, the name-clash guard, and the collect that feeds
# the iCloud reclaim.
#
# Usage: test/mac.sh          (also: /bin/bash test/mac.sh, for bash 3.2)

set -uo pipefail
export LC_ALL=C   # as avd-photos-sync runs: bytewise sort and comm
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export AVD_PHOTOS_CONFIG_DIR="$T/config" AVD_PHOTOS_STATE_DIR="$T/state"
mkdir -p "$HOME/Pictures" "$T/config" "$T/state" "$T/staging/2026/05" "$T/staging/a/b_c" "$T/staging/a_b/c"
printf 'ICLOUD_USERNAME=t@example.invalid\nSTAGING="%s/staging"\nGPHOTOS_UPLOAD_DIR="%s/home/Pictures/Google Photos Upload"\nPHOTOS_BACKEND=mac\n' "$T" "$T" > "$T/config/config"

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# The sync's helpers, as lib/mac.sh expects them.
LOGGED=""
log() { LOGGED="$LOGGED$*"$'\n'; }
phase() { :; }
FAILED_WITH=""
# shellcheck disable=SC2034  # read by lib/mac.sh
fail() { FAILED_WITH="$1"; return 1; }
none() { ! "$@"; }   # bash 3.2 has no `!` command for check's "$@"
count_lines() { local n; n="$(grep -c . "$1" 2>/dev/null)"; printf '%s\n' "${n:-0}"; }
# shellcheck disable=SC2034  # read by lib/mac.sh
ENUM_ERR=""
enumerate_staging() {
  while IFS= read -r f; do [ -n "$f" ] && printf '%s\n' "${f#"$STAGING"/}"; done < <(find "$STAGING" -type f 2>/dev/null) \
    | grep -iE '\.(jpg|jpeg|png|heic|heif|gif|webp|mp4|mov|m4v|3gp)$' | sort
}
# shellcheck disable=SC1091
. "$HERE/../lib/config.sh"; ap_load_config
RECLAIM_PENDING="$STATE_DIR/reclaim-pending.list"
# shellcheck disable=SC1091
. "$HERE/../lib/mac.sh"
mkdir -p "$MAC_BRIDGE"

echo "seed"
printf 'old/1.HEIC\nold/2.HEIC\n' > "$STATE_DIR/reclaimed.list"
printf 'old/3.HEIC\n' > "$RECLAIM_PENDING"
mac_seed
check "first run: the union of the emulator's lists, with no prior list (pipefail on)" test "$(tr '\n' ' ' < "$MAC_CONFIRMED")" = "old/1.HEIC old/2.HEIC old/3.HEIC "
check "the ledger exists only after the seed" test -e "$MAC_LEDGER"
check "the log names what it wrote" grep -q '3 file(s)' <<<"$LOGGED"
printf 'old/9.HEIC\n' >> "$STATE_DIR/reclaimed.list"; mac_seed
check "a second run does not seed again" test "$(count_lines "$MAC_CONFIRMED")" = 3

echo "handoff"
printf 'x' > "$T/staging/2026/05/IMG_1.HEIC"; printf 'yy' > "$T/staging/2026/05/IMG_1_HEVC.MOV"; printf 'zzz' > "$T/staging/2026/05/IMG_2.HEIC"
printf 'p' > "$T/staging/a/b_c/P.HEIC"; printf 'q' > "$T/staging/a_b/c/P.HEIC"
MAC_HANDED=0; mac_handoff
check "four handed over, the name clash held back" test "$MAC_HANDED" = 4
check "the clash is logged" grep -q 'name clash' <<<"$LOGGED"
check "copies are in the folder under flat names" test -f "$MAC_INBOX/2026_05_IMG_1.HEIC" -a -f "$MAC_INBOX/2026_05_IMG_1_HEVC.MOV"
check "ledger lines carry a handoff epoch" test "$(awk -F'\t' 'NF == 3 && $3 ~ /^[0-9]+$/' "$MAC_LEDGER" | wc -l | tr -d ' ')" = 4
check "nothing new is left but the clash" test "$(mac_list_new /dev/stdout | tr '\n' ' ')" = "a_b/c/P.HEIC "

echo "collect"
mkdir -p "$MAC_INBOX/Uploaded" "$MAC_INBOX/Failed"
mv "$MAC_INBOX/2026_05_IMG_2.HEIC" "$MAC_INBOX/Uploaded/"; mv "$MAC_INBOX/2026_05_IMG_1.HEIC" "$MAC_INBOX/Failed/"; mv "$MAC_INBOX/2026_05_IMG_1_HEVC.MOV" "$MAC_INBOX/Failed/"
cat > "$MAC_BRIDGE/ledger.json" <<'J'
{"files":{
 "2026_05_IMG_2.HEIC":{"id":"j1","state":"completed","mediaKey":"AF1Qtest","moved":"Uploaded/2026_05_IMG_2.HEIC"},
 "2026_05_IMG_1.HEIC":{"id":"j2","state":"failed","error":"remote_live_photo_component_exists","moved":"Failed/2026_05_IMG_1.HEIC"},
 "2026_05_IMG_1_HEVC.MOV":{"id":"j2","state":"failed","error":"remote_live_photo_component_exists","moved":"Failed/2026_05_IMG_1_HEVC.MOV"},
 "a_b_c_P.HEIC":{"id":"j3","state":"pending"}
}}
J
mac_collect
check "a media key confirms the staged path" grep -qx '2026/05/IMG_2.HEIC' "$MAC_CONFIRMED"
check "and only that path reaches the reclaim list" test "$(grep -v '^old/' "$RECLAIM_PENDING" | tr '\n' ' ')" = "2026/05/IMG_2.HEIC "
check "the consumed copy is deleted" test ! -e "$MAC_INBOX/Uploaded/2026_05_IMG_2.HEIC"
check "an existing Live Photo is kept in iCloud, not confirmed, not failed" test "$(count_lines "$MAC_EXISTS")" = 2 -a ! -e "$MAC_FAILED"
check "a pending job is left alone" test -f "$MAC_INBOX/a_b_c_P.HEIC"
check "outstanding is the pending one" test "$(mac_outstanding | tr '\n' ' ')" = "a/b_c/P.HEIC "

echo "give up"
old=$(( $(date +%s) - MAC_GIVE_UP - 60 ))
awk -F'\t' -v OFS='\t' -v o="$old" '{ $3 = o } 1' "$MAC_LEDGER" > "$MAC_LEDGER.t" && mv "$MAC_LEDGER.t" "$MAC_LEDGER"
printf 'lost_L.HEIC\tlost/L.HEIC\n' >> "$MAC_LEDGER"        # legacy two-column line, never seen by the bridge
printf 'x' > "$MAC_INBOX/lost_L.HEIC"
mac_collect
check "a name the bridge holds is not given up however old" grep -q 'a_b_c_P.HEIC' "$MAC_LEDGER"
check "a legacy line the bridge never saw is given up" none grep -q 'lost_L.HEIC' "$MAC_LEDGER"
check "its copy is removed and the failure recorded" test ! -e "$MAC_INBOX/lost_L.HEIC" -a "$(cut -f2 "$MAC_FAILED")" = never_taken_by_the_bridge
check "a confirmed line is never given up" grep -qx '2026/05/IMG_2.HEIC' "$MAC_CONFIRMED"

echo "clash release"
mkdir -p "$T/staging/lost"; printf 'x' > "$T/staging/lost/L.HEIC"
mac_handoff
check "the held-back path waits while its twin is pending" grep -q 'name clash' <<<"$LOGGED"
# confirm the twin: the bridge moved it, the sync collects it
mkdir -p "$MAC_INBOX/Uploaded"; mv "$MAC_INBOX/a_b_c_P.HEIC" "$MAC_INBOX/Uploaded/"
cat > "$MAC_BRIDGE/ledger.json" <<'J'
{"files":{"a_b_c_P.HEIC":{"id":"j3","state":"completed","mediaKey":"AF1Qtest2","moved":"Uploaded/a_b_c_P.HEIC"}}}
J
mac_collect; LOGGED=""; MAC_HANDED=0; mac_handoff
check "once the twin is confirmed the same flat name is handed over" test -f "$MAC_INBOX/a_b_c_P.HEIC" -a "$MAC_HANDED" -ge 1
check "and the outcome lookup maps the name to the NEW staged path" test "$(awk -F'\t' -v n=a_b_c_P.HEIC '$1 == n { r = $2 } END { print r }' "$MAC_LEDGER")" = "a_b/c/P.HEIC"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
