#!/usr/bin/env bash
# The Messages source, judged by effect on a scratch HOME: lib/messages.sh
# sourced the way avd-photos-sync sources it (set -uo pipefail), against a
# fixture chat.db built here with the real schema shape (attachment ->
# message_attachment_join -> message -> chat_message_join -> chat) and fixture
# files on disk. No Messages, no Google Photos, no network.
#
# What it pins down: which extensions the scan takes and which it refuses, the
# staged path's shape, that gp_present's "already there" answer stages nothing,
# that a second scan is a no-op (the ledger's guid+size test), that a file the
# database names but the disk does not have is counted and not recorded, and
# that an unreadable Attachments folder (no Full Disk Access) logs one line and
# leaves the tick alone.
#
# Usage: test/messages.sh          (also: /bin/bash test/messages.sh, bash 3.2)

set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home"
export AVD_PHOTOS_CONFIG_DIR="$T/config" AVD_PHOTOS_STATE_DIR="$T/state"
mkdir -p "$HOME" "$T/config" "$T/state" "$T/staging" "$T/messages/Attachments"
printf 'ICLOUD_USERNAME=t@example.invalid\nSTAGING="%s/staging"\nPHOTOS_BACKEND=mac\nMESSAGES_SOURCE=1\nMESSAGES_DIR="%s/messages/Attachments"\nMESSAGES_DB="%s/messages/chat.db"\n' \
  "$T" "$T" "$T" > "$T/config/config"

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
# shellcheck disable=SC1091
. "$HERE/../lib/messages.sh"

sqlite() { if [ -x /usr/bin/sqlite3 ]; then /usr/bin/sqlite3 "$@"; else sqlite3 "$@"; fi; }

# ── The fixture ──────────────────────────────────────────────────────────────
# Dates are Apple's: nanoseconds since 2001-01-01, which is 978307200 in unix
# time. One row is left at created_date = 0 so the fallback to the message's
# own date is exercised rather than assumed.
A="$T/messages/Attachments"
DB="$T/messages/chat.db"
JUL=1752580800    # 2025-07-15 12:00:00 UTC
AUG=1755259200    # 2025-08-15 12:00:00 UTC
ns() { printf '%s\n' "$((($1 - 978307200) * 1000000000))"; }

mkfile() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
mkfile "$A/00/photo one.HEIC"   "heic-bytes-one"
mkfile "$A/01/clip.MOV"         "mov-bytes-one"
mkfile "$A/02/photo.heic"       "heic-bytes-present"
mkfile "$A/03/link.pluginPayloadAttachment" "rich-link-payload"
mkfile "$A/04/voice.caf"        "audio"
mkfile "$A/05/doc.pdf"          "document"
mkfile "$A/06/late.PNG"         "png-bytes-fallback-date"
# 07/gone.jpg is deliberately NOT created: a row whose bytes are gone.

