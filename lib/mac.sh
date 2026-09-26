#!/usr/bin/env bash
# The Apple silicon half of avd-photos-sync (PHOTOS_BACKEND=mac): staged
# originals go to Google Photos for iPhone and iPad running natively on this
# Mac, through the folder ios/gp-bridge.m watches, and Google's answer comes
# back through the bridge's ledger. Sourced by avd-photos-sync after its own
# helpers (log, phase, fail, count_lines, enumerate_staging, ENUM_ERR);
# mac_sync stands in for steps 2 to 5 of the emulator path, and step 6, the
# iCloud reclaim, is the same code for both. avd-photos-status and
# gphotos-mac-setup source it too -- the first for the counts, the second for
# MAC_INBOX, which is defined here and nowhere else.
#
# CONFIRMATION IS GOOGLE'S MEDIA KEY. The bridge moves a file into Uploaded/
# only when the engine's job completed with a media key, which is the commit
# reply of Google's own upload API; the emulator path could only infer the
# same thing from Photos' database. That, and nothing else, feeds the reclaim
# list. A duplicate is not a risk (measured 2026-09-16): the engine cancels a
# second job with the same content hash and answers with the first job's
# result, and bytes Google already holds come back from a forced upload with
# the SAME media key -- Google deduplicates on its side.
#
# Files in the folder are copies, named after the staged path ("/" -> "_",
# the emulator path's device naming), so the staging tree is never touched
# and the ledger maps every name back exactly, with no basename guessing.

# ONE ROW PER STAGED PATH, keyed by that path, because a staged file has one
# lifecycle and the four files that modelled it needed two sort|comm pipelines,
# a reverse index and a grep per dedup to put it back together (the two reviews
# of 2026-09-16). Tab-separated:
#
#   rel     the path relative to STAGING -- the key
#   name    the flat copy name in the upload folder ("/" -> "_")
#   state   queued     handed over, waiting for the bridge to report
#           confirmed  Google answered with a media key
#           exists     a Live Photo component Google already holds, by hash.
#                      Neither confirmed nor retried: which component matched
#                      is not reported, so the pair stays in iCloud -- the
#                      safe direction.
#           present    Google Photos' OWN database already holds this file's
#                      bytes (lib/presence.sh), so it was never handed over.
#                      Its own state and not "confirmed", because the evidence
#                      is different: a confirmation is Google's reply to THIS
#                      pipeline's upload, a presence is a row in the app's
#                      library that some other device may have put there. Both
#                      mean the bytes are at Google and both feed the reclaim;
#                      only this one can be wrong about WHICH upload did it.
#           failed     the engine gave up, or the bridge never took it
#   stamp   epoch of the last transition (a queued row's handoff time)
#   tries   failures so far, against MAC_RETRIES
#   detail  the last engine error, or a word for where the row came from.
#           Never a media key and never an account: this file is read by the
#           menu bar and quoted in logs.
MAC_STATE="$STATE_DIR/mac-state.tsv"
# The media key of every file the presence check found, kept OUT of the state
# file above on purpose: that one is read by the menu bar and quoted in logs,
# and a media key is an account-scoped identifier for a photograph. One row per
# staged path, "<rel>\t<media key>\t<epoch>", append-only, nothing else reads
# it -- it is the evidence trail for a reclaim that was decided without an
# upload of our own.
MAC_PRESENT="$STATE_DIR/mac-present.tsv"
MAC_RETRIES=3                                  # handoffs per file before it is left alone
# A handoff the bridge has NO ENTRY for this long after the copy was lost on
# the way (a copy that never settled, a folder emptied by hand): it counts as
# a failure and is handed over again. A name the bridge does hold is the
# engine's however long it takes -- it uploads one item at a time and only
# while the app is visible and online, so wall-clock time says nothing about
# it, and a re-drop of a name the bridge tracks is ignored by it anyway.
MAC_GIVE_UP=$((6 * 3600))
# THE ONE DEFINITION OF THE UPLOAD FOLDER, and deliberately not a config key:
# the bridge inside the app hardcodes this path (ios/gp-bridge.m) because the
# app's sandbox reaches exactly ~/Pictures and cannot read this pipeline's
# config at all. A key only the sync honoured moved one half of the contract
# and left the other where it was.
MAC_INBOX="$HOME/Pictures/Google Photos Upload"
MAC_BRIDGE="$MAC_INBOX/.bridge"
MAC_HANDED=0                                   # handed over this run, for the "done" line
MAC_DONE=0                                     # confirmed this run
MAC_PRESENT_N=0                                # found already in Google Photos this run
MAC_FAILURES=0                                 # failures this run, and the gate on the confirmation stamp

# The presence check lives beside this file and is sourced from here rather
# than from avd-photos-sync, so every consumer of lib/mac.sh (the status
# command, the tests) has it too.
# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/presence.sh"

