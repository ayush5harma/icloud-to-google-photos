#!/usr/bin/env bash
# The Mac backend's bookkeeping, judged by effect on a scratch state: lib/mac.sh
# sourced the way avd-photos-sync sources it (set -uo pipefail), with the
# sync's own helpers stubbed and a bridge ledger written by hand. No Google
# Photos, no network. Covers what the two reviews of 2026-09-16 found by
# reading: the migration off the four bookkeeping files under pipefail, the
# give-up rule and its dependence on the bridge being up, an unstamped row, the
# name-clash guard, the collect that feeds the iCloud reclaim, and the way back
# in for a file that was given up on.
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
printf 'ICLOUD_USERNAME=t@example.invalid\nSTAGING="%s/staging"\nPHOTOS_BACKEND=mac\n' "$T" > "$T/config/config"

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

# There is no Google Photos here, so the bridge's liveness is faked from this
# shell: mac_expire refuses to give up on anything while the bridge is down,
# which is the rule under test, not the process lookup.
mac_app_pid() { printf '%s\n' "$$"; }
bridge_up()   { printf '{"pid":%s,"time":%s,"engine":true,"account":true}\n' "$$" "$(date +%s)" > "$MAC_BRIDGE/alive.json"; }
bridge_down() { rm -f "$MAC_BRIDGE/alive.json"; }
row() { awk -F'\t' -v r="$1" -v f="$2" '$1 == r { print $f }' "$MAC_STATE"; }

echo "migrate"
# A scratch state of its own, so the migration is judged on a directory that
# holds exactly the files the four-file layout left behind.
M="$T/migrate"; mkdir -p "$M"
KEEP_STATE_DIR="$STATE_DIR"; KEEP_MAC_STATE="$MAC_STATE"; KEEP_RECLAIM_PENDING="$RECLAIM_PENDING"
STATE_DIR="$M"; MAC_STATE="$M/mac-state.tsv"; RECLAIM_PENDING="$M/reclaim-pending.list"
printf 'old_1.HEIC\told/1.HEIC\t100\n' >  "$M/mac-queued.tsv"      # handed over, stamped
printf 'old_2.HEIC\told/2.HEIC\n'      >> "$M/mac-queued.tsv"      # the two-column line the first runs wrote
printf 'old/3.HEIC\tupload_failed\nold/3.HEIC\tquota\n' > "$M/mac-failed.tsv"
printf 'old/4.HEIC\n' > "$M/mac-exists.list"
printf 'old/5.HEIC\n' > "$M/mac-confirmed.list"
printf 'emu/6.HEIC\n' > "$M/reclaimed.list"
printf 'emu/7.HEIC\n' > "$RECLAIM_PENDING"
mac_migrate
check "a stamped handoff stays queued, with its stamp" test "$(row old/1.HEIC 3)/$(row old/1.HEIC 4)" = "queued/100"
check "an unstamped handoff is as old as it gets" test "$(row old/2.HEIC 3)/$(row old/2.HEIC 4)" = "queued/0"
check "failures become one row carrying the try count and the last reason" test "$(row old/3.HEIC 3)/$(row old/3.HEIC 5)/$(row old/3.HEIC 6)" = "failed/2/quota"
check "a Live Photo Google already holds stays exists" test "$(row old/4.HEIC 3)" = exists
check "a confirmed path stays confirmed" test "$(row old/5.HEIC 3)" = confirmed
check "the emulator's reclaim lists are confirmed, and say so" test "$(row emu/6.HEIC 3)/$(row emu/6.HEIC 6)" = "confirmed/emulator" -a "$(row emu/7.HEIC 3)" = confirmed
check "a row the old files never named gets its flat name" test "$(row emu/6.HEIC 2)" = emu_6.HEIC
check "the log counts what the emulator had confirmed" grep -q '2 file(s) the emulator already confirmed' <<<"$LOGGED"
printf 'emu/8.HEIC\n' >> "$M/reclaimed.list"; mac_migrate
check "a second call does not migrate again" test "$(count_lines "$MAC_STATE")" = 7
STATE_DIR="$KEEP_STATE_DIR"; MAC_STATE="$KEEP_MAC_STATE"; RECLAIM_PENDING="$KEEP_RECLAIM_PENDING"

