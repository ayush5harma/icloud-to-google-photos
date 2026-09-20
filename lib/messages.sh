#!/usr/bin/env bash
# A SECOND SOURCE OF MEDIA FOR THE TICK: the photos and videos people sent in
# Messages. iCloud Photos is not the only place originals accumulate -- on this
# Mac, measured 2026-09-20, ~/Library/Messages/Attachments held 1,435 media
# attachments and 3.17 GB, of which video was 74 % of the bytes in 8 % of the
# files. Those bytes are backed up nowhere: the photo pipeline never looked at
# them, and deleting a conversation takes them with it.
#
# What this does, and deliberately does not do:
#   - it READS. Messages is never modified, no attachment is ever deleted, and
#     the live chat.db is never opened: every query runs against a copy taken
#     with its -wal and -shm together (a copy without the WAL is a stale or
#     torn view, and opening the live file risks the database Messages is
#     using).
#   - it STAGES a copy of each new image or video into the pipeline's own
#     staging tree, under a "messages/" prefix, where the normal upload path
#     picks it up exactly like an iCloud original. Nothing else about the tick
#     changes.
#   - it ASKS gp_present (lib/presence.sh) first: an attachment whose bytes
#     Google Photos already holds -- usually because the same photo reached the
#     account from the phone -- is recorded as confirmed and never staged, so
#     the common case costs one hash and no bytes.
#
# OFF BY DEFAULT (MESSAGES_SOURCE=0). Reading ~/Library/Messages needs Full
# Disk Access, which the launchd-spawned half of this pipeline may not have;
# when the folder is unreadable the source logs one line and the tick carries
# on. A Messages source that fails a photo sync would be a bad trade.

# ONE ROW PER ATTACHMENT, keyed by the attachment's GUID *and* the SHA-1 of the
# file's bytes: the GUID is Messages' own identity for the attachment and the
# hash is what Google Photos dedups on, and a row needs both to mean "this
# exact file, from this exact attachment, has been dealt with". Tab-separated:
#
#   guid    the attachment.guid from chat.db -- stable across re-scans
#   sha1    SHA-1 of the file's bytes, hex. With guid, the key.
#   state   staged     copied into the staging tree; the upload path has it
#           present    Google Photos already holds these bytes (gp_present);
#                      recorded as confirmed, never staged, never uploaded
#   stamp   epoch of the row's creation
#   rel     the staging-relative path of the copy, or "-" for a present row
#   chat    chat.ROWID -- an id, never a display name
#   handle  chat.chat_identifier: a phone number, an email, or a group id.
#           The reports quote this; a contact's NAME is never read at all.
#   date    the attachment's own date, YYYY-MM-DD (local), for the report
#   bytes   size on disk at scan time; with guid it is the cheap re-scan test
#   kind    image | video
MSG_STATE="$STATE_DIR/messages-state.tsv"
# The staging sub-tree this source owns. Under STAGING so the existing
# enumerate_staging finds the files with no change at all, and prefixed so the
# iCloud reclaim can never match one of them to an iCloud asset: it rebuilds
# candidate paths as "YYYY/MM/<name>", which no "messages/..." path can equal.
MSG_PREFIX="messages"
# Extensions this source takes. Everything else in that folder is skipped by
# name: pluginpayloadattachment (219 files here) is rich-link and sticker
# payload, .caf is audio, .pdf/.html/.plist/.csv are documents -- none of them
# is camera media and Google Photos would reject or misfile them.
MSG_EXTS="heic heif jpg jpeg png gif webp mov mp4 m4v"

# Counters for the one line this source logs, and for the caller's own report.
MSG_SEEN=0        # attachment rows with a media extension and bytes on disk
MSG_NEW=0         # not in the ledger before this run
MSG_STAGED=0      # copied into staging for the upload path
MSG_PRESENT=0     # gp_present said Google Photos already has them
MSG_SKIPPED=0     # not media, or unreadable, or gone from disk
MSG_UNREADABLE="" # why the source was skipped, when it was

msg_enabled() { [ "${MESSAGES_SOURCE:-0}" = "1" ]; }

# macOS ships both of these; a PATH copy is used only if the system one is
# missing. Named absolutely for the same reason lib/fs.sh names stat: a
# launchd-seeded PATH can put a GNU build first, and GNU shasum is not the one
# whose output this parses.
msg_sqlite() { if [ -x /usr/bin/sqlite3 ]; then /usr/bin/sqlite3 "$@"; else sqlite3 "$@"; fi; }
msg_sha1() { if [ -x /usr/bin/shasum ]; then /usr/bin/shasum -a 1 "$1"; else shasum -a 1 "$1"; fi 2>/dev/null | cut -d' ' -f1; }

