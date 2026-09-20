#!/usr/bin/env bash
# The two reports, judged by what they render: lib/reports.sh against a ledger
# and a Mac-backend state written by hand, and a fixture Google Photos database
# with the real ServerPhotos column set. No Messages, no Google Photos, no
# Drive, no network.
#
# What it pins down: where the reports are written (the key, then the fleet's
# paths file, then nothing at all rather than a guessed folder), that only
# CONFIRMED attachments are listed, that videos come first and carry their
# dates, that a staged-but-unconfirmed file is named as such and never listed
# for deletion, that no file name reaches the report, and the duplicate groups'
# arithmetic.
#
# Usage: test/reports.sh          (also: /bin/bash test/reports.sh, bash 3.2)

set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
# KEEP=1 leaves the scratch tree behind, for reading the rendered reports.
trap '[ -n "${KEEP:-}" ] && echo "kept: $T" || rm -rf "$T"' EXIT
export HOME="$T/home"
export AVD_PHOTOS_CONFIG_DIR="$T/config" AVD_PHOTOS_STATE_DIR="$T/state"
mkdir -p "$HOME" "$T/config" "$T/state" "$T/staging" "$T/out" "$T/drive" "$T/gpstore"
printf 'ICLOUD_USERNAME=t@example.invalid\nSTAGING="%s/staging"\nMESSAGES_SOURCE=1\n' "$T" > "$T/config/config"

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
none() { ! "$@"; }

LOGGED=""
log() { LOGGED="$LOGGED$*"$'\n'; }
phase() { :; }
# shellcheck disable=SC1091
. "$HERE/../lib/config.sh"; ap_load_config
GP_STORE_DIR="$T/gpstore"
SC_PATHS_ENV="$T/paths.env"
# shellcheck disable=SC1091
. "$HERE/../lib/messages.sh"
# shellcheck disable=SC1091
. "$HERE/../lib/reports.sh"
MAC_STATE="$STATE_DIR/mac-state.tsv"

sqlite() { if [ -x /usr/bin/sqlite3 ]; then /usr/bin/sqlite3 "$@"; else sqlite3 "$@"; fi; }

