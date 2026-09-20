#!/usr/bin/env bash
# IS THIS STAGED FILE ALREADY IN GOOGLE PHOTOS? The Mac backend confirms an
# upload from its own call's reply (a media key), so it can only ever recognise
# what IT uploaded: a photo the phone's Google Photos app backed up years ago is
# invisible to it and is uploaded a second time. Google deduplicates on its own
# side, so nothing is duplicated up there -- but every one of those files is
# still copied into ~/Pictures, read, uploaded over the network and waited for.
#
# The app's own database answers the question for free. Google Photos for
# iPhone/iPad keeps the account's remote library in
#   ~/Library/Containers/com.google.photos/Data/Library/Application Support/store/photos-<accountId>.db
# where ServerPhotos holds one row per item Google has, with
#   mediaKey        Google's id for the item
#   localDedupKey   base64url(sha1(the file's bytes)), no "=" padding
# and localDedupKey is indexed. Measured on this fleet 2026-09-20: 53,150 rows,
# 41,551 distinct keys, every row with a key; 24 of 24 staged files sampled
# across .heic/.jpg/.mov/.mp4 resolved to a row by that formula, 0 misses.
#
# THE CONTRACT, which other code depends on:
#   gp_present <file>   0 = present, and the media key is on stdout
#                       1 = absent, upload it
#                       2 = unknown (no database, unreadable, no sha1 tool, or
#                           a cloud-evicted file whose bytes are not here)
# UNKNOWN IS NOT ABSENT AND IT IS NEVER PRESENT. Every caller must treat 2 the
# way it treats 1 -- upload -- because the cost of a wrong "absent" is one
# duplicate upload Google discards, while the cost of a wrong "present" is a
# photograph deleted from iCloud that nothing ever backed up.
#
# NEVER OPEN THE LIVE FILE. The app writes it while it runs and a reader that
# opens it can be handed a torn page or can block the app; a query against it
# would also leave the -shm and -wal of a database this pipeline does not own.
# gp_db_open copies the db together with its -wal and -shm (all three, in one
# breath -- copied seconds apart, sqlite rejects the set as "database disk image
# is malformed") into a per-tick temporary directory and reads the copy.
#
# ONE COPY PER TICK, NOT PER FILE: the copy plus the key dump is a fixed ~0.3 s
# whatever the tree size (the db is ~100 MB and APFS clones it), and the dumped
# key table turns each per-file question into one awk pass over a local file.
# gp_db_open is idempotent, so a caller that only ever calls gp_present still
# pays it once.

# The container is keyed by the app's bundle identifier (com.google.photos),
# not by where the bundle was installed, so this path does not follow
# GPHOTOS_APP. GP_STORE_DIR overrides it -- the tests point it at a fixture.
GP_STORE_DIR="${GP_STORE_DIR:-$HOME/Library/Containers/com.google.photos/Data/Library/Application Support/store}"
# The one dataless/zero-byte definition in this project, rather than a private
# copy of it here. Resolved from this file's own directory, so it works from a
# clone and from an installed copy alike; already sourced when the sync sourced
# it, and sourcing it twice only redefines two functions.
# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/fs.sh"
GP_DB_DIR=""        # the per-tick temporary directory, while one is open
GP_DB_STATE=""      # "" not tried yet | ready | unknown
GP_DB_KEYS=""       # the dumped "<dedup key>\t<media key>" table
# shellcheck disable=SC2034  # read by the caller (lib/mac.sh), to log ONCE
GP_DB_REASON=""     # why the state is unknown, for the caller to log ONCE

