#!/usr/bin/env bash
# THE TWO REPORTS A HUMAN ACTS ON, written on every tick and never acted on by
# this pipeline itself. Both exist because the two deletions worth doing here
# have no safe programmatic path:
#
#   messages-cleanup-report.md   per conversation, the attachments this
#       pipeline has CONFIRMED in Google Photos -- so they can be deleted from
#       Messages by hand, which is the only supported way (Apple ships no API
#       for it, and writing chat.db is how a Messages database gets corrupted).
#       Videos first: 8 % of the attachments and 63 % of the bytes, measured
#       2026-09-20.
#   gphotos-duplicates-report.md  the account's duplicate groups by content
#       hash, from the Google Photos app's own database -- so they can be
#       cleaned in Google Photos by hand. 8,186 groups and 11,599 excess copies
#       here, measured 2026-09-20.
#
# IDENTIFIERS ONLY. A conversation is its chat id and its handle id (a phone
# number, an email, a group id); no display name, no message text and no file
# name is read from Messages at all, let alone written into a report that lands
# in a cloud folder. Each item is a date, a size and the first 8 hex of its own
# SHA-1, which is also the prefix of its staged file name -- enough to find it
# in a conversation, and nothing about what is in it.

# Sourced AFTER lib/messages.sh, whose MSG_STATE (the ledger these read) and
# msg_sqlite (the sqlite3 the fleet's PATH may not put first) belong to it.
#
# Where the reports go when MESSAGES_REPORT_DIR is empty, under the Drive this
# host declares. The fleet's paths file is READ, never sourced: it is data, and
# a config file that can run commands is a config file that will.
MSG_REPORT_SUBPATH="[01] Personal/[05] Media & Chats/Messages Backup"

msg_report_dir() {
  if [ -n "${MESSAGES_REPORT_DIR:-}" ]; then printf '%s\n' "$MESSAGES_REPORT_DIR"; return 0; fi
  [ -r "$SC_PATHS_ENV" ] || return 1
  local drive
  drive="$(awk -F"'" '/^SC_MY_DRIVE=/ { print $2; exit }' "$SC_PATHS_ENV")"
  [ -n "$drive" ] && [ -d "$drive" ] || return 1
  printf '%s/%s\n' "$drive" "$MSG_REPORT_SUBPATH"
}

# Every staged path Google Photos holds, one per line, from the Mac backend's
# own ledger -- the only authority on it. TWO of its states count:
#   confirmed  Google answered this pipeline's own upload with a media key.
#   present    the file's bytes were found in Google Photos' own database
#              before it was uploaded (lib/presence.sh). Same evidence the
#              reclaim already acts on, from the other end.
# `exists` deliberately does not: it means a Live Photo component matched by
# hash and WHICH half is not reported, so those stay in both places -- and a
# report that says "delete this" must never be the place that guess is made.
# On the emulator backend there is no such ledger at all: its evidence is the
# reclaim list, which the verify step feeds with exactly the device files
# Google Photos' own database confirmed, and the reclaimed list it drains into.
# Reading both is what makes this report work on an Intel Mac; on the Mac
# backend they hold the same paths again and cost one sort.
msg_confirmed_rels() {
  if [ -r "${MAC_STATE:-}" ]; then
    awk -F'\t' '$3 == "confirmed" || $3 == "present" { print $1 }' "$MAC_STATE"
  fi
  [ -r "${RECLAIM_PENDING:-}" ] && cat "$RECLAIM_PENDING"
  [ -r "${RECLAIMED:-}" ] && cat "$RECLAIMED"
  return 0
}

