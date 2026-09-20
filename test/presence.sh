#!/usr/bin/env bash
# The presence check, judged by effect: lib/presence.sh against a FIXTURE
# Google Photos database built here with sqlite3, and lib/mac.sh's tick pass
# against a scratch staging tree. No Google Photos, no network, no real
# database -- GP_STORE_DIR points at the fixture.
#
# Covers what the design rests on: the hash formula against a fixed vector, the
# 27-character shape, the Live Photo rule (the still is hashed, the video is
# carried by it), the three answers of gp_present, and the one that matters
# most -- an unreadable database must make every file UPLOAD, never "present".
#
# Usage: test/presence.sh     (also: /bin/bash test/presence.sh, for bash 3.2)

set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export AVD_PHOTOS_CONFIG_DIR="$T/config" AVD_PHOTOS_STATE_DIR="$T/state"
mkdir -p "$HOME/Pictures" "$T/config" "$T/state" "$T/staging/2026/05" "$T/store"
printf 'ICLOUD_USERNAME=t@example.invalid\nSTAGING="%s/staging"\nPHOTOS_BACKEND=mac\n' "$T" > "$T/config/config"

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
none() { ! "$@"; }   # bash 3.2 has no `!` command for check's "$@"
rc_of() { "$@" >/dev/null 2>&1; printf '%s\n' "$?"; }

# The sync's helpers, as lib/mac.sh expects them.
LOGGED=""
log() { LOGGED="$LOGGED$*"$'\n'; }
phase() { :; }
# shellcheck disable=SC2034  # read by lib/mac.sh
fail() { echo "UNEXPECTED fail(): $1" >&2; return 1; }
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
# The fixture store, before lib/mac.sh sources lib/presence.sh (which reads
# GP_STORE_DIR at source time).
export GP_STORE_DIR="$T/store"
# shellcheck disable=SC1091
. "$HERE/../lib/mac.sh"

echo "the hash"
# A FIXED VECTOR, computed from the formula and nothing else: sha1("hello") is
# aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d, which base64url-encodes to
# qvTGHdzF6KLavt4PO0gs2a6pQ00= and loses its one "=".
printf 'hello' > "$T/vector.bin"
V="$(gp_hash "$T/vector.bin")"
check "sha1 -> base64url, no padding" test "$V" = "qvTGHdzF6KLavt4PO0gs2a6pQ00"
check "27 characters, which is what 160 bits comes to" test "${#V}" = 27
check "the URL-safe alphabet, never + or /" none grep -q '[+/=]' <<<"$V"
printf '' > "$T/empty.bin"
check "an empty file still hashes (sha1 of nothing is a real digest)" test "$(gp_hash "$T/empty.bin")" = "2jmj7l5rSw0yVb_vlWAYkK_YBwk"
check "a file that is not there is not a hash" test "$(rc_of gp_hash "$T/nope.bin")" = 1

echo "the fixture database"
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "  SKIP  no sqlite3 on PATH; the database tests cannot run"
else
  DB="$GP_STORE_DIR/photos-1234567890.db"
  sqlite3 "$DB" 'create table ServerPhotos (mediaKey TEXT PRIMARY KEY, localDedupKey TEXT);'
  # Two staged files: a Live Photo (still + motion) and a standalone photo.
  printf 'still-bytes'  > "$T/staging/2026/05/IMG_1.HEIC"
  printf 'motion-bytes' > "$T/staging/2026/05/IMG_1_HEVC.MOV"
  printf 'other-bytes'  > "$T/staging/2026/05/IMG_2.HEIC"
  STILL_KEY="$(gp_hash "$T/staging/2026/05/IMG_1.HEIC")"
  sqlite3 "$DB" "insert into ServerPhotos values ('AF1QmediaKeyForTheStill', '$STILL_KEY');"
  # A decoy row with an empty key: it must never match anything.
  sqlite3 "$DB" "insert into ServerPhotos values ('AF1QemptyKey', '');"

  check "the database is found by its account-suffixed name" test "$(gp_db_path)" = "$DB"
  check "opening it reports ready" gp_db_open
  # The decoy is dropped at the dump, not at the lookup: an empty key must
  # never be a row a file could match, and a file whose hash somehow came out
  # empty would otherwise "match" it.
  check "the empty key is not in the table at all" test "$(gp_db_rows)" = 1
  key="$(gp_present "$T/staging/2026/05/IMG_1.HEIC")"
  check "a file Google holds is PRESENT" test "$?" = 0
  check "and its media key is on stdout" test "$key" = AF1QmediaKeyForTheStill
  check "a file Google does not hold is ABSENT" test "$(rc_of gp_present "$T/staging/2026/05/IMG_2.HEIC")" = 1
  check "a file that is not there is UNKNOWN, never absent" test "$(rc_of gp_present "$T/staging/2026/05/nope.HEIC")" = 2
  # THE RULE THIS WHOLE FEATURE RESTS ON: the video half of a Live Photo has no
  # row of its own, so asking about its bytes can only answer "absent".
  check "the motion half is not in the database by its own bytes" test "$(rc_of gp_present "$T/staging/2026/05/IMG_1_HEVC.MOV")" = 1