# The account's database. photos-shared.db and transaction-shared.db sit beside
# it and belong to no account; one signed-in account means one photos-<id>.db.
#
# TWO OF THEM IS AN UNKNOWN, NOT A CHOICE. A Mac that has had a second Google
# account keeps that account's file too, and nothing here can tell which one the
# app is signed into now -- picking the newest would let a row in account A's
# library authorise deleting an iCloud original while the pipeline uploads to
# account B. It is the same mistake as globbing for a Drive mount, and the
# answer is the same: refuse and say so.
#
# IT REPORTS THROUGH ITS EXIT CODE, never by setting a variable: every caller
# reads it as `$(gp_db_path)`, which is a SUBSHELL, so an assignment made in
# here is discarded and the caller would log an empty reason -- which is what
# the test asking for that reason measured. 0 = the path is on stdout,
# 1 = none, 2 = more than one.
gp_db_path() {
  local found="" n=0 f
  [ -d "$GP_STORE_DIR" ] || return 1
  for f in "$GP_STORE_DIR"/photos-*.db; do
    case "$f" in *'*'*|*/photos-shared.db) continue ;; esac
    [ -f "$f" ] || continue
    n=$((n + 1)); found="$f"
  done
  [ "$n" -gt 1 ] && return 2
  [ "$n" -eq 1 ] || return 1
  printf '%s\n' "$found"
}

# The copy and the key dump. Returns 0 when the table is readable, 2 otherwise
# -- and a 2 here is what makes every later gp_present answer "unknown".
gp_db_open() {
  [ -n "$GP_DB_STATE" ] && { [ "$GP_DB_STATE" = ready ] && return 0 || return 2; }
  GP_DB_STATE=unknown
  local live sql
  if ! command -v sqlite3 >/dev/null 2>&1; then
    GP_DB_REASON="no sqlite3 on PATH"; return 2
  fi
  # The reason is built HERE, from gp_db_path's exit code, because that function
  # runs in a command substitution and could not set a variable this shell would
  # ever see.
  live="$(gp_db_path)"
  case $? in
    2) GP_DB_REASON="more than one Google Photos database in $GP_STORE_DIR (this Mac has had more than one account) -- which one the app is signed into now cannot be read from here"
       return 2 ;;
    1) GP_DB_REASON="no Google Photos database under $GP_STORE_DIR (the app has never signed in on this Mac)"
       return 2 ;;
  esac
  # Anything a killed run left behind, before making another: each copy is the
  # whole database (about 100 MB here) and the sync runs every fifteen minutes,
  # so a leak here is measured in gigabytes a day on a pipeline whose purpose is
  # reclaiming space. An hour is past any run of this (the budget is minutes).
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'gp-presence.*' -mmin +60 -exec rm -rf {} + 2>/dev/null
  GP_DB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gp-presence.XXXXXX")" || {
    GP_DB_REASON="could not make a temporary directory"; return 2; }
  # The -wal carries everything written since the last checkpoint, which on a
  # running app is every upload of the last few minutes. Missing it would not
  # corrupt the read, it would just answer "absent" for the newest items.
  if ! /bin/cp "$live" "$GP_DB_DIR/photos.db" 2>/dev/null; then
    GP_DB_REASON="could not copy the database (macOS refused this process access to the app's container)"
    return 2
  fi
  [ -f "$live-wal" ] && /bin/cp "$live-wal" "$GP_DB_DIR/photos.db-wal" 2>/dev/null
  [ -f "$live-shm" ] && /bin/cp "$live-shm" "$GP_DB_DIR/photos.db-shm" 2>/dev/null
  GP_DB_KEYS="$GP_DB_DIR/keys.tsv"
  # Read-write on the COPY on purpose: sqlite replays the -wal into it, which a
  # read-only open of a copied database cannot do.
  #
  # THE TOMBSTONE JOIN IS NOT OPTIONAL. A photo deleted in Google Photos gets a
  # row in ServerTombstones, and its ServerPhotos row -- localDedupKey and all
  # -- STAYS. Without this exclusion a file the user deleted at Google answers
  # "present", reaches the reclaim list, and its iCloud original is deleted too:
  # gone from both sides, which is the one outcome this pipeline exists to make
  # impossible. Measured on this fleet 2026-09-20: 2 tombstones, both still
  # carrying a ServerPhotos row, and the exclusion removes exactly those two of
  # 53,150 rows -- it costs no true positive. Excluding by mediaKey and not by
  # localDedupKey is deliberate: the same bytes can have several rows (8,186
  # duplicate-key groups here), and if another, live row holds that key then
  # Google really does still have the item.
  sql='select p.localDedupKey, p.mediaKey from ServerPhotos p
       where p.localDedupKey is not null and p.localDedupKey != ""
         and p.mediaKey not in (select t.mediaKey from ServerTombstones t);'
  # A schema without ServerPhotos or without ServerTombstones fails here, and
  # failing is right: the fallback would be the same query without the
  # tombstone exclusion, which is the unsafe one. Unknown means upload, which
  # costs duplicates; guessing would cost photographs.
  if ! sqlite3 -batch -noheader -separator "$(printf '\t')" "$GP_DB_DIR/photos.db" "$sql" > "$GP_DB_KEYS" 2>/dev/null; then
    GP_DB_REASON="the Google Photos database has no readable ServerPhotos/ServerTombstones pair (the app's schema changed)"
    return 2
  fi
  [ -s "$GP_DB_KEYS" ] || { GP_DB_REASON="the Google Photos database holds no items yet"; return 2; }
  GP_DB_STATE=ready
  return 0
}