sqlite "$DB" <<SQL
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT);
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, text TEXT);
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT,
                         total_bytes INTEGER, mime_type TEXT, created_date INTEGER,
                         hide_attachment INTEGER DEFAULT 0);
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
INSERT INTO chat VALUES (1, '+15550001111', 'A Name That Must Never Be Read');
INSERT INTO chat VALUES (2, 'someone@example.invalid', NULL);
INSERT INTO message VALUES (1, $(ns $JUL), 'message text that must never be read');
INSERT INTO message VALUES (2, $(ns $JUL), NULL);
INSERT INTO message VALUES (3, $(ns $JUL), NULL);
INSERT INTO message VALUES (4, $(ns $JUL), NULL);
INSERT INTO message VALUES (5, $(ns $JUL), NULL);
INSERT INTO message VALUES (6, $(ns $JUL), NULL);
INSERT INTO message VALUES (7, $(ns $AUG), NULL);
INSERT INTO message VALUES (8, $(ns $JUL), NULL);
INSERT INTO attachment VALUES (1, 'guid-photo-one', '~/../messages/Attachments/00/photo one.HEIC', 14, 'image/heic', $(ns $JUL), 0);
INSERT INTO attachment VALUES (2, 'guid-clip',      '$A/01/clip.MOV',        13, 'video/quicktime', $(ns $JUL), 0);
INSERT INTO attachment VALUES (3, 'guid-present',   '$A/02/photo.heic',      18, 'image/heic', $(ns $JUL), 0);
INSERT INTO attachment VALUES (4, 'guid-plugin',    '$A/03/link.pluginPayloadAttachment', 17, NULL, $(ns $JUL), 0);
INSERT INTO attachment VALUES (5, 'guid-audio',     '$A/04/voice.caf',       5,  'audio/x-caf', $(ns $JUL), 0);
INSERT INTO attachment VALUES (6, 'guid-doc',       '$A/05/doc.pdf',         8,  'application/pdf', $(ns $JUL), 0);
INSERT INTO attachment VALUES (7, 'guid-late',      '$A/06/late.PNG',        23, 'image/png', 0, 0);
INSERT INTO attachment VALUES (8, 'guid-gone',      '$A/07/gone.jpg',        99, 'image/jpeg', $(ns $JUL), 0);
INSERT INTO message_attachment_join VALUES (1,1),(2,2),(3,3),(4,4),(5,5),(6,6),(7,7),(8,8);
INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(1,5),(1,6),(2,7),(2,8);
SQL

# The sibling's presence check (lib/presence.sh, feat/presence-and-keep), stubbed
# here to the contract this source calls it by: 0 with a media key on stdout for
# a file Google Photos already holds, 1 for one it does not.
gp_present() {
  case "$1" in *"/02/photo.heic") printf 'AF1QipFAKEKEY\n'; return 0 ;; esac
  return 1
}

sha8() { msg_sha1 "$1" | cut -c1-8; }
rows() { [ -r "$MSG_STATE" ] && grep -c . "$MSG_STATE" || echo 0; }
field() { awk -F'\t' -v g="$1" -v f="$2" '$1 == g { print $f }' "$MSG_STATE"; }

echo "the scan"
msg_scan
check "both media files of the first chat are staged" \
  test -f "$STAGING/messages/$(date -r $JUL +%Y/%m)/$(sha8 "$A/00/photo one.HEIC")-photo one.HEIC" \
   -a  -f "$STAGING/messages/$(date -r $JUL +%Y/%m)/$(sha8 "$A/01/clip.MOV")-clip.MOV"
check "a rich-link payload, audio and a document are never staged" \
  test "$(find "$STAGING" -name '*.pluginPayloadAttachment' -o -name '*.caf' -o -name '*.pdf' | wc -l | tr -d ' ')" = 0
check "and they are not in the ledger either" test "$(field guid-plugin 3)$(field guid-audio 3)$(field guid-doc 3)" = ""
check "the video is recorded as video, the photo as image" \
  test "$(field guid-clip 10)" = video -a "$(field guid-photo-one 10)" = image
check "a file Google Photos already holds is present, not staged" \
  test "$(field guid-present 3)" = present -a "$(field guid-present 5)" = "-"
check "and no copy of it was made" test ! -e "$STAGING/messages/$(date -r $JUL +%Y/%m)/$(sha8 "$A/02/photo.heic")-photo.heic"
check "a row whose file is gone is counted, not recorded" \
  test "$(field guid-gone 3)" = "" && grep -q '1 with no bytes on disk' <<<"$LOGGED"
check "the chat id and the handle id are recorded, and nothing else about the conversation" \
  test "$(field guid-photo-one 6)/$(field guid-photo-one 7)" = "1/+15550001111"
check "no display name and no message text reach the ledger" \
  none grep -qE 'A Name That Must Never Be Read|message text that must never' "$MSG_STATE"
check "created_date 0 falls back to the message's own date" \
  test "$(field guid-late 8)" = "$(date -r $AUG +%Y-%m-%d)" -a "$(field guid-late 6)" = 2
check "the staged path carries the date's year and month" \
  test -f "$STAGING/messages/$(date -r $AUG +%Y/%m)/$(sha8 "$A/06/late.PNG")-late.PNG"