# /usr/bin/jq ships with macOS since 15; a jq on PATH does as well.
mac_jq() {
  if [ -x /usr/bin/jq ]; then /usr/bin/jq "$@"; else jq "$@"; fi
}

# Lines on stdin. NOT `grep -c . || true`: grep prints its own 0 AND exits 1 on
# empty input, so that idiom yields "0\n0".
mac_count() { local n; n="$(grep -c .)"; printf '%s\n' "${n:-0}"; }

# ── The state file ───────────────────────────────────────────────────────────

# One row, rewritten whole: the path's old row dropped, the new one appended,
# through a temporary file, so a kill leaves the file as it was or as it will
# be and never half of each.
mac_state_set() {  # <rel> <name> <state> <tries> [detail]
  [ -e "$MAC_STATE" ] || : > "$MAC_STATE"
  awk -F'\t' -v OFS='\t' -v r="$1" -v n="$2" -v s="$3" -v t="$4" -v d="${5:--}" -v now="$(date +%s)" '
    $1 == r { next }
    { print }
    END { print r, n, s, now, t + 0, d }' "$MAC_STATE" > "$MAC_STATE.tmp" \
    && mv -f "$MAC_STATE.tmp" "$MAC_STATE" || { rm -f "$MAC_STATE.tmp"; return 1; }
}

# Every staged path in one state, one per line.
mac_state_rels() {  # <state>
  [ -r "$MAC_STATE" ] || return 0
  awk -F'\t' -v s="$1" '$3 == s { print $1 }' "$MAC_STATE"
}

# The staged path a bridge name currently belongs to. Only a queued row can
# answer: the flat name is lossy ("a/b_c" and "a_b/c" both flatten to "a_b_c")
# and the handoff guard keeps at most one of them in flight, so the name means
# exactly one staged path for as long as the bridge holds it.
mac_state_rel_of_name() {  # <name>
  [ -r "$MAC_STATE" ] || return 0
  awk -F'\t' -v n="$1" '$2 == n && $3 == "queued" { print $1; exit }' "$MAC_STATE"
}