# Rows in the dumped table, for the caller's one log line. "0" when there is none.
gp_db_rows() {
  [ "$GP_DB_STATE" = ready ] || { printf '0\n'; return 0; }
  local n; n="$(grep -c . "$GP_DB_KEYS" 2>/dev/null)"; printf '%s\n' "${n:-0}"
}

gp_db_close() {
  [ -n "$GP_DB_DIR" ] && rm -rf "$GP_DB_DIR"
  GP_DB_DIR=""; GP_DB_STATE=""; GP_DB_KEYS=""
  # shellcheck disable=SC2034  # read by the caller (lib/mac.sh)
  GP_DB_REASON=""
}

# base64url(sha1(file bytes)) with the padding stripped: 27 characters. Two
# openssl calls rather than shasum + xxd, because openssl is one tool that is
# always there and neither step ever renders the digest as text -- a hex
# round trip is where a "-b"-less shasum's filename or a locale's idea of a
# byte would get in. Nothing is read into a shell variable: the bytes go
# digest -> base64 through a pipe, so a 4 GB video costs no memory here.
gp_hash() {  # <file>
  local h
  h="$(/usr/bin/openssl dgst -binary -sha1 "$1" 2>/dev/null | /usr/bin/openssl base64 2>/dev/null | tr -d '\n')" || return 1
  [ -n "$h" ] || return 1
  h="${h//+/-}"; h="${h//\//_}"; h="${h%%=*}"
  # 27 characters is what 160 bits encodes to once the single "=" is gone.
  # Anything else means the digest was not 20 bytes: refuse rather than look
  # up a truncated key and get a confident answer to the wrong question.
  [ "${#h}" -eq 27 ] || return 1
  printf '%s\n' "$h"
}

# THE CONTRACT. 0 + media key on stdout / 1 absent / 2 unknown.
gp_present() {  # <file>
  local f="$1" key hit
  gp_db_open || return 2
  [ -f "$f" ] || return 2
  # A staging tree in a cloud folder in stream mode holds files whose bytes are
  # not on this Mac. Reading one blocks until it is downloaded, which is the
  # opposite of what a cheap pre-upload check is for -- and the handoff skips
  # the same files. has_local_bytes (lib/fs.sh) is the one definition of that
  # test in this project; a sixth private copy of it is how the five that
  # existed before it drifted.
  has_local_bytes "$f" || return 2
  # AND A ZERO-BYTE FILE IS UNKNOWN HERE, although has_local_bytes calls it
  # present (nothing to fault in, which is the right answer to ITS question).
  # Every empty file has the same sha1, so one empty row in the database would
  # make every empty staged file "present" and send its iCloud original to the
  # reclaim. The handoff refuses these too, with an explanation.
  [ "$(/usr/bin/stat -f %z "$f" 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null || return 2
  key="$(gp_hash "$f")" || return 2
  hit="$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$GP_DB_KEYS" 2>/dev/null)" || return 2
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
  return 0
}

