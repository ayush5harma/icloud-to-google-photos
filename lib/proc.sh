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
  local _m; _m="$(ap_mtime "$1")"
  printf '%s\n' "$(( $(date +%s) - ${_m:-0} ))"
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
      _dev_emit "$_out"; rm -f "$_out"; return 124
    fi
    sleep "$_poll"; _n=$((_n+1))
  done
  wait "$_pid"; _rc=$?
  _dev_emit "$_out"; rm -f "$_out"
  return "$_rc"
}

# adb.exe writes the device's output in TEXT mode on Windows: `adb shell echo
# ok` arrives as "ok\r\n" (measured), and every exact-match test on a device
# answer -- `grep -q '^ok$'` for the preinit device, a module, the sepolicy rule
# -- would silently read "no". So the one capture every device query goes
# through hands back LF only, as a Mac's adb does.
_dev_emit() {
  if [ "$AP_OS" = windows ]; then tr -d '\r' < "$1"; else cat "$1"; fi
}

# ap_avd_name_of <serial> [secs]: the name of the AVD running on <serial>, via
# adb's own `emu avd name` (which answers "<name>\nOK"). Bounded, because a
# half-dead emulator answers this console command by never answering at all.
ap_avd_name_of() {
  local _ser="$1" _secs="${2:-10}" _out _pid _n=0
  _out="$(mktemp)"
  ( adb -s "$_ser" emu avd name >"$_out" 2>/dev/null </dev/null ) & _pid=$!
  while kill -0 "$_pid" 2>/dev/null; do
    if [ "$_n" -ge "$_secs" ]; then kill -9 "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null; rm -f "$_out"; return 124; fi
    sleep 1; _n=$((_n+1))
  done
  wait "$_pid" 2>/dev/null
  head -1 "$_out" | tr -d '\r\n'
  rm -f "$_out"
}

# ap_emulator_serial <avd-name>: the adb serial whose running emulator IS
# <avd-name>, or nothing (rc 1).
#
# NEVER ASSUME emulator-5554. It is only the FIRST free console port, so any
# other emulator started earlier -- an app developer's, a CI job's, this
# pipeline's own throwaway donor VM -- owns it instead, and every `adb -s
# emulator-5554` in this project would then push photos into, query, prune from,
# or `emu kill` a device that has nothing to do with the pipeline. Ask each
# emulator its name and match.
ap_emulator_serial() {
  local _want="$1" _ser _name
  while read -r _ser _; do
    case "$_ser" in emulator-*) ;; *) continue ;; esac
    _name="$(ap_avd_name_of "$_ser")"
    if [ "$_name" = "$_want" ]; then printf '%s\n' "$_ser"; return 0; fi
  done < <(adb devices 2>/dev/null | tail -n +2)
  return 1
}

# ── The emulator PROCESS ─────────────────────────────────────────────────────
# "Is our VM running" is asked of the process table, not of adb: a booting or
# wedged emulator is not attached yet but is very much running, and starting a
# second copy of the same AVD is what that question exists to prevent.
#
# macOS: the VM is `qemu-system-aarch64 ... -avd <name> ...`, and pgrep -f sees
# the whole command line. Windows: the VM is qemu-system-x86_64[-headless].exe,
# started by an emulator.exe that waits on it, and a command line is only
# readable through CIM -- about half a second of PowerShell. So a tasklist pass
# answers the common case ("no emulator at all", ~0.1 s) and CIM is asked only
# when some emulator exists. The name is matched as the whole -avd argument, so
# gphotos-tablet never matches a gphotos-tablet2 or the Play Store donor VM.

# ap_emu_pids <avd-name>: the pid(s) of the emulator process(es) running
# <avd-name>, one per line; nothing when it is not running.
ap_emu_pids() {
  local _n="$1"
  if [ "$AP_OS" != windows ]; then pgrep -f "qemu-system.*$_n" 2>/dev/null; return 0; fi
  tasklist.exe //NH //FO CSV //FI "IMAGENAME eq qemu-system*" 2>/dev/null | grep -qi 'qemu-system' \
    || tasklist.exe //NH //FO CSV //FI "IMAGENAME eq emulator.exe" 2>/dev/null | grep -qi 'emulator.exe' \
    || return 0
  # The name travels in the environment and is escaped by PowerShell itself.
  # emulator.exe's command line quotes every argument ("-avd" "name"), QEMU's
  # does not (-avd name); both must match.
  AP_EMU_NAME="$_n" ap_ps "$(cat <<'PS'
$re = '(^|[\s"])-avd"?\s+"?' + [regex]::Escape($env:AP_EMU_NAME) + '"?(\s|$)'
Get-CimInstance Win32_Process -Filter "Name LIKE 'qemu-system%' OR Name = 'emulator.exe'" |
  Where-Object { $_.CommandLine -match $re } | ForEach-Object { $_.ProcessId }
PS
)"
}

ap_emu_running() { [ -n "$(ap_emu_pids "$1")" ]; }

# ap_emu_kill <avd-name>: hard-stop that emulator's processes. The LAST resort,
# after `adb emu kill` (which lets QEMU exit cleanly) has had its chance -- a hard
# stop discards unflushed writes, which is why nothing calls this after a Magisk
# module install (see reboot_wait in avd-photos-setup).
ap_emu_kill() {
  local _pids
  if [ "$AP_OS" != windows ]; then pkill -f "qemu-system.*$1" 2>/dev/null; return 0; fi
  _pids="$(ap_emu_pids "$1" | tr '\n' ',' | sed 's/,$//')"
  [ -n "$_pids" ] && ap_ps "Stop-Process -Force -ErrorAction SilentlyContinue -Id $_pids" >/dev/null
  return 0
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
  if mkdir "$_dir" 2>/dev/null; then ap_lock_write "$_dir"; return 0; fi
  SFL_PID="$(cat "$_dir/pid" 2>/dev/null || true)"
  if [ -n "$SFL_PID" ] && ap_lock_alive "$_dir"; then return 1; fi
  [ -n "$_notice" ] && "$_notice" "reclaiming a stale lock (pid ${SFL_PID:-?} is gone)"
  rm -rf "$_dir"
  mkdir "$_dir" 2>/dev/null || return 2
  ap_lock_write "$_dir"
  return 0
}

# ap_lock_write <dir> / ap_lock_alive <dir>: who holds a lock, and are they
# still running. On Windows the Windows pid is recorded as well: an MSYS pid is
# only visible to bashes from the SAME Git installation, and a run started from
# the user's own Git Bash beside the tray's copy would otherwise read the other's
# live lock as stale and reclaim it -- two setups racing on one ramdisk.img. The
# image name is checked too, so a reused Windows pid does not hold a lock forever.
ap_lock_write() {
  printf '%s\n' "$$" > "$1/pid"
  [ "$AP_OS" = windows ] && { tr -dc '0-9' < "/proc/$$/winpid" > "$1/winpid"; } 2>/dev/null
  return 0
}
ap_lock_alive() {
  local _p _w
  _p="$(tr -dc '0-9' < "$1/pid" 2>/dev/null)"
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && return 0
  [ "$AP_OS" = windows ] || return 1
  _w="$(tr -dc '0-9' < "$1/winpid" 2>/dev/null)"
  [ -n "$_w" ] && ap_winpid_alive "$_w" bash.exe
}