echo "first run"
LOGGED=""
printf 'old/1.HEIC\nold/2.HEIC\n' > "$STATE_DIR/reclaimed.list"
printf 'old/3.HEIC\n' > "$RECLAIM_PENDING"
mac_migrate
check "the emulator's lists alone, with no other file (pipefail on)" test "$(mac_state_rels confirmed | sort | tr '\n' ' ')" = "old/1.HEIC old/2.HEIC old/3.HEIC "
check "the state file exists only after the migration" test -e "$MAC_STATE"
check "the log names what it wrote" grep -q '3 file(s)' <<<"$LOGGED"

echo "handoff"
printf 'x' > "$T/staging/2026/05/IMG_1.HEIC"; printf 'yy' > "$T/staging/2026/05/IMG_1_HEVC.MOV"; printf 'zzz' > "$T/staging/2026/05/IMG_2.HEIC"
printf 'p' > "$T/staging/a/b_c/P.HEIC"; printf 'q' > "$T/staging/a_b/c/P.HEIC"
MAC_HANDED=0; mac_handoff
check "four handed over, the name clash held back" test "$MAC_HANDED" = 4
check "the clash is logged" grep -q 'name clash' <<<"$LOGGED"
check "copies are in the folder under flat names" test -f "$MAC_INBOX/2026_05_IMG_1.HEIC" -a -f "$MAC_INBOX/2026_05_IMG_1_HEVC.MOV"
check "the new rows are queued and stamped" test "$(awk -F'\t' 'NF == 6 && $3 == "queued" && $4 ~ /^[0-9]+$/' "$MAC_STATE" | wc -l | tr -d ' ')" = 4
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
check "a media key confirms the staged path" test "$(row 2026/05/IMG_2.HEIC 3)" = confirmed
check "and only that path reaches the reclaim list" test "$(grep -v '^old/' "$RECLAIM_PENDING" | tr '\n' ' ')" = "2026/05/IMG_2.HEIC "
check "the consumed copy is deleted" test ! -e "$MAC_INBOX/Uploaded/2026_05_IMG_2.HEIC"
check "an existing Live Photo is kept in iCloud, not confirmed, not failed" test "$(mac_state_rels exists | wc -l | tr -d ' ')" = 2 -a "$MAC_FAILURES" = 0
check "a pending job is left alone" test -f "$MAC_INBOX/a_b_c_P.HEIC"
check "outstanding is the pending one" test "$(mac_outstanding | tr '\n' ' ')" = "a/b_c/P.HEIC "

echo "give up"
old=$(( $(date +%s) - MAC_GIVE_UP - 60 ))
awk -F'\t' -v OFS='\t' -v o="$old" '$3 == "queued" { $4 = o } 1' "$MAC_STATE" > "$MAC_STATE.t" && mv "$MAC_STATE.t" "$MAC_STATE"
printf 'lost/L.HEIC\tlost_L.HEIC\tqueued\t0\t0\t-\n' >> "$MAC_STATE"   # the unstamped row the migration writes
printf 'x' > "$MAC_INBOX/lost_L.HEIC"
bridge_down; mac_expire
check "nothing is given up while the bridge is down (its ledger is the evidence)" test "$(row lost/L.HEIC 3)" = queued
bridge_up; mac_expire
check "a name the bridge holds is not given up however old" test "$(row a/b_c/P.HEIC 3)" = queued
check "a handoff the bridge never saw is given up" test "$(row lost/L.HEIC 3)/$(row lost/L.HEIC 5)/$(row lost/L.HEIC 6)" = "failed/1/never_taken_by_the_bridge"
check "its copy is removed" test ! -e "$MAC_INBOX/lost_L.HEIC"
check "a confirmed row is never given up" test "$(row 2026/05/IMG_2.HEIC 3)" = confirmed