# Written through a temporary file and renamed: the reports live in a synced
# folder, and a half-written file is one the cloud client uploads anyway.
#
# AND ONLY WHEN THE CONTENT CHANGED, ignoring the "Generated" line, which is
# the only part that differs on a tick where nothing happened. A tick fires 96
# times a day and Drive keeps a version per write; a report that says the same
# thing as the one already there is not worth 96 versions of it.
msg_write() {  # <destination> < body
  local dst="$1" tmp
  tmp="$dst.tmp.$$"
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$dst" ] \
     && diff -q <(grep -v '^Generated ' "$tmp") <(grep -v '^Generated ' "$dst") >/dev/null 2>&1; then
    rm -f "$tmp"; return 0
  fi
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

# ── The conversation cleanup list ────────────────────────────────────────────

msg_cleanup_report() {  # <destination file>
  local conf
  conf="$(mktemp)"
  msg_confirmed_rels | sort -u > "$conf"
  # One awk pass over the ledger, with the confirmed set in an array: a row is
  # confirmed when Google Photos answered for its staged copy, or when it was
  # never staged BECAUSE Google Photos already had those bytes (state=present).
  awk -F'\t' -v conffile="$conf" -v now="$(date '+%Y-%m-%d %H:%M')" '
    function mb(b) { return sprintf("%.1f", b / 1048576) }
    BEGIN {
      while ((getline line < conffile) > 0) confirmed[line] = 1
      close(conffile)
    }
    {
      sha = $2; state = $3; rel = $5; chat = $6; handle = $7
      day = $8; bytes = $9 + 0; kind = $10
      done = (state == "present") || (state == "staged" && (rel in confirmed))
      if (!done) { waiting++; waitbytes += bytes; next }
      key = chat SUBSEP handle
      if (!(key in known)) { known[key] = 1; chats[++nchat] = key }
      items[key]++; cbytes[key] += bytes
      if (kind == "video") {
        vids[key]++; vbytes[key] += bytes
        vline[key] = vline[key] sprintf("| %s | %s | `%s` |\n", day, mb(bytes), substr(sha, 1, 8))
      } else {
        m = substr(day, 1, 7)
        mk = key SUBSEP m
        if (!(mk in mseen)) { mseen[mk] = 1; months[key] = months[key] m "\n" }
        mcount[mk]++; mbytes[mk] += bytes
      }
      total++; tbytes += bytes
      if (kind == "video") { tvid++; tvbytes += bytes }
    }
    END {
      print "# Messages attachments already in Google Photos"
      print ""
      printf "Generated %s by icloud-to-google-photos. Every attachment below has been\n", now
      print "CONFIRMED in Google Photos: either this pipeline uploaded it and Google"
      print "answered with a media key, or Google Photos already held those exact bytes"
      print "before it was ever staged. **Nothing here has been deleted from anywhere**, and"
      print "nothing in this pipeline ever deletes from Messages: Apple ships no supported"
      print "way to do it, so the deletion is a human one, in the Messages app."
      print ""
      print "Identifiers only: a conversation is its chat id and handle id, an item is its"
      print "date, its size and the first 8 hex of its own SHA-1 (the prefix of its staged"
      print "file name). No contact name, no message text and no file name is read."
      print ""
      if (total == 0) {
        print "Nothing is confirmed yet."
        if (waiting) printf "\n%d attachment(s), %s MB, are staged and waiting for Google Photos.\n", waiting, mb(waitbytes)
        exit
      }
      printf "**%d attachment(s), %s MB confirmed**, of which %d video(s), %s MB.\n", total, mb(tbytes), tvid, mb(tvbytes)
      if (waiting) printf "%d more, %s MB, are staged and not confirmed yet: leave those alone.\n", waiting, mb(waitbytes)
      print ""
      print "## By conversation"
      print ""
      print "| chat | handle | items | MB | videos | video MB |"
      print "| --- | --- | ---: | ---: | ---: | ---: |"
      # Biggest first: the conversation worth opening is the one holding the bytes.
      for (i = 1; i <= nchat; i++) order[i] = chats[i]
      for (i = 1; i <= nchat; i++)
        for (j = i + 1; j <= nchat; j++)
          if (cbytes[order[j]] > cbytes[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
      for (i = 1; i <= nchat; i++) {
        k = order[i]; split(k, p, SUBSEP)
        printf "| %s | `%s` | %d | %s | %d | %s |\n", p[1], p[2], items[k], mb(cbytes[k]), vids[k] + 0, mb(vbytes[k] + 0)
      }
      print ""
      print "Videos are listed one by one below because they carry most of the bytes;"
      print "photos are summarised per month, which is how they are found in a"
      print "conversation anyway."
      for (i = 1; i <= nchat; i++) {
        k = order[i]; split(k, p, SUBSEP)
        printf "\n## chat %s — `%s`\n\n", p[1], p[2]
        if (vids[k]) {
          printf "### Videos (%d, %s MB)\n\n", vids[k], mb(vbytes[k])
          print "| date | MB | id |"
          print "| --- | ---: | --- |"
          n = split(vline[k], lines, "\n")
          for (x = 1; x <= n; x++) if (lines[x] != "") print lines[x]
          print ""
        }
        if (items[k] - vids[k] > 0) {
          printf "### Photos by month (%d, %s MB)\n\n", items[k] - (vids[k] + 0), mb(cbytes[k] - (vbytes[k] + 0))
          print "| month | items | MB |"
          print "| --- | ---: | ---: |"
          n = split(months[k], ms, "\n")
          for (x = 1; x <= n; x++) {
            if (ms[x] == "") continue
            mk = k SUBSEP ms[x]
            printf "| %s | %d | %s |\n", ms[x], mcount[mk], mb(mbytes[mk])
          }
        }
      }
    }
  ' "$MSG_STATE" | msg_write "$1"
  local rc=$?
  rm -f "$conf"
  return "$rc"
}

# ── The Google Photos duplicate groups ───────────────────────────────────────

# WHICH DATABASE THIS REPORT READS, and deliberately NOT a function called
# gp_db_path: lib/presence.sh defines one, this file is sourced after it, and a
# second definition of that name would silently replace the one gp_present
# calls -- putting the report's rule on the path that decides whether a
# photograph may leave iCloud. This asks that function instead, and only falls
# back to its own copy of the rule for a caller that loaded this file alone.
#
# TWO ACCOUNT DATABASES IS A REFUSAL, not a choice between them: a Mac that has
# had a second Google account keeps that account's file, and nothing here can
# tell which one the app is signed into now. Exit codes are presence.sh's, so
# the two agree: 0 = the path is on stdout, 1 = none, 2 = more than one.
msg_gp_db_path() {
  if command -v gp_db_path >/dev/null 2>&1; then gp_db_path; return $?; fi
  local store found="" n=0 f
  store="${GP_STORE_DIR:-$HOME/Library/Containers/com.google.photos/Data/Library/Application Support/store}"
  [ -d "$store" ] || return 1
  for f in "$store"/photos-*.db; do
    case "$f" in *'*'*|*/photos-shared.db) continue ;; esac
    [ -f "$f" ] || continue
    n=$((n + 1)); found="$f"
  done
  [ "$n" -gt 1 ] && return 2
  [ "$n" -eq 1 ] || return 1
  printf '%s\n' "$found"
}

gp_duplicates_report() {  # <destination file>
  local src snap groups totals
  src="$(msg_gp_db_path)"
  case $? in
    0) ;;
    2) log "duplicates report skipped: the app's store holds more than one account database, and which one it is signed into is not knowable from here"; return 0 ;;
    *) log "duplicates report skipped: no Google Photos database in the app's own store"; return 0 ;;
  esac
  snap="$(mktemp -d)" || return 0
  # db + -wal + -shm together, and opened read-write, for the same reasons the
  # Messages copy is (lib/messages.sh): the WAL holds everything since the last
  # checkpoint and SQLite must be allowed to replay it into the copy. On APFS a
  # cp of this 102 MB file is a clone -- 0.3 s measured 2026-09-20 -- so this
  # is cheap enough to do on every tick.
  if ! /bin/cp -p "$src" "$snap/gp.db" 2>/dev/null; then
    log "duplicates report skipped: could not copy the Google Photos database"
    rm -rf "$snap"; return 0
  fi
  [ -f "$src-wal" ] && /bin/cp -p "$src-wal" "$snap/gp.db-wal" 2>/dev/null
  [ -f "$src-shm" ] && /bin/cp -p "$src-shm" "$snap/gp.db-shm" 2>/dev/null
  # localDedupKey is base64url(SHA-1(file bytes)) -- Google's own content
  # fingerprint, one row per accepted upload (measured 2026-09-20, 6 of 8
  # blind files matched by computed key; the two misses were the video halves
  # of Live Photos, which have no key of their own). Two rows sharing a key are
  # the SAME bytes stored twice. A group is dated by its earliest copy.
  totals="$(msg_sqlite -batch -noheader -separator "$(printf '\t')" "$snap/gp.db" "
    WITH g AS (SELECT localDedupKey k, COUNT(*) n, MAX(size) sz, MIN(timestampMs) t
               FROM ServerPhotos WHERE localDedupKey IS NOT NULL AND localDedupKey <> ''
               GROUP BY 1 HAVING COUNT(*) >= 2)
    SELECT (SELECT COUNT(*) FROM ServerPhotos), COUNT(*), COALESCE(SUM(n),0),
           COALESCE(SUM(n-1),0), COALESCE(SUM((n-1)*sz),0) FROM g;" 2>/dev/null)"
  if [ -z "$totals" ]; then
    log "duplicates report skipped: the Google Photos database has no ServerPhotos table to read"
    rm -rf "$snap"; return 0
  fi
  groups="$(msg_sqlite -batch -noheader -separator "$(printf '\t')" "$snap/gp.db" "
    WITH g AS (SELECT localDedupKey k, COUNT(*) n, MAX(size) sz, MIN(timestampMs) t
               FROM ServerPhotos WHERE localDedupKey IS NOT NULL AND localDedupKey <> ''
               GROUP BY 1 HAVING COUNT(*) >= 2)
    SELECT strftime('%Y-%m', t/1000, 'unixepoch', 'localtime'), COUNT(*), SUM(n), SUM(n-1), SUM((n-1)*sz)
    FROM g GROUP BY 1 ORDER BY 1 DESC;" 2>/dev/null)"
  local largest
  largest="$(msg_sqlite -batch -noheader -separator "$(printf '\t')" "$snap/gp.db" "
    WITH g AS (SELECT localDedupKey k, COUNT(*) n, MAX(size) sz, MIN(timestampMs) t
               FROM ServerPhotos WHERE localDedupKey IS NOT NULL AND localDedupKey <> ''
               GROUP BY 1 HAVING COUNT(*) >= 2)
    SELECT strftime('%Y-%m-%d', t/1000, 'unixepoch', 'localtime'), n, sz, (n-1)*sz, substr(k,1,8)
    FROM g ORDER BY (n-1)*sz DESC LIMIT 25;" 2>/dev/null)"
  {
    printf '# Google Photos duplicate groups\n\n'
    printf 'Generated %s by icloud-to-google-photos, from a **copy** of the Google\n' "$(date '+%Y-%m-%d %H:%M')"
    printf 'Photos app'"'"'s own database. Read-only: nothing here deletes anything, and this\n'
    printf 'pipeline has no way to delete from Google Photos at all — the cleanup is a\n'
    printf 'human one, in the Google Photos app.\n\n'
    printf 'A group is a set of library items sharing one `localDedupKey`, which is\n'
    printf '`base64url(SHA-1(file bytes))` — Google'"'"'s own content fingerprint. Rows in one\n'
    printf 'group are byte-identical copies, so every copy beyond the first is storage\n'
    printf 'bought twice. A group is dated by its earliest copy, and its excess is\n'
    printf 'counted against the largest size in the group.\n\n'
    printf '%s' "$totals" | awk -F'\t' '{
      printf "| library items | duplicate groups | items in them | excess copies | excess GB |\n"
      printf "| ---: | ---: | ---: | ---: | ---: |\n"
      printf "| %d | %d | %d | %d | %.1f |\n\n", $1, $2, $3, $4, $5 / 1073741824 }'
    printf '## By month\n\n'
    printf '| month | groups | copies | excess copies | excess GB |\n'
    printf '| --- | ---: | ---: | ---: | ---: |\n'
    printf '%s' "$groups" | awk -F'\t' 'NF { printf "| %s | %d | %d | %d | %.2f |\n", $1, $2, $3, $4, $5 / 1073741824 }'
    printf '\n## The 25 groups costing the most\n\n'
    printf '| earliest copy | copies | MB each | excess MB | id |\n'
    printf '| --- | ---: | ---: | ---: | --- |\n'
    printf '%s' "$largest" | awk -F'\t' 'NF { printf "| %s | %d | %.1f | %.1f | `%s` |\n", $1, $2, $3 / 1048576, $4 / 1048576, $5 }'
    printf '\nThe id is the first 8 characters of the group'"'"'s content hash: it identifies\n'
    printf 'the group between one run of this report and the next, and says nothing about\n'
    printf 'what the item is.\n'
  } | msg_write "$1"
  rm -rf "$snap"
  return 0
}

# Both reports, on every tick. Cheap by construction: the first is one awk pass
# over a ledger of a few thousand lines, the second three indexed queries over
# an APFS clone of the app's database (0.4 s in all, measured 2026-09-20).
msg_reports() {
  msg_enabled || return 0
  local dir
  if ! dir="$(msg_report_dir)"; then
    log "Messages reports skipped: no MESSAGES_REPORT_DIR, and $SC_PATHS_ENV names no mounted Drive"
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    log "Messages reports skipped: cannot create $dir"
    return 0
  fi
  # The cleanup list needs the Messages ledger; the duplicates report is about
  # the Google Photos account and is worth writing on a tick that staged
  # nothing at all.
  if [ -r "$MSG_STATE" ]; then
    msg_cleanup_report "$dir/messages-cleanup-report.md" \
      || log "WARNING: could not write $dir/messages-cleanup-report.md"
  fi
  gp_duplicates_report "$dir/gphotos-duplicates-report.md" \
    || log "WARNING: could not write $dir/gphotos-duplicates-report.md"
  return 0
}