# image | video | "" (not media), from the extension alone, case-insensitively.
msg_kind() {
  local ext="${1##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  case " $MSG_EXTS " in *" $ext "*) ;; *) return 1 ;; esac
  case "$ext" in mov|mp4|m4v) printf 'video\n' ;; *) printf 'image\n' ;; esac
}

# FULL DISK ACCESS IS THE WHOLE PREREQUISITE, and a process without it gets
# EPERM on the directory itself -- which a bare `[ -d ]` reports exactly like
# "does not exist". So the probe keeps stderr and reports what macOS said,
# because "no Messages attachments on this Mac" and "this process may not look"
# need different answers from a human.
msg_readable() {
  MSG_UNREADABLE=""
  local err
  err="$(/bin/ls -1 "$MESSAGES_DIR" 2>&1 >/dev/null)"
  if [ -n "$err" ]; then MSG_UNREADABLE="${err##*: }"; return 1; fi
  err="$(/usr/bin/head -c 16 "$MESSAGES_DB" 2>&1 >/dev/null)"
  if [ -n "$err" ]; then MSG_UNREADABLE="${err##*: }"; return 1; fi
  return 0
}

# A COPY, WITH ITS -wal AND -shm. The live chat.db is never opened: Messages
# holds it open with WAL journalling, so a reader that takes the .db alone sees
# the database as it was at the last checkpoint (missing, here, everything
# since) and a writer-shaped open of the live file is how a Messages database
# gets corrupted. The copy is opened READ-WRITE on purpose -- SQLite must
# replay the copied WAL to present a consistent view, and it can only do that
# in a file it may write. It is a copy in a temporary directory; the originals
# are never touched.
msg_db_snapshot() {  # <destination directory> -> <destination>/chat.db
  local dest="$1" f
  /bin/cp -p "$MESSAGES_DB" "$dest/chat.db" 2>/dev/null || return 1
  for f in wal shm; do
    [ -f "$MESSAGES_DB-$f" ] && { /bin/cp -p "$MESSAGES_DB-$f" "$dest/chat.db-$f" 2>/dev/null || return 1; }
  done
  return 0
}

# One row per attachment: guid, path, date (unix), chat id, handle id. The
# database's own total_bytes is deliberately not selected: the size that
# decides anything here is the one on disk, and the two disagree (a row whose
# bytes were never fully downloaded still carries its full size).
#
# Apple's dates are nanoseconds since 2001-01-01 in every current macOS and
# SECONDS since that epoch in old databases, so the CASE picks the unit by
# magnitude rather than trusting one shape; 978307200 is that epoch in unix
# time. An attachment with no created_date falls back to its message's date.
# The join is attachment -> message_attachment_join -> message ->
# chat_message_join -> chat, collapsed to the LOWEST chat id per attachment, so
# the same file forwarded into two conversations is counted once.
#
# NOTHING HERE READS TEXT OR A NAME: no message.text, no chat.display_name, no
# handle beyond the identifier the report is allowed to print. A filename
# carrying a tab or a newline is excluded rather than parsed, because it would
# split this tab-separated stream into fields that no longer line up.
msg_rows() {  # <db copy>
  msg_sqlite -batch -noheader -separator "$(printf '\t')" "$1" "
    SELECT a.guid,
           a.filename,
           CAST((CASE WHEN COALESCE(NULLIF(a.created_date, 0), j.mdate) > 1000000000000
                      THEN COALESCE(NULLIF(a.created_date, 0), j.mdate) / 1000000000
                      ELSE COALESCE(NULLIF(a.created_date, 0), j.mdate) END) + 978307200 AS INTEGER),
           ch.ROWID,
           ch.chat_identifier
    FROM attachment a
    JOIN (SELECT maj.attachment_id AS aid, MIN(cmj.chat_id) AS cid, MIN(m.date) AS mdate
          FROM message_attachment_join maj
          JOIN message m ON m.ROWID = maj.message_id
          JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
          GROUP BY maj.attachment_id) j ON j.aid = a.ROWID
    JOIN chat ch ON ch.ROWID = j.cid
    WHERE a.filename IS NOT NULL AND a.filename <> ''
      AND instr(a.filename, char(10)) = 0
      AND instr(a.filename, char(9)) = 0
    ORDER BY a.ROWID;" 2>/dev/null
}