# ── Live Photos ──────────────────────────────────────────────────────────────
# A Live Photo is ONE iCloud asset staged as two files: the still (IMG_1234.HEIC)
# and its motion component, which icloudpd names IMG_1234_HEVC.MOV or, with the
# other filename policy, IMG_1234.MOV -- the same two candidates the reclaim
# step builds when it looks for companions.
#
# ONLY THE STILL IS HASHED. Google's item for a Live Photo is keyed by the
# still's bytes, so the video component has no row of its own to match and
# asking about it can only ever answer "absent". gp_still_of gives the caller
# the still a staged video belongs to, and the caller carries the still's
# answer over to it: a present still means the pair is already in Google Photos
# and neither file is uploaded.
#
# THE COST OF THAT RULE, stated plainly: the evidence is the still's bytes, and
# nothing here proves Google also holds the motion part. It is the rule this
# repository was asked for; the conservative alternative is to upload the video
# anyway, which is what happens for every pair whose still is absent.
# A STEM MATCH ALONE IS NOT EVIDENCE OF A PAIR, and this function authorises a
# deletion, so the two naming forms are not treated alike:
#
#   IMG_1234_HEVC.MOV   icloudpd's own Live Photo name (lp_filename_concatinator).
#                       A file is given that suffix only as a still's motion
#                       component, so the stem match IS the evidence.
#   IMG_1234.MOV        the other filename policy's name for the same thing --
#                       and also what a plain video is called. iPhone names
#                       recycle (the counter wraps at 9999, and a merged library
#                       holds two devices' IMG_00xx), so the stem alone could
#                       pair a standalone video with an unrelated photo and send
#                       that video's iCloud original to the reclaim on the
#                       photo's evidence. This branch therefore also requires
#                       the two files to carry the SAME mtime: icloudpd stamps
#                       every component with the asset's own creation date, so
#                       two files of one asset match to the second and two
#                       unrelated assets would have to share a creation second
#                       as well as a name.
#
# Measured over this fleet's staging tree 2026-09-20: 784 pairs, every one the
# _HEVC form, and in all 784 the still and the video carry the same mtime; the
# 201 bare .MOV files have no same-stem still at all, so the guarded branch
# never fires here. That is exactly why it is guarded rather than trusted.
gp_still_of() {  # <staging dir> <relative path of a staged file> -> the still's relative path, or nothing
  local root="$1" rel="$2" dir base stem ext cand hevc=0
  case "$rel" in
    *.MOV|*.mov|*.MP4|*.mp4|*.M4V|*.m4v) ;;
    *) return 1 ;;
  esac
  case "$rel" in */*) dir="${rel%/*}/" ;; *) dir="" ;; esac
  base="${rel##*/}"
  stem="${base%.*}"
  case "$stem" in *_HEVC|*_hevc) stem="${stem%_*}"; hevc=1 ;; esac
  for ext in HEIC heic JPG jpg JPEG jpeg PNG png HEIF heif; do
    cand="$dir$stem.$ext"
    [ "$cand" = "$rel" ] && continue
    [ -f "$root/$cand" ] || continue
    if [ "$hevc" -eq 0 ] \
       && [ "$(/usr/bin/stat -f %m "$root/$cand" 2>/dev/null || echo x)" \
         != "$(/usr/bin/stat -f %m "$root/$rel" 2>/dev/null || echo y)" ]; then
      continue
    fi
    printf '%s\n' "$cand"; return 0
  done
  return 1
}