# Failures recorded against a staged path so far.
mac_state_tries() {  # <rel>
  [ -r "$MAC_STATE" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v r="$1" '$1 == r { t = $5 } END { print t + 0 }' "$MAC_STATE"
}

# Everything that needs no further handoff: every row except a failure with
# retries left. Sorted, for comm against the staging listing.
mac_handled() {
  [ -r "$MAC_STATE" ] || return 0
  awk -F'\t' -v max="$MAC_RETRIES" '$3 != "failed" || $5 + 0 >= max { print $1 }' "$MAC_STATE" | sort -u
}

# Handed over and still waiting for Google's answer.
mac_outstanding() { mac_state_rels queued | sort -u; }

# Failed MAC_RETRIES times: out of the pipeline until a human asks for them
# again (avd-photos-sync --retry-given-up).
mac_given_up() {
  [ -r "$MAC_STATE" ] || return 0
  awk -F'\t' -v max="$MAC_RETRIES" '$3 == "failed" && $5 + 0 >= max { print $1 }' "$MAC_STATE"
}

# A transition that leaves the retry budget where it is -- every state change
# but a failure.
mac_state_to() {  # <rel> <name> <state> [detail]
  mac_state_set "$1" "$2" "$3" "$(mac_state_tries "$1")" "${4:--}"
}

# Records one failed handoff against the staged path's own row: the try count
# is what MAC_RETRIES is measured against, and the detail is the last reason.
mac_fail() {  # <rel> <name> <error>
  MAC_FAILURES=$((MAC_FAILURES + 1))
  mac_state_set "$1" "$2" failed "$(( $(mac_state_tries "$1") + 1 ))" "${3:--}"
}

# THE ONLY DOOR TO DELETING FROM iCLOUD, and it opens for a run that recorded
# no failure at all. A run that did leaves the stamp for the poll loop to
# remove, so the reclaim step refuses on the very next run.
mac_stamp_if_clean() {
  [ "$MAC_FAILURES" -eq 0 ] && date +%s > "$STATE_DIR/last-upload-confirmed"
  return 0
}

# The lines of one legacy file, each tagged with what it is, or nothing when
# the file is absent -- the shape the migration can hand to a single awk pass.
mac_tag() {  # <kind> <file>
  [ -r "$2" ] || return 0
  awk -v k="$1" 'NF { print k "\t" $0 }' "$2"
}

# The state file, built once from whatever the four bookkeeping files this
# replaced left behind and from the emulator backend's reclaim lists, so a Mac
# whose emulator pipeline already confirmed part of the library does not send
# it again (it would dedupe at Google, but only after copying and hashing every
# file).
#
# awk is handed ONE tagged stream rather than a file list, because awk given a
# file that does not exist fails the whole pass -- and on a first run most of
# these are absent. That family of mistake (`sort -u a b c`, then `cat a b c |`
# under pipefail) is what made the first production run of this backend,
# 2026-09-16, log "3108 not sent again" and hand 300 of them to Google Photos
# anyway.
mac_migrate() {
  [ -e "$MAC_STATE" ] && return 0
  local tagged from_emulator
  tagged="$(mktemp)"
  mac_tag queued    "$STATE_DIR/mac-queued.tsv"     >> "$tagged"
  mac_tag failed    "$STATE_DIR/mac-failed.tsv"     >> "$tagged"
  mac_tag exists    "$STATE_DIR/mac-exists.list"    >> "$tagged"
  mac_tag emulator  "$RECLAIM_PENDING"              >> "$tagged"
  mac_tag emulator  "$STATE_DIR/reclaimed.list"     >> "$tagged"
  mac_tag confirmed "$STATE_DIR/mac-confirmed.list" >> "$tagged"
  from_emulator="$(awk -F'\t' '$1 == "emulator" { print $2 }' "$tagged" | sort -u | mac_count)"
  if ! awk -F'\t' -v OFS='\t' '
    # Rank decides the state when one staged path was recorded several ways: a
    # confirmation outranks a refusal, a refusal a handoff, and a failure is
    # what is left when nothing better was written. The failure COUNT is kept
    # whatever the state ends up being -- it is the retry budget.
    function record(r, st, rk, dt,   flat) {
      if (!(r in rank) || rk >= rank[r]) { rank[r] = rk; state[r] = st; detail[r] = dt }
      if (!(r in name)) { flat = r; gsub(/\//, "_", flat); name[r] = flat }
      if (!(r in stamp)) stamp[r] = 0
      if (!(r in tries)) tries[r] = 0
    }
    $1 == "queued"    && $3 != "" { record($3, "queued", 1, "-")
                                    name[$3] = $2
                                    stamp[$3] = ($4 ~ /^[0-9]+$/) ? $4 : 0; next }
    $1 == "failed"    && $2 != "" { record($2, "failed", 0, ($3 == "") ? "-" : $3); tries[$2]++; next }
    $1 == "exists"    && $2 != "" { record($2, "exists", 2, "-"); next }
    $1 == "emulator"  && $2 != "" { record($2, "confirmed", 3, "emulator"); next }
    $1 == "confirmed" && $2 != "" { record($2, "confirmed", 4, "-"); next }
    END { for (r in state) print r, name[r], state[r], stamp[r], tries[r], detail[r] }
  ' "$tagged" | sort > "$MAC_STATE.tmp"; then
    rm -f "$MAC_STATE.tmp" "$tagged"
    fail "could not build $MAC_STATE from the previous bookkeeping files"
  fi
  rm -f "$tagged"
  mv -f "$MAC_STATE.tmp" "$MAC_STATE" || fail "could not write $MAC_STATE"
  [ "$from_emulator" -gt 0 ] \
    && log "first run on Google Photos for Mac: $from_emulator file(s) the emulator already confirmed are not sent again"
  return 0
}

# Resets the retry budget of every staged path this backend gave up on, so the
# next run hands them over again. The one way back in: nothing else ever clears
# a give-up.
mac_retry_given_up() {
  local n
  if [ ! -r "$MAC_STATE" ]; then log "no Mac backend state yet ($MAC_STATE): nothing to retry"; return 0; fi
  n="$(mac_given_up | mac_count)"
  if ! awk -F'\t' -v OFS='\t' -v max="$MAC_RETRIES" '
         $3 == "failed" && $5 + 0 >= max { $5 = 0 } 1' "$MAC_STATE" > "$MAC_STATE.tmp"; then
    rm -f "$MAC_STATE.tmp"; fail "could not rewrite $MAC_STATE"
  fi
  mv -f "$MAC_STATE.tmp" "$MAC_STATE" || fail "could not write $MAC_STATE"
  log "$n file(s) given up after $MAC_RETRIES failures are handed over again from the next run"
}

# ── The app and its bridge ───────────────────────────────────────────────────

# The app's process: its executable lives directly in the bundle.
mac_app_pid() { pgrep -f "^$GPHOTOS_APP/[^/]*$" 2>/dev/null | head -1; }

# One field of the bridge's heartbeat, or empty when it has none.
mac_alive() { mac_jq -r ".$1 // empty" "$MAC_BRIDGE/alive.json" 2>/dev/null; }

# The bridge is up when its heartbeat is recent AND came from the running app:
# a heartbeat file outlives the process that wrote it.
mac_bridge_up() {
  local t pid now
  t="$(mac_alive time)"; pid="$(mac_alive pid)"; now="$(date +%s)"
  [ -n "$t" ] && [ -n "$pid" ] && [ $((now - t)) -lt 30 ] && [ "$pid" = "$(mac_app_pid)" ]
}

# Launch Google Photos WITHOUT taking focus (open -g) when it is not running,
# and wait for the bridge's first heartbeat (its first pass is 8 s after launch).
mac_launch() {
  if [ -z "$(mac_app_pid)" ]; then
    log "starting Google Photos in the background"
    phase "starting Google Photos"
    open -g "$GPHOTOS_APP" >/dev/null 2>&1 || fail "could not open $GPHOTOS_APP"
  fi
  local n=0
  while [ "$n" -lt 30 ]; do
    mac_bridge_up && return 0
    sleep 2; n=$((n + 1))
  done
  fail "Google Photos is running but its upload bridge never reported (no fresh $MAC_BRIDGE/alive.json) -- reinstall it with gphotos-mac-setup"
}

# Take in every outcome the bridge has reported: a confirmation to the reclaim
# list, a refusal or a failure to the staged path's own row. The moved file is
# deleted once the row is written, which is the bridge's signal that the entry
# was consumed -- in that order, so a kill in between costs a repeat and never
# a lost confirmation. A file this pipeline did not hand over is left exactly
# where it is.
mac_collect() {
  local name state key err moved rel
  [ -r "$MAC_BRIDGE/ledger.json" ] || return 0
  while IFS="$(printf '\t')" read -r name state key err moved; do
    [ -n "$name" ] && [ -n "$moved" ] || continue
    [ -e "$MAC_INBOX/$moved" ] || continue
    rel="$(mac_state_rel_of_name "$name")"
    [ -n "$rel" ] || continue
    case "$moved" in
      Uploaded/*)
        if [ "$state" = completed ] && [ -n "$key" ] && [ "$key" != "-" ]; then
          mac_state_to "$rel" "$name" confirmed
          grep -qxF "$rel" "$RECLAIM_PENDING" 2>/dev/null || printf '%s\n' "$rel" >> "$RECLAIM_PENDING"
          rm -f "$MAC_INBOX/$moved"
          MAC_DONE=$((MAC_DONE + 1))
        fi ;;
      Failed/*)
        if [ "$err" = remote_live_photo_component_exists ]; then
          mac_state_to "$rel" "$name" exists "$err"
          log "  already in Google Photos (a Live Photo component matched by hash), kept in iCloud: $rel"
        else
          mac_fail "$rel" "$name" "$err"
          log "  upload failed ($err): $rel"
        fi
        rm -f "$MAC_INBOX/$moved" ;;
    esac
  done < <(mac_jq -r '.files | to_entries[] | select((.value.moved // "") != "")
                      | [.key, (.value.state // "-"), (.value.mediaKey // "-"), (.value.error // "-"), .value.moved] | @tsv' \
             "$MAC_BRIDGE/ledger.json" 2>/dev/null)
}

# Give up on a handoff the bridge never took: the copy was lost on the way, so
# nothing will ever report on it. ONLY while the bridge is up, because its
# ledger is the evidence -- a bridge that is not running holds no entries at
# all, and every outstanding handoff would look lost.
mac_expire() {
  local rel name state stamp now seen
  [ -r "$MAC_STATE" ] || return 0
  mac_bridge_up || return 0
  now="$(date +%s)"; seen="$(mktemp)"
  mac_jq -r '.files | keys[]' "$MAC_BRIDGE/ledger.json" > "$seen" 2>/dev/null
  # The loop rewrites the file it reads (mac_fail does): the redirection holds
  # the old inode, which mv -f replaces rather than truncates, so this pass
  # sees the rows as they were when it started.
  while IFS="$(printf '\t')" read -r rel name state stamp _; do
    [ "$state" = queued ] || continue
    case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
    [ "$stamp" -le $((now - MAC_GIVE_UP)) ] || continue
    grep -qxF "$name" "$seen" && continue
    mac_fail "$rel" "$name" never_taken_by_the_bridge
    rm -f "$MAC_INBOX/$name"
    log "  the bridge never took it in $((MAC_GIVE_UP / 3600)) h, handed over again next run: $rel"
  done < "$MAC_STATE"
  rm -f "$seen"
}

# ── What Google Photos already has ───────────────────────────────────────────
# This backend's confirmation is the reply to its OWN upload call, so it can
# only ever recognise what it uploaded itself: a library the phone's Google
# Photos backed up years ago is handed over again, file by file, and Google
# discards every one of them as a duplicate after the copy, the read and the
# upload. lib/presence.sh asks the app's own database instead, and a file it
# finds there is confirmed without being uploaded at all.
#
# THE SAME EVIDENCE THE RECLAIM ALREADY TRUSTS, from the other end: a row in
# ServerPhotos IS Google holding those bytes. What it does not say is who put
# them there, which is why the row is "present" and not "confirmed".

# One staged path's answer, cached in a file so a still that several callers
# ask about is hashed once. Echoes the media key on stdout when present; the
# exit code is gp_present's (0 present, 1 absent, 2 unknown).
mac_presence_of() {  # <rel> <cache file>
  local rel="$1" cache="$2" rc key
  # Two fields, read with IFS rather than picked apart with a literal tab in a
  # parameter expansion -- an invisible character is not something the next
  # reader of this file should have to trust.
  IFS="$(printf '\t')" read -r rc key < <(awk -F'\t' -v r="$rel" '$1 == r { print $2 "\t" $3; exit }' "$cache" 2>/dev/null)
  if [ -n "${rc:-}" ]; then
    [ "$rc" = 0 ] && printf '%s\n' "$key"
    return "$rc"
  fi
  key="$(gp_present "$STAGING/$rel")"; rc=$?
  printf '%s\t%s\t%s\n' "$rel" "$rc" "$key" >> "$cache"
  [ "$rc" = 0 ] && printf '%s\n' "$key"
  return "$rc"
}

# A staged path Google already holds: its own row, its media key beside it, and
# the reclaim list -- the same three things mac_collect does for a confirmed
# upload, minus the upload.
mac_present_confirm() {  # <rel> <media key>
  mac_state_to "$1" "${1//\//_}" present already_in_google_photos
  printf '%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" >> "$MAC_PRESENT"
  grep -qxF "$1" "$RECLAIM_PENDING" 2>/dev/null || printf '%s\n' "$1" >> "$RECLAIM_PENDING"
  MAC_PRESENT_N=$((MAC_PRESENT_N + 1))
}

# Decides each new staged path against the app's database and REWRITES the list
# it is given with only the ones that still have to be uploaded.
#
# BOUNDED BY WALL CLOCK, not by file count: the cost is dominated by reading
# every candidate's bytes (measured 2026-09-20 over this fleet's own staging
# tree: 2,404 files, 16.2 GB, 87 s -- 36 ms per file), so a first run against a
# large library would otherwise spend the whole tick hashing. Whatever the
# budget does not reach is handed over the way it always was, which is the old
# behaviour and never a deletion.
#
# ONE DATABASE COPY FOR THE WHOLE PASS (gp_db_open is idempotent): 1.4 s for
# the 100 MB copy and the 53,150-row key dump, against 36 ms per file after it.
mac_presence_pass() {  # <file of new staged paths>
  local newf="$1" cache out rel still key rc deadline
  local n_present=0 n_absent=0 n_unknown=0 n_pair=0 n_skipped=0 checked=0
  case "${PRESENCE_CHECK:-1}" in 1|yes|true) ;; *) return 0 ;; esac
  if ! gp_db_open; then
    log "  Google Photos' own library is not readable ($GP_DB_REASON): every new file is handed over as before"
    return 0
  fi
  # WHICH database answered, how much it knew and how fresh it is. This check
  # decides what is never uploaded and what may leave iCloud, so a run that
  # consulted a stale or nearly empty library says so in the log rather than
  # only in its results.
  local db db_age
  db="$(gp_db_path)"
  db_age=$(( ( $(date +%s) - $(/usr/bin/stat -f %m "$db" 2>/dev/null || date +%s) ) / 60 ))
  log "  Google Photos' own library: $(gp_db_rows) item(s), written ${db_age} min ago ($db)"
  cache="$(mktemp)"; out="$(mktemp)"
  # A config file is a human's file: a budget that is not a number would
  # otherwise leave `deadline` unset and abort the whole sync at the first
  # comparison, under set -u.
  case "${PRESENCE_BUDGET:-}" in ''|*[!0-9]*) PRESENCE_BUDGET=300 ;; esac
  deadline=$((SECONDS + PRESENCE_BUDGET))
  phase "checking what Google Photos already has"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ "$SECONDS" -ge "$deadline" ]; then
      n_skipped=$((n_skipped + 1)); printf '%s\n' "$rel" >> "$out"; continue
    fi
    # A Live Photo is ONE item at Google, keyed by the still's bytes, so the
    # motion component is asked about through its still. gp_still_of answers
    # only for a video that has a still beside it in the staging tree.
    still="$(gp_still_of "$STAGING" "$rel")" || still="$rel"
    key="$(mac_presence_of "$still" "$cache")"; rc=$?
    checked=$((checked + 1))
    case "$rc" in
      0) mac_present_confirm "$rel" "$key"
         n_present=$((n_present + 1))
         [ "$still" = "$rel" ] || n_pair=$((n_pair + 1)) ;;
      1) n_absent=$((n_absent + 1)); printf '%s\n' "$rel" >> "$out" ;;
      # UNKNOWN IS UPLOADED. An unreadable database, a missing sha1 or a file
      # whose bytes the cloud folder has not materialised all land here, and
      # each of them must cost a duplicate upload rather than a deletion.
      *) n_unknown=$((n_unknown + 1)); printf '%s\n' "$rel" >> "$out" ;;
    esac
    [ $((checked % 50)) -eq 0 ] && phase "checking what Google Photos already has: $checked"
  done < "$newf"
  mv -f "$out" "$newf"
  rm -f "$cache"
  # THE COPY OF THE DATABASE GOES NOW, not at process exit: it is the whole
  # file (about 100 MB), this runs every fifteen minutes, and nothing else
  # would ever remove it -- gigabytes a day leaked by the step that exists to
  # reclaim space. gp_db_open is idempotent, so a later gp_present simply makes
  # a fresh copy.
  gp_db_close
  log "already in Google Photos: $n_present of $((n_present + n_absent + n_unknown)) checked (of which $n_pair Live Photo component(s) by their still); to upload: $n_absent; undecidable, so uploaded anyway: $n_unknown"
  [ "$n_skipped" -gt 0 ] \
    && log "  the ${PRESENCE_BUDGET}s presence budget ran out with $n_skipped file(s) unchecked; they are handed over as usual"
  return 0
}

# ── The handoff ──────────────────────────────────────────────────────────────

# The staged files not handled yet, sorted, into $1; MAC_STAGED holds the
# count of everything staged. Fails the run when the tree cannot be listed.
MAC_STAGED=0
mac_list_new() {
  local cand handled
  cand="$(mktemp)"; handled="$(mktemp)"
  phase "listing the staging tree"
  enumerate_staging > "$cand"
  case "$ENUM_ERR" in
    *"Operation not permitted"*)
      fail "no access to the staging directory (macOS refused this process; a sync over a cloud-provider mount must run as a child of the app bundle — see 'Staging' in the README)" ;;
  esac
  if [ ! -s "$cand" ] && [ -n "$(ls "$STAGING" 2>/dev/null)" ]; then
    fail "staging tree unreadable: the listing of $STAGING found no media although it has entries"
  fi
  MAC_STAGED="$(count_lines "$cand")"
  mac_handled > "$handled"
  comm -23 "$cand" "$handled" > "$1"
  rm -f "$cand" "$handled"
}

# Copies every new staged file into the folder: all of them to dot-names first,
# then renamed into place back to back, so the bridge (which skips dot-names
# and waits out any file whose inode changed in the last five seconds) sees a
# Live Photo's still and video together. cp -p keeps the photo's own date,
# which the engine turns into the item's timestamp.
# <list> is the new staged paths, already listed and already put past the
# presence check by the caller. Without it this does both itself, so a call
# from anywhere else is still complete.
mac_handoff() {  # [file of new staged paths]
  local newf batch rel name src_sz dst_sz room cap target evicted=0 empty=0 short=0 total_new clash own=0
  local hyd_end hyd_secs hydrated=0 hyd_slow=0 hyd_stub=0 hyd_err=0 hyd_untried=0
  # A config file is a human's file (see mac_presence_pass): a bound that is not
  # a number falls back to the default rather than aborting the run under set -u,
  # and 10# keeps a digits-only "08" from being octal (an arithmetic error that
  # would abort the handoff).
  case "${MAC_HYDRATE_TIMEOUT:-}" in ''|*[!0-9]*) MAC_HYDRATE_TIMEOUT=120 ;; *) MAC_HYDRATE_TIMEOUT=$((10#$MAC_HYDRATE_TIMEOUT)) ;; esac
  case "${MAC_HYDRATE_BUDGET:-}" in ''|*[!0-9]*) MAC_HYDRATE_BUDGET=600 ;; *) MAC_HYDRATE_BUDGET=$((10#$MAC_HYDRATE_BUDGET)) ;; esac
  hyd_end=$((SECONDS + MAC_HYDRATE_BUDGET))
  batch="$(mktemp)"
  rm -f "$MAC_INBOX"/.incoming-* 2>/dev/null
  if [ $# -ge 1 ] && [ -n "$1" ]; then
    newf="$1"
  else
    newf="$(mktemp)"; own=1
    mac_list_new "$newf"
    mac_presence_pass "$newf"
  fi
  total_new="$(count_lines "$newf")"
  room=$((MAC_INBOX_MAX - $(mac_outstanding | mac_count)))
  cap="$PUSH_CAP"; [ "$room" -lt "$cap" ] && cap="$room"; [ "$cap" -lt 0 ] && cap=0
  target=$(( total_new < cap ? total_new : cap ))
  [ "$target" -gt 0 ] && phase "pushing 0 of $target to Google Photos"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ "$(count_lines "$batch")" -ge "$cap" ] && break
    # The flat name must map back to ONE staged path while it is in flight:
    # "a/b_c" and "a_b/c" both flatten to "a_b_c", and the second would be
    # confirmed and deleted from iCloud on the strength of the first's upload.
    # The second waits while the first is queued (or in this batch); once the
    # first is no longer queued the name is free again. Asked before the
    # hydration below, so a file that waits anyway is not fetched for nothing.
    name="${rel//\//_}"
    clash="$(mac_state_rel_of_name "$name")"
    [ -z "$clash" ] && clash="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$batch")"
    if [ -n "$clash" ] && [ "$clash" != "$rel" ]; then
      log "  name clash with a file still uploading, waits for the next run: $rel"; continue
    fi
    # An online-only stub is fetched before it is copied, because cp would read
    # it with no bound at all (lib/fs.sh). Only candidates that get this far are
    # fetched, so a run reads at most its cap's worth, and every read is bounded
    # twice: per file, and by what is left of the run's budget, so a Drive that
    # serves nothing costs one budget per run and not the run.
    if is_dataless "$STAGING/$rel"; then
      hyd_secs=$((hyd_end - SECONDS))
      [ "$hyd_secs" -gt "$MAC_HYDRATE_TIMEOUT" ] && hyd_secs="$MAC_HYDRATE_TIMEOUT"
      if [ "$hyd_secs" -le 0 ]; then
        hyd_untried=$((hyd_untried + 1)); evicted=$((evicted + 1)); continue
      fi
      phase "pushing $(count_lines "$batch") of $target to Google Photos: fetching an online-only file"
      hydrate_bounded "$STAGING/$rel" "$hyd_secs"
      # Timeouts are named, since each costs up to the per-file bound every run
      # and the budget caps how many there can be; the other two are counted
      # and only the first is named, because a provider that fails fast would
      # fail every candidate the same way.
      case $? in
        0)   hydrated=$((hydrated + 1)) ;;
        124) hyd_slow=$((hyd_slow + 1)); evicted=$((evicted + 1))
             log "  still online-only after ${hyd_secs}s of reading, left for the next run: $rel"; continue ;;
        2)   hyd_err=$((hyd_err + 1)); evicted=$((evicted + 1))
             [ "$hyd_err" -eq 1 ] && log "  an online-only file could not be read (the first of this run): $rel"; continue ;;
        *)   hyd_stub=$((hyd_stub + 1)); evicted=$((evicted + 1))
             [ "$hyd_stub" -eq 1 ] && log "  still online-only after a full read (the first of this run): $rel"; continue ;;
      esac
    fi
    src_sz="$(/usr/bin/stat -f %z "$STAGING/$rel" 2>/dev/null || echo 0)"
    if [ "${src_sz:-0}" -eq 0 ]; then
      empty=$((empty + 1)); log "  empty staged file skipped (delete it to let icloudpd fetch it again): $rel"; continue
    fi
    if /bin/cp -p "$STAGING/$rel" "$MAC_INBOX/.incoming-$name" 2>/dev/null \
       && dst_sz="$(/usr/bin/stat -f %z "$MAC_INBOX/.incoming-$name" 2>/dev/null)" && [ "$dst_sz" = "$src_sz" ]; then
      printf '%s\t%s\n' "$name" "$rel" >> "$batch"
      [ $(( $(count_lines "$batch") % 25 )) -eq 0 ] && phase "pushing $(count_lines "$batch") of $target to Google Photos"
    else
      log "WARNING: short copy, not handed over: $rel (staged $src_sz bytes, copied ${dst_sz:-?})"
      rm -f "$MAC_INBOX/.incoming-$name"; short=$((short + 1))
    fi
  done < "$newf"
  while IFS="$(printf '\t')" read -r name rel; do
    [ -n "$name" ] || continue
    if mv -f "$MAC_INBOX/.incoming-$name" "$MAC_INBOX/$name"; then
      mac_state_to "$rel" "$name" queued
      MAC_HANDED=$((MAC_HANDED + 1))
    fi
  done < "$batch"
  log "staged $MAC_STAGED media file(s); new since last run: $total_new; handed to Google Photos $MAC_HANDED (cap $cap), short $short, hydrated $hydrated, evicted-skipped $evicted, empty-skipped $empty; given up after $MAC_RETRIES failures so far: $(mac_given_up | mac_count)"
  [ "$evicted" -gt 0 ] \
    && log "  online-only files not handed over: $hyd_slow still blocked after the ${MAC_HYDRATE_TIMEOUT}s per-file bound, $hyd_stub still online-only after a full read, $hyd_err unreadable, $hyd_untried not tried (the ${MAC_HYDRATE_BUDGET}s hydration budget was spent, or MAC_HYDRATE_TIMEOUT is 0)"
  [ "$total_new" -gt "$MAC_HANDED" ] && log "$((total_new - MAC_HANDED)) left for the next run"
  [ "$own" -eq 1 ] && rm -f "$newf"
  rm -f "$batch"
}

# Wait for Google's answers to the handoffs in flight, bounded by UPLOAD_WAIT
# (like the emulator's verify pass), and report what came back. Uploads keep
# going after the wait; the next run collects whatever finished in between.
# Every fourth poll says why nothing is moving, if that is the case: the engine
# uploads only while the app has a visible window, and none of its three
# reasons for standing still is visible from outside.
mac_wait_for_google() {  # <how many were outstanding when the wait began>
  local start="$1" waiting end polls=0
  end=$((SECONDS + UPLOAD_WAIT + start * 2))
  phase "verifying uploads: 0 of $start confirmed"
  while :; do
    sleep 15
    mac_collect
    polls=$((polls + 1))
    waiting="$(mac_outstanding | mac_count)"
    [ "$waiting" -eq 0 ] && break
    [ "$SECONDS" -ge "$end" ] && break
    mac_bridge_up || fail "the Google Photos upload bridge stopped reporting (the app quit or hung)"
    if [ $((polls % 4)) -eq 1 ]; then
      if [ "$(mac_alive online)" != true ]; then
        log "  Google Photos cannot upload right now: its window is minimised or hidden, or the Mac is offline (uploads resume on their own once it is visible)"
      elif [ "$(mac_alive paused)" = true ]; then
        log "  uploads are PAUSED in Google Photos' GoToHP settings"
      elif [ "$(mac_alive wifiOnly)" = true ] && [ "$(mac_alive wifi)" != true ]; then
        log "  Google Photos is still set to Wi-Fi only and the Mac is not on Wi-Fi (the bridge retries turning that off)"
      fi
    fi
    [ $((polls % 4)) -eq 0 ] && log "upload in progress: $MAC_DONE/$start confirmed, $waiting waiting, $MAC_FAILURES failed"
    phase "verifying uploads: $MAC_DONE of $start confirmed"
  done
  printf '%s %s %s %s\n' "$MAC_DONE" "$start" "$MAC_FAILURES" "$(date +%s)" > "$STATE_DIR/upload-status"
  if [ "$waiting" -eq 0 ] && [ "$MAC_FAILURES" -eq 0 ]; then
    log "UPLOAD CONFIRMED: $MAC_DONE file(s) backed up to Google Photos (media key for each)"
    date +%s > "$STATE_DIR/last-upload-confirmed"
  else
    log "WARNING: upload NOT complete — $MAC_DONE of $start confirmed, $waiting still waiting, $MAC_FAILURES failed"
    log "         the ones still waiting keep uploading; the next run collects them"
    rm -f "$STATE_DIR/last-upload-confirmed"
  fi
}

# The whole backend: prerequisites, the outcomes waiting since last time, then
# the handoff and the wait, publishing the counts the menu bar reads.
mac_sync() {
  [ -d "$GPHOTOS_APP" ] || fail "Google Photos is not installed at $GPHOTOS_APP — run gphotos-mac-setup"
  command -v jq >/dev/null 2>&1 || [ -x /usr/bin/jq ] || fail "jq missing (it ships with macOS 15 and later)"
  mkdir -p "$MAC_INBOX" 2>/dev/null || fail "cannot create $MAC_INBOX"
  mac_migrate
  local waiting new newf
  mac_collect
  # A quiet tick is one listing and one read of the bridge's ledger: the app
  # is launched only when there is something to hand over or to wait for.
  newf="$(mktemp)"; mac_list_new "$newf"; new="$(count_lines "$newf")"
  # THE PRESENCE CHECK COMES BEFORE THE LAUNCH, deliberately: a tick whose new
  # files Google Photos already holds now confirms them from the database and
  # ends without opening the app at all -- which is the whole point of asking
  # before uploading rather than after.
  if [ "$new" -gt 0 ]; then
    mac_presence_pass "$newf"
    new="$(count_lines "$newf")"
  fi
  waiting="$(mac_outstanding | mac_count)"
  if [ "$new" -eq 0 ] && [ "$waiting" -eq 0 ]; then
    rm -f "$newf"
    log "staged $MAC_STAGED media file(s); nothing new, nothing waiting for Google Photos"
    mac_stamp_if_clean
    return 0
  fi
  # The app, and its sign-in, before any copying: a Mac that has never signed
  # in would otherwise fill ~/Pictures with a library's worth of copies.
  mac_launch
  case "$(mac_alive engine)" in true|1) ;; *) fail "this Google Photos has no GoToHP engine (the IPA must carry the Gunshot tweak's GunshotJailed.dylib) — run gphotos-mac-setup" ;; esac
  [ "$(mac_alive account)" = true ] || fail "Google Photos is not signed in (open it and sign in once; the bridge reports no account)"
  mac_expire
  [ "$new" -gt 0 ] && mac_handoff "$newf"
  rm -f "$newf"
  waiting="$(mac_outstanding | mac_count)"
  if [ "$waiting" -eq 0 ]; then
    log "nothing waiting for Google Photos"
    mac_stamp_if_clean
    return 0
  fi
  mac_wait_for_google "$waiting"
}