fi

echo "the Live Photo pairing"
check "a _HEVC.MOV resolves to its still" test "$(gp_still_of "$STAGING" 2026/05/IMG_1_HEVC.MOV)" = 2026/05/IMG_1.HEIC
printf 'plain-motion' > "$T/staging/2026/05/IMG_2.MOV"
check "a plain .MOV beside a still resolves to it" test "$(gp_still_of "$STAGING" 2026/05/IMG_2.MOV)" = 2026/05/IMG_2.HEIC
printf 'standalone' > "$T/staging/2026/05/00000955-VIDEO.MOV"
check "a video with no still beside it resolves to nothing" test "$(rc_of gp_still_of "$STAGING" 2026/05/00000955-VIDEO.MOV)" = 1
check "a still is not the video half of anything" test "$(rc_of gp_still_of "$STAGING" 2026/05/IMG_1.HEIC)" = 1

echo "the tick pass"
if command -v sqlite3 >/dev/null 2>&1; then
  gp_db_close
  LOGGED=""; MAC_PRESENT_N=0
  newf="$T/new.list"
  printf '2026/05/IMG_1.HEIC\n2026/05/IMG_1_HEVC.MOV\n2026/05/IMG_2.HEIC\n' > "$newf"
  : > "$MAC_STATE"; : > "$RECLAIM_PENDING"; rm -f "$MAC_PRESENT"
  mac_presence_pass "$newf"
  check "only the absent file is left to upload" test "$(tr '\n' ' ' < "$newf")" = "2026/05/IMG_2.HEIC "
  check "the still and its motion half are both present" test "$MAC_PRESENT_N" = 2
  check "both carry the present state" test "$(mac_state_rels present | sort | tr '\n' ' ')" = "2026/05/IMG_1.HEIC 2026/05/IMG_1_HEVC.MOV "
  check "and both reach the reclaim list, so the asset can leave iCloud" test "$(sort "$RECLAIM_PENDING" | tr '\n' ' ')" = "2026/05/IMG_1.HEIC 2026/05/IMG_1_HEVC.MOV "
  check "the media key is recorded beside them, not in the state file" grep -q 'AF1QmediaKeyForTheStill' "$MAC_PRESENT"
  check "and never in the state file, which the menu bar reads" none grep -q 'AF1Q' "$MAC_STATE"
  check "the log says what it found" grep -q 'already in Google Photos: 2 of 3 checked' <<<"$LOGGED"
  check "a present file counts as handled, so no run hands it over" grep -qx '2026/05/IMG_1.HEIC' <<<"$(mac_handled)"
fi

echo "an unreadable database uploads, it never keeps"
gp_db_close
GP_STORE_DIR="$T/no-such-store"
LOGGED=""; MAC_PRESENT_N=0
: > "$MAC_STATE"; : > "$RECLAIM_PENDING"
newf="$T/new2.list"
printf '2026/05/IMG_1.HEIC\n2026/05/IMG_1_HEVC.MOV\n' > "$newf"
mac_presence_pass "$newf"
check "every file stays on the upload list" test "$(count_lines "$newf")" = 2
check "nothing is marked present" test "$MAC_PRESENT_N" = 0
check "nothing reaches the reclaim list" test "$(count_lines "$RECLAIM_PENDING")" = 0
check "and the run says why, once" grep -q 'is not readable' <<<"$LOGGED"
check "gp_present alone answers UNKNOWN, not absent" test "$(rc_of gp_present "$T/staging/2026/05/IMG_1.HEIC")" = 2

echo "the off switch"
gp_db_close
GP_STORE_DIR="$T/store"
# shellcheck disable=SC2034  # read by lib/mac.sh
PRESENCE_CHECK=0
LOGGED=""; MAC_PRESENT_N=0
printf '2026/05/IMG_1.HEIC\n' > "$newf"
mac_presence_pass "$newf"
check "PRESENCE_CHECK=0 checks nothing at all" test "$(count_lines "$newf")" = 1 -a "$MAC_PRESENT_N" = 0
check "and does not even open the database" test -z "$LOGGED"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
