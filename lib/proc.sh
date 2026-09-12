#!/usr/bin/env bash
# Shared process-timing and device-command helpers. Source via:
#   . "$LIB_DIR/proc.sh"

# run_bounded <secs> <cmd> [args...]: wall-clock bound for any command. macOS
# ships no timeout(1), and an unattended launchd job that blocks on a wedged
# host command (sdkmanager, curl, adb) never runs again until someone notices.
# Returns the command's own exit status, or 124 if it had to be killed.
# STDOUT GOES TO /dev/null -- never use this where output is wanted; that is
# what dev_capture below is for.
run_bounded() {
  local secs="$1"; shift
  "$@" >/dev/null 2>&1 & local pid=$!
  local n=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$secs" ]; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    sleep 1; n=$((n+1))
  done
  wait "$pid"
}

# stamp_age <file>: seconds since <file>'s mtime, or a very large number (the
# epoch, in effect) when it does not exist -- callers compare this against a
# staleness threshold without a separate existence check.
stamp_age() {
  printf '%s\n' "$(( $(date +%s) - $(/usr/bin/stat -f %m "$1" 2>/dev/null || echo 0) ))"
}

# dev_capture <serial> <timeout-secs> <poll-secs> <stderr-mode> <cmd> [args...]:
# an `adb -s <serial> shell` call bounded on wall clock, with its stdout captured
# and printed and its REAL exit status returned (124 if it had to be killed).
# run_bounded cannot stand in: it sends stdout to /dev/null, and using it where a
# capture was meant is what left the device-id ledger entry unwritten through
# seven armed runs (measured 2026-09-06) -- the sync then never noticed a
# recreated emulator.
# <poll-secs> empty = 1 s; a device call made tens of times per run passes 0.1,
# so the poll floor is not most of the runtime.
# <stderr-mode> "merge" folds the device's stderr into the captured output (the
# setup script shows it: the on-device ramdisk patch reports its failures there);
# anything else, empty included, discards it.
dev_capture() {
  local _ser="$1" _secs="$2" _poll="${3:-1}" _err="${4:-}"; shift 4
  local _out _pid _rc _n=0 _max
  _out="$(mktemp)"
  _max="$(awk -v s="$_secs" -v p="$_poll" 'BEGIN { printf "%d", (p > 0 ? s / p : s) }')"
  # stdin from /dev/null: `adb shell` forwards its stdin to the device, and a
  # caller inside `while read ... done < list` lost the rest of its list to it
  # (2026-09-07: a push loop stopped after one file).
  if [ "$_err" = merge ]; then
    ( adb -s "$_ser" shell "$@" >"$_out" 2>&1 </dev/null ) & _pid=$!
  else
    ( adb -s "$_ser" shell "$@" >"$_out" 2>/dev/null </dev/null ) & _pid=$!
  fi
  while kill -0 "$_pid" 2>/dev/null; do
    if [ "$_n" -ge "$_max" ]; then
      kill -9 "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null
      cat "$_out"; rm -f "$_out"; return 124
    fi
    sleep "$_poll"; _n=$((_n+1))
  done
  wait "$_pid"; _rc=$?
  cat "$_out"; rm -f "$_out"
  return "$_rc"
}

# single_flight_lock <dir> [notice-fn]: take <dir> as a lock (mkdir is the
# portable atomic test-and-set -- macOS has no flock) and record this pid in
# <dir>/pid. A launchd job whose calendar firings missed during sleep all land on
# one wake can otherwise run twice over the same tree.
# 0 = held. 1 = another run owns it and is alive, its pid in $SFL_PID (the caller
# decides whether that is a skip or an error). 2 = the lock could not be taken at
# all. A lock whose pid is gone is reclaimed rather than left to block every later
# run; <notice-fn> is called with one line when that happens.
single_flight_lock() {
  local _dir="$1" _notice="${2:-}"
  SFL_PID=""
  if mkdir "$_dir" 2>/dev/null; then printf '%s\n' "$$" > "$_dir/pid"; return 0; fi
  SFL_PID="$(cat "$_dir/pid" 2>/dev/null || true)"
  if [ -n "$SFL_PID" ] && kill -0 "$SFL_PID" 2>/dev/null; then return 1; fi
  [ -n "$_notice" ] && "$_notice" "reclaiming a stale lock (pid ${SFL_PID:-?} is gone)"
  rm -rf "$_dir"
  mkdir "$_dir" 2>/dev/null || return 2
  printf '%s\n' "$$" > "$_dir/pid"
  return 0
}