# THE CHEAP RE-SCAN, and the reason the ledger carries the byte size. A tick
# runs every 15 minutes; hashing 3 GB of attachments every time would cost more
# than the whole photo sync. An attachment whose GUID is already recorded at
# the same size is the same file -- Messages content-addresses attachments and
# never rewrites one in place -- so it is skipped before it is read at all. The
# hash still decides identity when there is any doubt: a row whose size moved
# is hashed and matched on guid+sha1 (msg_known_key) before anything is staged.
msg_known() {  # <guid> <bytes>
  [ -r "$MSG_STATE" ] || return 1
  awk -F'\t' -v g="$1" -v b="$2" '$1 == g && $9 == b { f = 1; exit } END { exit f ? 0 : 1 }' "$MSG_STATE"
}

msg_known_key() {  # <guid> <sha1>
  [ -r "$MSG_STATE" ] || return 1
  awk -F'\t' -v g="$1" -v s="$2" '$1 == g && $2 == s { f = 1; exit } END { exit f ? 0 : 1 }' "$MSG_STATE"
}

# Append one row. Appended rather than rewritten: a row is only ever added, and
# its key (guid+sha1) is unique, so there is nothing to rewrite and no window
# in which the file is half a ledger.
msg_state_add() {  # <guid> <sha1> <state> <rel> <chat> <handle> <date> <bytes> <kind>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$(date +%s)" "$4" "$5" "$6" "$7" "$8" "$9" >> "$MSG_STATE"
}

# The staging-relative path a file gets: messages/YYYY/MM/<8 hex of sha1>-<its
# own name>. The hash prefix is what makes the name unique -- two conversations
# routinely hold "IMG_0001.HEIC" -- and it is also the id the cleanup report
# quotes, so a line in the report can be tied back to a staged file without the
# report ever carrying a file name.
msg_rel() {  # <sha1> <original path> <unix date>
  local base name
  base="$(basename -- "$2")"
  # Control characters cannot reach a path this pipeline builds: they break
  # every ledger that is read back with awk -F'\t'.
  name="$(printf '%s' "$base" | tr -d '\000-\037')"
  printf '%s/%s/%s-%s\n' "$MSG_PREFIX" "$(date -r "$3" +%Y/%m 2>/dev/null || echo "0000/00")" "${1:0:8}" "$name"
}