echo "clash release"
mkdir -p "$T/staging/lost"; printf 'x' > "$T/staging/lost/L.HEIC"
mac_handoff
check "the held-back path waits while its twin is pending" grep -q 'name clash' <<<"$LOGGED"
check "a failure with tries left is handed over again" test "$(row lost/L.HEIC 3)" = queued
# confirm the twin: the bridge moved it, the sync collects it
mkdir -p "$MAC_INBOX/Uploaded"; mv "$MAC_INBOX/a_b_c_P.HEIC" "$MAC_INBOX/Uploaded/"
cat > "$MAC_BRIDGE/ledger.json" <<'J'
{"files":{"a_b_c_P.HEIC":{"id":"j3","state":"completed","mediaKey":"AF1Qtest2","moved":"Uploaded/a_b_c_P.HEIC"}}}
J
mac_collect; LOGGED=""; MAC_HANDED=0; mac_handoff
check "once the twin is confirmed the same flat name is handed over" test -f "$MAC_INBOX/a_b_c_P.HEIC" -a "$MAC_HANDED" -ge 1
check "and the name maps to the NEW staged path" test "$(mac_state_rel_of_name a_b_c_P.HEIC)" = "a_b/c/P.HEIC"

echo "given up, and the way back"
mac_fail lost/L.HEIC lost_L.HEIC upload_failed
mac_fail lost/L.HEIC lost_L.HEIC upload_failed   # three in all: out of tries
check "MAC_RETRIES failures put it out of the pipeline" test "$(mac_given_up | tr '\n' ' ')" = "lost/L.HEIC "
check "and it counts as handled, so no run hands it over again" grep -qx 'lost/L.HEIC' <<<"$(mac_handled)"
check "the backlog does not carry it" none grep -qx 'lost/L.HEIC' <<<"$(mac_list_new /dev/stdout)"
LOGGED=""; mac_retry_given_up
check "--retry-given-up clears the budget" test "$(mac_given_up | mac_count)" = 0
check "and says how many" grep -q '1 file(s) given up' <<<"$LOGGED"
check "the file is a candidate again" grep -qx 'lost/L.HEIC' <<<"$(mac_list_new /dev/stdout)"

echo "online-only files"
# A real dataless placeholder cannot be made in a scratch directory, so the FLAG
# is stubbed and the READ is real, against a FIFO standing in for the stub: a
# reader blocks in open() on a FIFO that nobody writes, which is the stuck
# provider exactly, and a FIFO whose writer serves the bytes, swaps a regular
# file in and clears the flag BEFORE closing is a provider that materialises a
# file when it is read -- measured on Drive's stream mode 2026-09-26, where
# every staged file was such a stub and none was ever handed over.
DATALESS="$T/dataless.list"; : > "$DATALESS"
is_dataless() { grep -qxF "$1" "$DATALESS" 2>/dev/null; }
SERVERS=""
mkdir -p "$STAGING/hyd"
serves() {  # <rel>: a stub that materialises when it is read
  local p="$STAGING/$1"
  mkfifo "$p"; printf '%s\n' "$p" >> "$DATALESS"; printf 'bytes of %s' "$1" > "$p.real"
  ( exec 3>"$p"; cat "$p.real" >&3; mv -f "$p.real" "$p"
    grep -vxF "$p" "$DATALESS" > "$DATALESS.t"; mv -f "$DATALESS.t" "$DATALESS"; exec 3>&- ) &
  SERVERS="$SERVERS $!"
}
stuck() { mkfifo "$STAGING/$1"; printf '%s\n' "$STAGING/$1" >> "$DATALESS"; }   # never served
stays() { printf 'x' > "$STAGING/$1"; printf '%s\n' "$STAGING/$1" >> "$DATALESS"; }  # read, still a stub
KEEP_PUSH_CAP="$PUSH_CAP"

