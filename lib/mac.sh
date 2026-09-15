#!/usr/bin/env bash
# The Apple silicon half of avd-photos-sync (PHOTOS_BACKEND=mac): staged
# originals go to Google Photos for iPhone and iPad running natively on this
# Mac, through the folder ios/gp-bridge.m watches, and Google's answer comes
# back through the bridge's ledger. Sourced by avd-photos-sync after its own
# helpers (log, phase, fail, count_lines, enumerate_staging, ENUM_ERR);
# mac_sync stands in for steps 2 to 5 of the emulator path, and step 6, the
# iCloud reclaim, is the same code for both.
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

MAC_LEDGER="$STATE_DIR/mac-queued.tsv"         # <name> TAB <staged rel>, one line per handoff
MAC_CONFIRMED="$STATE_DIR/mac-confirmed.list"  # staged rel: Google answered with a media key
MAC_FAILED="$STATE_DIR/mac-failed.tsv"         # <staged rel> TAB <engine error>, one line per failure
# A Live Photo pair the engine refused because Google already holds one of its
# two components (by hash). Neither confirmed nor retried: which component
# matched is not reported, so the pair stays in iCloud -- the safe direction.
MAC_EXISTS="$STATE_DIR/mac-exists.list"
MAC_RETRIES=3                                  # handoffs per file before it is left alone
MAC_INBOX="$GPHOTOS_UPLOAD_DIR"
MAC_BRIDGE="$MAC_INBOX/.bridge"
MAC_HANDED=0                                   # handed over this run, for the "done" line

# /usr/bin/jq ships with macOS since 15; a jq on PATH does as well.
mac_jq() {
  if [ -x /usr/bin/jq ]; then /usr/bin/jq "$@"; else jq "$@"; fi
}

# Everything handled already: handed over and not failed, confirmed, or refused
# as already in Google. Sorted, one staged rel per line.
mac_handled() {
  { cut -f2 "$MAC_LEDGER" 2>/dev/null; cat "$MAC_CONFIRMED" "$MAC_EXISTS" 2>/dev/null; } | grep . | sort -u
}

# Handed over and still waiting for Google's answer.
mac_outstanding() {
  cut -f2 "$MAC_LEDGER" 2>/dev/null | grep . | sort -u \
    | comm -23 - <(cat "$MAC_CONFIRMED" "$MAC_EXISTS" 2>/dev/null | grep . | sort -u)
}

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