# Copy into staging through a name the staging enumeration cannot match, then
# rename: the same tick lists the tree a moment later and hands what it finds
# to Google Photos, so a half-copied file must be invisible to that listing
# until it is whole. A DOT-NAME IS NOT ENOUGH for that -- enumerate_staging
# selects on the extension alone and would happily hand over
# ".incoming-<name>.MOV" -- so the partial file ends in ".part" as well, which
# also makes a leftover from a killed run sweepable by name (msg_scan does it).
# The size is checked before the rename for the same reason mac_handoff checks
# it: a short copy that is renamed is a truncated photo with a media key.
msg_stage() {  # <source file> <staging-relative destination>
  local dst="$STAGING/$2" dir tmp src_sz dst_sz
  dir="$(dirname "$dst")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$dir/.incoming-$(basename -- "$2").part"
  src_sz="$(/usr/bin/stat -f %z "$1" 2>/dev/null || echo 0)"
  if /bin/cp -p "$1" "$tmp" 2>/dev/null; then
    dst_sz="$(/usr/bin/stat -f %z "$tmp" 2>/dev/null || echo 0)"
    if [ "$dst_sz" = "$src_sz" ] && [ "$src_sz" != 0 ]; then
      mv -f "$tmp" "$dst" && return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

# gp_present (lib/presence.sh) when it is loaded, "unknown" when it is not, so
# this source works on its own and gets cheaper the moment presence lands.
# Exit 0 = present (its media key on stdout, which is deliberately NOT stored:
# this ledger is quoted in a report that goes to a cloud folder), 1 = absent,
# anything else = could not tell.
msg_present() {  # <file> -> 0 present, 1 absent, 2 unknown
  command -v gp_present >/dev/null 2>&1 || return 2
  gp_present "$1" >/dev/null 2>&1
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# The scan: every media attachment chat.db knows about, hashed once, asked
# about once, staged once. Never fails the tick -- every exit path is 0.
msg_scan() {
  msg_enabled || return 0
  MSG_SEEN=0; MSG_NEW=0; MSG_STAGED=0; MSG_PRESENT=0; MSG_SKIPPED=0
  local t0 snap rows guid path when chat handle kind sha rel size gone=0 failed=0 secs
  t0="$(date +%s)"
  if ! msg_readable; then
    log "Messages source skipped: cannot read $MESSAGES_DIR ($MSG_UNREADABLE) — Full Disk Access is needed by whatever runs this sync"
    return 0
  fi
  snap="$(mktemp -d)" || return 0
  if ! msg_db_snapshot "$snap"; then
    log "Messages source skipped: could not copy $MESSAGES_DB (with its -wal and -shm) — nothing was read"
    rm -rf "$snap"; return 0
  fi
  # Whatever a killed run left half-copied. Named, not globbed by extension,
  # because this must never remove a staged file.
  find "$STAGING/$MSG_PREFIX" -type f -name '.incoming-*.part' -delete 2>/dev/null
  rows="$(mktemp)"
  msg_rows "$snap/chat.db" > "$rows"
  if [ ! -s "$rows" ]; then
    log "Messages source: no attachment rows in the chat.db copy — nothing to do"
    rm -rf "$snap" "$rows"; return 0
  fi
  phase "scanning Messages attachments"
  while IFS="$(printf '\t')" read -r guid path when chat handle; do
    [ -n "$guid" ] && [ -n "$path" ] || continue
    # chat.db stores the path as "~/Library/Messages/Attachments/..." -- the
    # tilde is data in a column, not a shell expansion.
    case "$path" in \~/*) path="$HOME/${path#\~/}" ;; esac
    if ! kind="$(msg_kind "$path")"; then MSG_SKIPPED=$((MSG_SKIPPED + 1)); continue; fi
    MSG_SEEN=$((MSG_SEEN + 1))
    # 24 of 1,415 rows pointed at a file that is gone (measured 2026-09-20):
    # deleted through the UI, never fully downloaded, or evicted. A row without
    # bytes is not an error, it is just nothing to back up.
    if [ ! -f "$path" ]; then gone=$((gone + 1)); continue; fi
    # An evicted stub has no timeout when read (lib/fs.sh has the measurement),
    # so it is detected from metadata and left alone.
    if /usr/bin/stat -f %Sf "$path" 2>/dev/null | grep -q dataless; then gone=$((gone + 1)); continue; fi
    size="$(/usr/bin/stat -f %z "$path" 2>/dev/null || echo 0)"
    [ "${size:-0}" -gt 0 ] || { gone=$((gone + 1)); continue; }
    msg_known "$guid" "$size" && continue
    sha="$(msg_sha1 "$path")"
    [ -n "$sha" ] || { failed=$((failed + 1)); continue; }
    msg_known_key "$guid" "$sha" && continue
    MSG_NEW=$((MSG_NEW + 1))
    when="${when:-0}"; case "$when" in ''|*[!0-9]*) when=0 ;; esac
    # An attachment with neither its own date nor a dated message would file
    # itself under 1970/01; the file's own mtime is a better answer and is the
    # date Messages itself shows for it.
    [ "$when" = 0 ] && when="$(/usr/bin/stat -f %m "$path" 2>/dev/null || echo 0)"
    if msg_present "$path"; then
      msg_state_add "$guid" "$sha" present "-" "$chat" "$handle" \
        "$(date -r "$when" +%Y-%m-%d 2>/dev/null || echo 0000-00-00)" "$size" "$kind"
      MSG_PRESENT=$((MSG_PRESENT + 1))
      continue
    fi
    rel="$(msg_rel "$sha" "$path" "$when")"
    if msg_stage "$path" "$rel"; then
      msg_state_add "$guid" "$sha" staged "$rel" "$chat" "$handle" \
        "$(date -r "$when" +%Y-%m-%d 2>/dev/null || echo 0000-00-00)" "$size" "$kind"
      MSG_STAGED=$((MSG_STAGED + 1))
    else
      # No ledger row: an unstaged file must be tried again next tick.
      failed=$((failed + 1))
    fi
  done < "$rows"
  secs=$(( $(date +%s) - t0 ))
  log "Messages source: $MSG_SEEN media attachment(s) seen, $MSG_NEW new, $MSG_STAGED staged, $MSG_PRESENT already in Google Photos, $gone with no bytes on disk, $failed not staged, ${secs}s"
  rm -rf "$snap" "$rows"
  return 0
}