serves hyd/A.JPG; stuck hyd/B.JPG; stays hyd/C.JPG; serves hyd/D.JPG
printf 'hyd/A.JPG\nhyd/B.JPG\nhyd/C.JPG\nhyd/D.JPG\n' > "$T/hyd.list"
# shellcheck disable=SC2034  # read by lib/mac.sh
MAC_HYDRATE_TIMEOUT=1 MAC_HYDRATE_BUDGET=30
LOGGED=""; MAC_HANDED=0
t0=$SECONDS; mac_handoff "$T/hyd.list"; took=$((SECONDS - t0))
check "a stub that materialises when read is handed over" test "$(row hyd/A.JPG 3)/$(row hyd/D.JPG 3)" = "queued/queued"
check "with its bytes" test "$(cat "$MAC_INBOX/hyd_A.JPG" 2>/dev/null)" = "bytes of hyd/A.JPG"
check "a stub still blocked at the bound is not handed over" test -z "$(row hyd/B.JPG 3)"
check "nor is one still dataless after a full read" test -z "$(row hyd/C.JPG 3)"
check "the log counts both apart" grep -q 'handed to Google Photos 2 .*hydrated 2, evicted-skipped 2' <<<"$LOGGED"
check "and says why each was left" grep -q '1 still blocked after the 1s per-file bound, 1 still online-only after a full read, 0 unreadable, 0 not tried' <<<"$LOGGED"
check "a timed-out file is named" grep -q 'still online-only after 1s of reading, left for the next run: hyd/B.JPG' <<<"$LOGGED"
check "the blocked read was killed, not left to hang" none pgrep -f "cat -- $STAGING/hyd/B.JPG"
check "the run was bounded by the per-file timeout" test "$took" -le 4

serves hyd/E.JPG; serves hyd/F.JPG
printf 'hyd/E.JPG\nhyd/F.JPG\n' > "$T/hyd.list"
LOGGED=""; MAC_HANDED=0; PUSH_CAP=1
mac_handoff "$T/hyd.list"
check "hydration stops at the cap: the first is handed over" test "$(row hyd/E.JPG 3)" = queued -a "$MAC_HANDED" = 1
check "and the next one is never read" grep -qxF "$STAGING/hyd/F.JPG" "$DATALESS"
PUSH_CAP="$KEEP_PUSH_CAP"

stuck hyd/G.JPG; stuck hyd/H.JPG
printf 'hyd/G.JPG\nhyd/H.JPG\nhyd/F.JPG\n' > "$T/hyd.list"
# shellcheck disable=SC2034  # read by lib/mac.sh
MAC_HYDRATE_BUDGET=1
LOGGED=""; MAC_HANDED=0
mac_handoff "$T/hyd.list"
check "once the run's hydration budget is spent nothing else is read" grep -qxF "$STAGING/hyd/F.JPG" "$DATALESS"
# SECONDS is whole seconds, so a one-second budget may already read as spent
# before the first file: G is tried or not, but nothing after it ever is.
check "and the untried ones are counted as such" grep -qE '(1 still blocked after the 1s per-file bound, 0 still online-only after a full read, 0 unreadable, 2|0 still blocked after the 1s per-file bound, 0 still online-only after a full read, 0 unreadable, 3) not tried' <<<"$LOGGED"

# shellcheck disable=SC2034  # read by lib/mac.sh
MAC_HYDRATE_BUDGET=30 MAC_HYDRATE_TIMEOUT=0
LOGGED=""; MAC_HANDED=0
printf 'hyd/F.JPG\n' > "$T/hyd.list"; mac_handoff "$T/hyd.list"
check "MAC_HYDRATE_TIMEOUT=0 turns hydration off: the stub is skipped unread" grep -qxF "$STAGING/hyd/F.JPG" "$DATALESS"
check "and is counted as not tried, not as a timeout" grep -q '0 still blocked .*, 1 not tried' <<<"$LOGGED"

# A human's "08" is octal to $(( )), which aborted the handoff before 10#.
# shellcheck disable=SC2034  # read by lib/mac.sh
MAC_HYDRATE_TIMEOUT=08 MAC_HYDRATE_BUDGET=030
LOGGED=""; MAC_HANDED=0
printf 'hyd/F.JPG\n' > "$T/hyd.list"; mac_handoff "$T/hyd.list"
check "a zero-padded bound is decimal, and the stub is fetched" test "$(row hyd/F.JPG 3)" = queued