# Take in every outcome the bridge has reported: confirmations to the reclaim
# list, failures to the retry count. The moved file is deleted once recorded,
# which is the bridge's signal that the entry was consumed. A file this
# pipeline did not hand over is left exactly where it is.
mac_collect() {
  local name state key err moved rel
  [ -r "$MAC_BRIDGE/ledger.json" ] || return 0
  while IFS="$(printf '\t')" read -r name state key err moved; do
    [ -n "$name" ] && [ -n "$moved" ] || continue
    [ -e "$MAC_INBOX/$moved" ] || continue
    rel="$(awk -F'\t' -v n="$name" '$1 == n { r = $2 } END { if (r != "") print r }' "$MAC_LEDGER" 2>/dev/null)"
    [ -n "$rel" ] || continue
    case "$moved" in
      Uploaded/*)
        if [ "$state" = completed ] && [ -n "$key" ] && [ "$key" != "-" ]; then
          grep -qxF "$rel" "$MAC_CONFIRMED" 2>/dev/null || printf '%s\n' "$rel" >> "$MAC_CONFIRMED"
          printf '%s\n' "$rel" >> "$RECLAIM_PENDING"
          rm -f "$MAC_INBOX/$moved"
        fi ;;
      Failed/*)
        if [ "$err" = remote_live_photo_component_exists ]; then
          grep -qxF "$rel" "$MAC_EXISTS" 2>/dev/null || printf '%s\n' "$rel" >> "$MAC_EXISTS"
          log "  already in Google Photos (a Live Photo component matched by hash), kept in iCloud: $rel"
        else
          printf '%s\t%s\n' "$rel" "${err:--}" >> "$MAC_FAILED"
          # Out of the ledger, so the next run hands it over again while it
          # has retries left.
          awk -F'\t' -v n="$name" '$1 != n' "$MAC_LEDGER" > "$MAC_LEDGER.tmp" && mv -f "$MAC_LEDGER.tmp" "$MAC_LEDGER"
          log "  upload failed ($err): $rel"
        fi
        rm -f "$MAC_INBOX/$moved" ;;
    esac
  done < <(mac_jq -r '.files | to_entries[] | select((.value.moved // "") != "")
                      | [.key, (.value.state // "-"), (.value.mediaKey // "-"), (.value.error // "-"), .value.moved] | @tsv' \
             "$MAC_BRIDGE/ledger.json" 2>/dev/null)
}

# Seeds the ledger on the first run of this backend on a Mac whose emulator
# pipeline already confirmed part of the library, so those are not sent again
# (they would dedupe at Google, but at the cost of copying and hashing them).
mac_seed() {
  [ -e "$MAC_LEDGER" ] && return 0
  : > "$MAC_LEDGER"
  if [ -s "$RECLAIM_PENDING" ] || [ -s "$STATE_DIR/reclaimed.list" ]; then
    cat "$RECLAIM_PENDING" "$STATE_DIR/reclaimed.list" 2>/dev/null | grep . | sort -u > "$MAC_CONFIRMED.seed"
    sort -u "$MAC_CONFIRMED" "$MAC_CONFIRMED.seed" 2>/dev/null > "$MAC_CONFIRMED.tmp" && mv -f "$MAC_CONFIRMED.tmp" "$MAC_CONFIRMED"
    log "first run on Google Photos for Mac: $(count_lines "$MAC_CONFIRMED.seed") file(s) the emulator already confirmed are not sent again"
    rm -f "$MAC_CONFIRMED.seed"
  fi
}

# Copies every new staged file into the folder: all of them to dot-names first,
# then renamed into place back to back, so the bridge (which skips dot-names
# and waits out any file whose inode changed in the last five seconds) sees a
# Live Photo's still and video together. cp -p keeps the photo's own date,
# which the engine turns into the item's timestamp.
mac_handoff() {
  local cand handled newf batch rel name tries src_sz dst_sz room cap evicted=0 empty=0 skipped=0 short=0 total_new
  cand="$(mktemp)"; handled="$(mktemp)"; newf="$(mktemp)"; batch="$(mktemp)"
  rm -f "$MAC_INBOX"/.incoming-* 2>/dev/null
  phase "listing the staging tree"
  enumerate_staging > "$cand"
  case "$ENUM_ERR" in
    *"Operation not permitted"*)
      fail "no access to the staging directory (macOS refused this process; a sync over a cloud-provider mount must run as a child of the app bundle — see 'Staging' in the README)" ;;
  esac
  if [ ! -s "$cand" ] && [ -n "$(ls "$STAGING" 2>/dev/null)" ]; then
    fail "staging tree unreadable: the listing of $STAGING found no media although it has entries"
  fi
  mac_handled > "$handled"
  comm -23 "$cand" "$handled" > "$newf"
  total_new="$(count_lines "$newf")"
  room=$((MAC_INBOX_MAX - $(mac_outstanding | grep -c .)))
  cap="$PUSH_CAP"; [ "$room" -lt "$cap" ] && cap="$room"; [ "$cap" -lt 0 ] && cap=0
  [ "$total_new" -gt 0 ] && [ "$cap" -gt 0 ] && phase "pushing 0 of $(( total_new < cap ? total_new : cap )) to Google Photos"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ "$(count_lines "$batch")" -ge "$cap" ] && break
    tries="$(awk -F'\t' -v r="$rel" '$1 == r { n++ } END { print n + 0 }' "$MAC_FAILED" 2>/dev/null)"
    if [ "${tries:-0}" -ge "$MAC_RETRIES" ]; then skipped=$((skipped + 1)); continue; fi
    # An online-only stub can block forever when read: metadata only, skip it.
    if /usr/bin/stat -f %Sf "$STAGING/$rel" 2>/dev/null | grep -q dataless; then evicted=$((evicted + 1)); continue; fi
    src_sz="$(/usr/bin/stat -f %z "$STAGING/$rel" 2>/dev/null || echo 0)"
    if [ "${src_sz:-0}" -eq 0 ]; then
      empty=$((empty + 1)); log "  empty staged file skipped (delete it to let icloudpd fetch it again): $rel"; continue
    fi
    name="${rel//\//_}"
    if /bin/cp -p "$STAGING/$rel" "$MAC_INBOX/.incoming-$name" 2>/dev/null \
       && dst_sz="$(/usr/bin/stat -f %z "$MAC_INBOX/.incoming-$name" 2>/dev/null)" && [ "$dst_sz" = "$src_sz" ]; then
      printf '%s\t%s\n' "$name" "$rel" >> "$batch"
      [ $(( $(count_lines "$batch") % 25 )) -eq 0 ] && phase "pushing $(count_lines "$batch") of $(( total_new < cap ? total_new : cap )) to Google Photos"
    else
      log "WARNING: short copy, not handed over: $rel (staged $src_sz bytes, copied ${dst_sz:-?})"
      rm -f "$MAC_INBOX/.incoming-$name"; short=$((short + 1))
    fi
  done < "$newf"
  while IFS="$(printf '\t')" read -r name rel; do
    [ -n "$name" ] || continue
    if mv -f "$MAC_INBOX/.incoming-$name" "$MAC_INBOX/$name"; then
      printf '%s\t%s\n' "$name" "$rel" >> "$MAC_LEDGER"
      MAC_HANDED=$((MAC_HANDED + 1))
    fi
  done < "$batch"
  log "staged $(count_lines "$cand") media file(s); new since last run: $total_new; handed to Google Photos $MAC_HANDED (cap $cap), short $short, evicted-skipped $evicted, empty-skipped $empty, given up after $MAC_RETRIES failures $skipped"
  [ "$total_new" -gt "$MAC_HANDED" ] && log "$((total_new - MAC_HANDED)) left for the next run"
  rm -f "$cand" "$handled" "$newf" "$batch"
}

# The whole backend: prerequisites, handoff, then wait for Google's answers
# (bounded by UPLOAD_WAIT, like the emulator's verify pass), publishing the
# counts the menu bar reads. Uploads keep going after the wait; the next run
# collects whatever finished in between.
mac_sync() {
  [ -d "$GPHOTOS_APP" ] || fail "Google Photos is not installed at $GPHOTOS_APP — run gphotos-mac-setup"
  command -v jq >/dev/null 2>&1 || [ -x /usr/bin/jq ] || fail "jq missing (it ships with macOS 15 and later)"
  mkdir -p "$MAC_INBOX" 2>/dev/null || fail "cannot create $MAC_INBOX"
  mac_seed
  mac_collect
  mac_handoff
  local waiting start end done_now failed_now polls=0 online prev_conf prev_fail
  waiting="$(mac_outstanding | grep -c .)"
  if [ "$waiting" -eq 0 ]; then
    log "nothing waiting for Google Photos"
    date +%s > "$STATE_DIR/last-upload-confirmed"
    return 0
  fi
  mac_launch
  case "$(mac_alive engine)" in true|1) ;; *) fail "this Google Photos has no GoToHP engine (the IPA must carry the Gunshot tweak's GunshotJailed.dylib) — run gphotos-mac-setup" ;; esac
  [ "$(mac_alive account)" = true ] || fail "Google Photos is not signed in (open it and sign in once; the bridge reports no account)"
  prev_conf="$(count_lines "$MAC_CONFIRMED")"; prev_fail="$(count_lines "$MAC_FAILED")"
  start="$waiting"; end=$((SECONDS + UPLOAD_WAIT + waiting * 2))
  phase "verifying uploads: 0 of $start confirmed"
  while :; do
    sleep 15
    mac_collect
    polls=$((polls + 1))
    waiting="$(mac_outstanding | grep -c .)"
    done_now=$(( $(count_lines "$MAC_CONFIRMED") - prev_conf ))
    failed_now=$(( $(count_lines "$MAC_FAILED") - prev_fail ))
    [ "$waiting" -eq 0 ] && break
    [ "$SECONDS" -ge "$end" ] && break
    mac_bridge_up || fail "the Google Photos upload bridge stopped reporting (the app quit or hung)"
    online="$(mac_alive online)"
    if [ "$online" != true ] && [ $((polls % 4)) -eq 1 ]; then
      log "  Google Photos cannot upload right now: its window is minimised or hidden, or the Mac is offline (uploads resume on their own once it is visible)"
    fi
    [ $((polls % 4)) -eq 0 ] && log "upload in progress: $done_now/$start confirmed, $waiting waiting, $failed_now failed"
    phase "verifying uploads: $done_now of $start confirmed"
  done
  printf '%s %s %s %s\n' "$done_now" "$start" "$failed_now" "$(date +%s)" > "$STATE_DIR/upload-status"
  if [ "$waiting" -eq 0 ] && [ "$failed_now" -eq 0 ]; then
    log "UPLOAD CONFIRMED: $done_now file(s) backed up to Google Photos (media key for each)"
    date +%s > "$STATE_DIR/last-upload-confirmed"
  else
    log "WARNING: upload NOT complete — $done_now of $start confirmed, $waiting still waiting, $failed_now failed"
    log "         the ones still waiting keep uploading; the next run collects them"
    rm -f "$STATE_DIR/last-upload-confirmed"
  fi
}