check "the log says what it did" grep -qE 'Messages source: 5 media attachment\(s\) seen, 4 new, 3 staged, 1 already in Google Photos, 1 with no bytes' <<<"$LOGGED"
check "the counters agree with it" test "$MSG_STAGED/$MSG_PRESENT/$MSG_SEEN" = "3/1/5"

echo "a half-copied file"
# The staging enumeration selects on the extension alone, so a partial copy
# must not carry one: a leftover from a killed run would otherwise be handed to
# Google Photos as a truncated photo, and confirmed.
STALE="$STAGING/messages/$(date -r $JUL +%Y/%m)/.incoming-deadbeef-half.HEIC.part"
printf 'half' > "$STALE"
check "a partial copy cannot end in a media extension" \
  test "$(find "$STAGING" -type f | grep -icE '\.(heic|mov|png|jpg)$' | tr -d ' ')" = 3
msg_scan
check "and a leftover is swept by the next scan" test ! -e "$STALE"

echo "a second scan"
BEFORE="$(rows)"; LOGGED=""
msg_scan
check "nothing is staged twice" test "$(rows)" = "$BEFORE" -a "$MSG_STAGED" = 0 -a "$MSG_NEW" = 0
check "and it says so" grep -q '0 new, 0 staged' <<<"$LOGGED"
check "a staged file removed from staging is not re-staged either (the ledger decides, not the tree)" \
  test "$(rm -f "$STAGING/messages/$(date -r $JUL +%Y/%m)/$(sha8 "$A/01/clip.MOV")-clip.MOV"; msg_scan; echo "$MSG_STAGED")" = 0

echo "a new attachment arrives"
LOGGED=""
mkfile "$A/08/new.JPG" "a new photo"
sqlite "$DB" "INSERT INTO message VALUES (9, $(ns $AUG), NULL);
              INSERT INTO attachment VALUES (9, 'guid-new', '$A/08/new.JPG', 11, 'image/jpeg', $(ns $AUG), 0);
              INSERT INTO message_attachment_join VALUES (9,9);
              INSERT INTO chat_message_join VALUES (2,9);"
msg_scan
check "only the new one is staged" test "$MSG_STAGED" = 1 -a "$MSG_NEW" = 1
check "and it landed under its own month" test -f "$STAGING/messages/$(date -r $AUG +%Y/%m)/$(sha8 "$A/08/new.JPG")-new.JPG"

echo "the same file again, from another conversation"
LOGGED=""
mkfile "$A/09/forwarded.JPG" "a new photo"   # same bytes, a different attachment
sqlite "$DB" "INSERT INTO message VALUES (10, $(ns $AUG), NULL);
              INSERT INTO attachment VALUES (10, 'guid-fwd', '$A/09/forwarded.JPG', 11, 'image/jpeg', $(ns $AUG), 0);
              INSERT INTO message_attachment_join VALUES (10,10);
              INSERT INTO chat_message_join VALUES (1,10);"
msg_scan
check "a different attachment with the same bytes is its own row (the key is guid AND sha1)" \
  test "$(field guid-fwd 3)" = staged -a "$(field guid-fwd 2)" = "$(field guid-new 2)"

echo "no Full Disk Access"
LOGGED=""; BEFORE="$(rows)"
chmod 000 "$A"
msg_scan; rc=$?
chmod 755 "$A"
check "the scan does not fail the tick" test "$rc" = 0
check "it logs exactly one line, naming the reason" \
  test "$(grep -c . <<<"$LOGGED")" = 1 && grep -q 'Messages source skipped: cannot read' <<<"$LOGGED"
check "and changes no ledger" test "$(rows)" = "$BEFORE"

echo "off by default"
LOGGED=""
# shellcheck disable=SC2034  # read by msg_enabled in lib/messages.sh
MESSAGES_SOURCE=0
msg_scan
check "MESSAGES_SOURCE=0 is a no-op, and silent" test -z "$LOGGED"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