printf 'x' > "$STAGING/hyd/U.JPG"; chmod 000 "$STAGING/hyd/U.JPG"; printf '%s\n' "$STAGING/hyd/U.JPG" >> "$DATALESS"
LOGGED=""; MAC_HANDED=0
printf 'hyd/U.JPG\n' > "$T/hyd.list"; mac_handoff "$T/hyd.list"
check "a read that fails is counted apart from a stub that stays one" grep -q '0 still online-only after a full read, 1 unreadable' <<<"$LOGGED"
chmod 600 "$STAGING/hyd/U.JPG"
# EACCES is ONE file's modes, not the process: treated as run-wide, a single
# chmod-000 file first in the list would block every read on every run, and
# the menu would say "cannot read cloud files" for ever.
check "a file-mode refusal is that file's, not the run's" test "$(cut -f2 "$MAC_ACCESS")" = ok
printf 'x' > "$STAGING/hyd/U2.JPG"; chmod 000 "$STAGING/hyd/U2.JPG"; printf '%s\n' "$STAGING/hyd/U2.JPG" >> "$DATALESS"
serves hyd/V.JPG
LOGGED=""; MAC_HANDED=0
printf 'hyd/U2.JPG\nhyd/V.JPG\n' > "$T/hyd.list"; mac_handoff "$T/hyd.list"
check "so the files after it are still read and handed over" test "$(row hyd/V.JPG 3)" = queued
chmod 600 "$STAGING/hyd/U2.JPG"

echo "online-only files this process may not read"
# Measured 2026-09-26 on Caraxes: the launchd-run sync (Photo Sync.app --sync,
# no Full Disk Access) had every read of the Drive staging tree refused, logged
# "2667 unreadable, 1703 not tried (the 600s hydration budget was spent)" and
# handed over nothing -- the refusals were fast, and there were enough of them
# to spend the whole budget. The READER is stubbed to fail the way TCC does.
READS="$T/reads"; : > "$READS"
hydrate_read() { printf '%s\n' "$1" >> "$READS"; printf 'cat: %s: Operation not permitted\n' "$1" >&2; return 1; }
for x in P1 P2 P3; do printf 'x' > "$STAGING/hyd/$x.JPG"; printf '%s\n' "$STAGING/hyd/$x.JPG" >> "$DATALESS"; done
# shellcheck disable=SC2034  # read by lib/mac.sh
MAC_HYDRATE_TIMEOUT=5 MAC_HYDRATE_BUDGET=30
LOGGED=""; MAC_HANDED=0
printf 'hyd/P1.JPG\nhyd/P2.JPG\nhyd/P3.JPG\n' > "$T/hyd.list"
mac_handoff "$T/hyd.list"
check "the first refusal stops hydration for the run: one read, not three" test "$(grep -c . "$READS")" = 1
check "nothing is handed over" test "$MAC_HANDED" = 0 -a -z "$(row hyd/P2.JPG 3)"
check "one line names the refusal and who needs the grant" \
  test "$(grep -c 'online-only files cannot be read: Operation not permitted -- Full Disk Access is needed by whatever runs this sync (Photo Sync.app)' <<<"$LOGGED")" = 1
check "the counts keep their meanings, and the refused ones are their own" \
  grep -q '0 still online-only after a full read, 1 unreadable, 0 not tried (.*), 2 not read because reading was refused' <<<"$LOGGED"
check "the staging-access line says denied, with macOS's words" \
  test "$(cut -f2,3 "$MAC_ACCESS")" = "denied$(printf '\t')Operation not permitted"
# shellcheck disable=SC1091
. "$HERE/../lib/fs.sh"   # the real reader back, which brings the real flag test too
is_dataless() { grep -qxF "$1" "$DATALESS" 2>/dev/null; }
serves hyd/Q.JPG
LOGGED=""; MAC_HANDED=0
printf 'hyd/Q.JPG\n' > "$T/hyd.list"; mac_handoff "$T/hyd.list"
check "a run whose reads are allowed again says ok" \
  test "$(row hyd/Q.JPG 3)/$(cut -f2 "$MAC_ACCESS")" = "queued/ok"
check "and logs no refusal" none grep -q 'reading was refused\|cannot be read' <<<"$LOGGED"
before="$(cat "$MAC_ACCESS")"
printf 'hyd/P1.JPG\n' > "$T/hyd.list"; sed -i '' "\|$STAGING/hyd/P1.JPG|d" "$DATALESS"
LOGGED=""; MAC_HANDED=0; mac_handoff "$T/hyd.list"
check "a run that reads no stub leaves the line alone (it observed nothing)" test "$(cat "$MAC_ACCESS")" = "$before"
# shellcheck disable=SC2086  # a list of pids
{ kill $SERVERS; wait $SERVERS; } 2>/dev/null

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