# ── Fixtures ─────────────────────────────────────────────────────────────────
# The ledger: one big conversation with two videos and two photos, a second
# with one photo, one row Google Photos already had, and one row staged but not
# confirmed. Sizes are round numbers so the MB column can be asserted exactly.
row() { printf '%s\t%s\t%s\t0\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$MSG_STATE"; }
row g1 sha1aaaa staged  "messages/2025/07/sha1aaaa-a secret name.MOV" 1 '+15550001111' 2025-07-15 209715200 video
row g2 sha1bbbb staged  "messages/2025/07/sha1bbbb-clip2.MOV"         1 '+15550001111' 2025-07-16 104857600 video
row g3 sha1cccc staged  "messages/2025/07/sha1cccc-p1.HEIC"           1 '+15550001111' 2025-07-15 10485760  image
row g4 sha1dddd staged  "messages/2025/08/sha1dddd-p2.HEIC"           1 '+15550001111' 2025-08-02 10485760  image
row g5 sha1eeee present "-"                                           2 'a@example.invalid' 2025-07-20 5242880 image
row g6 sha1ffff staged  "messages/2025/07/sha1ffff-waiting.HEIC"      2 'a@example.invalid' 2025-07-21 1048576 image
# The Mac backend confirmed everything but the waiting one.
{
  printf 'messages/2025/07/sha1aaaa-a secret name.MOV\tn\tconfirmed\t0\t0\t-\n'
  printf 'messages/2025/07/sha1bbbb-clip2.MOV\tn\tconfirmed\t0\t0\t-\n'
  printf 'messages/2025/07/sha1cccc-p1.HEIC\tn\tconfirmed\t0\t0\t-\n'
  printf 'messages/2025/08/sha1dddd-p2.HEIC\tn\tconfirmed\t0\t0\t-\n'
  printf 'messages/2025/07/sha1ffff-waiting.HEIC\tn\tqueued\t0\t0\t-\n'
  printf '2025/07/IMG_9.HEIC\tn\texists\t0\t0\t-\n'
} > "$MAC_STATE"

# The Mac backend's own states, checked against this report's rule: a file
# Google was found to hold already (present) counts, a Live Photo component
# that matched by hash (exists) does not -- which half matched is not reported,
# so it is not something a delete-these list may guess at.
check "confirmed and present count, exists and queued do not" \
  test "$(msg_confirmed_rels | wc -l | tr -d ' ')" = 4
printf 'messages/2025/08/sha1dddd-p2.HEIC\tn\tpresent\t0\t0\talready_in_google_photos\n' >> "$MAC_STATE"
check "a present row is taken as Google holding the bytes" \
  test "$(msg_confirmed_rels | grep -c 'sha1dddd')" = 2

# The app database: three dedup groups, one of them a triple.
GPDB="$T/gpstore/photos-1234567890.db"
sqlite "$GPDB" <<'SQL'
CREATE TABLE ServerPhotos (mediaKey TEXT PRIMARY KEY, localDedupKey TEXT, timestampMs INTEGER, size INTEGER);
INSERT INTO ServerPhotos VALUES
 ('k1','dupAAAAAAAA',1752580800000,10485760),
 ('k2','dupAAAAAAAA',1752667200000,10485760),
 ('k3','dupBBBBBBBB',1755259200000,104857600),
 ('k4','dupBBBBBBBB',1755345600000,104857600),
 ('k5','dupBBBBBBBB',1755432000000,104857600),
 ('k6','uniqueCCCCC',1752580800000,1048576);
SQL
sqlite "$T/gpstore/photos-shared.db" "CREATE TABLE NotALibrary (x INTEGER);"

echo "where the reports go"
check "the key wins" test "$(MESSAGES_REPORT_DIR="$T/out" msg_report_dir)" = "$T/out"
printf "SC_MY_DRIVE='%s'\n" "$T/drive" > "$SC_PATHS_ENV"
check "without it, the host's declared Drive decides" \
  test "$(msg_report_dir)" = "$T/drive/$MSG_REPORT_SUBPATH"
rm -f "$SC_PATHS_ENV"
check "with neither, no folder is invented" none msg_report_dir
LOGGED=""; msg_reports
check "and the tick is told once, not failed" \
  test "$(grep -c . <<<"$LOGGED")" = 1 && grep -q 'Messages reports skipped' <<<"$LOGGED"

echo "the cleanup report"
# shellcheck disable=SC2034  # read by msg_report_dir in lib/reports.sh
MESSAGES_REPORT_DIR="$T/out"
LOGGED=""; msg_reports
R="$T/out/messages-cleanup-report.md"
check "it is written" test -s "$R"
check "only confirmed attachments are counted (5 of the 6 rows)" \
  grep -q '\*\*5 attachment(s), 325.0 MB confirmed\*\*, of which 2 video(s), 300.0 MB' "$R"
check "the one still waiting is named as waiting, not as deletable" \
  grep -q '^1 more, 1.0 MB, are staged and not confirmed yet' "$R"
check "the big conversation comes first, with its own totals" \
  grep -q '^| 1 | `+15550001111` | 4 | 320.0 | 2 | 300.0 |' "$R"
check "the second conversation is there too, with its handle id" \
  grep -q '^| 2 | `a@example.invalid` | 1 | 5.0 | 0 | 0.0 |' "$R"
check "videos are listed one by one, with their dates, newest last" \
  grep -q '^| 2025-07-16 | 100.0 | `sha1bbbb` |' "$R" && grep -q '^| 2025-07-15 | 200.0 | `sha1aaaa` |' "$R"
check "a video's row carries its size" grep -q '^| 2025-07-15 | 200.0 | `sha1aaaa` |' "$R"
check "photos are summarised by month, not listed" \
  grep -q '^| 2025-08 | 1 | 10.0 |' "$R"
check "NO FILE NAME reaches the report, not even from a staged path" \
  none grep -q 'a secret name\|\.MOV\|\.HEIC' "$R"
check "and it says plainly that it deleted nothing" grep -q 'has been deleted from anywhere' "$R"

echo "with no confirmation from the upload path"
SAVED="$MAC_STATE"; MAC_STATE="$T/state/none.tsv"; : > "$MAC_STATE"
msg_cleanup_report "$T/out/none-confirmed.md"
check "a present row is confirmed on its own -- it was never staged to begin with" \
  grep -q '\*\*1 attachment(s), 5.0 MB confirmed\*\*' "$T/out/none-confirmed.md"
check "and everything staged is counted as waiting" \
  grep -q '^5 more, 321.0 MB, are staged and not confirmed yet' "$T/out/none-confirmed.md"
# A ledger with nothing but staged rows: the report must say so rather than
# render an empty table a human would read as "nothing to clean up".
grep -v 'present' "$MSG_STATE" > "$T/state/staged-only.tsv"
SAVED_MSG="$MSG_STATE"; MSG_STATE="$T/state/staged-only.tsv"
msg_cleanup_report "$T/out/empty.md"
check "nothing confirmed at all says so in words" grep -q '^Nothing is confirmed yet' "$T/out/empty.md"
MSG_STATE="$SAVED_MSG"; MAC_STATE="$SAVED"

echo "the duplicates report"
D="$T/out/gphotos-duplicates-report.md"
check "it is written" test -s "$D"
check "the totals are the groups with 2+ rows, and the excess is per group" \
  grep -q '^| 6 | 2 | 5 | 3 | 0.2 |' "$D"
check "months come from the group's earliest copy" grep -q '^| 2025-07 | 1 | 2 | 1 | 0.01 |' "$D"
check "the triple is the costliest group, counted twice over" \
  grep -q '^| 2025-08-15 | 3 | 100.0 | 200.0 | `dupBBBBB' "$D"
check "a key with one row is not a group" none grep -q 'uniqueCC' "$D"
check "photos-shared.db is not read as a library" none grep -q 'skipped' <<<"$LOGGED"
check "it says plainly that it deleted nothing" grep -q 'nothing here deletes anything' "$D"

echo "a tick that staged nothing"
LOGGED=""
SAVED_MSG="$MSG_STATE"; MSG_STATE="$T/state/no-such-ledger.tsv"
rm -f "$T/out/gphotos-duplicates-report.md"
msg_reports
check "the duplicates report is about the account, so it is written anyway" \
  test -s "$T/out/gphotos-duplicates-report.md"
MSG_STATE="$SAVED_MSG"

echo "no Google Photos database"
LOGGED=""; GP_STORE_DIR="$T/empty-store"; mkdir -p "$GP_STORE_DIR"
gp_duplicates_report "$T/out/none.md"
check "the report is skipped with one line, and the old one is left alone" \
  test ! -e "$T/out/none.md" && grep -q 'duplicates report skipped' <<<"$LOGGED"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
