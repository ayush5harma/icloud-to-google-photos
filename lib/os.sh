#!/usr/bin/env bash
# The ONE place the operating systems differ. Sourced by config.sh (so every
# script has it) before anything else runs. Every other file calls the ap_*
# helpers below and never asks which OS it is on for a stat, a hash, a date or a
# process lookup.
#
# macOS is the platform this pipeline was built on and its branches are the
# original code, moved here verbatim. Windows runs the SAME scripts under Git for
# Windows' bash (MSYS2), and three things about that environment decide most of
# what follows:
#
#   PATH CONVERSION. MSYS rewrites any argument that looks like a POSIX path
#   when it hands it to a native Windows program, so `adb push f /sdcard/x`
#   reaches adb.exe as `adb push f C:/Program Files/Git/sdcard/x` and the push
#   lands nowhere, with no error. The device's own path prefixes are therefore
#   excluded from conversion (MSYS2_ARG_CONV_EXCL, below). Host paths still
#   convert, which is what mktemp's /tmp/... and readlink's /d/... need.
#
#   ENVIRONMENT VARIABLES ARE NOT CONVERTED. ANDROID_HOME=/c/sdk reaches the
#   emulator as the literal string "/c/sdk". So every path this pipeline owns is
#   held in MIXED form (C:/Users/me/...): bash, cygwin's stat and every native
#   program all read it, and it survives an environment variable unchanged. HOME
#   is normalised to that form first, so every default derived from it is too.
#
#   A PATH ENTRY CANNOT BE MIXED FORM. "C:/x" in a colon-separated PATH is two
#   entries, "C" and "/x"; ap_seed_path converts its arguments back to /c/x.

case "$(uname -s 2>/dev/null)" in
  Darwin) AP_OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) AP_OS=windows ;;
  *) AP_OS=linux ;;
esac

if [ "$AP_OS" = windows ]; then
  HOME="$(cygpath -m "$HOME")"; export HOME
  # Every prefix an emulator path can start with. A prefix list, not
  # MSYS_NO_PATHCONV=1: switching conversion off entirely would also stop it for
  # mktemp's /tmp/... and for the scripts' own /d/... paths, which DO need it.
  export MSYS2_ARG_CONV_EXCL="/sdcard;/data;/storage;/system;/product;/vendor;/debug_ramdisk;/metadata;/dev/block;/proc;/apex;/mnt;/sys"
  # uv resolves --python against every interpreter it can find, including a
  # half-installed Microsoft Store one; only its own managed builds are the same
  # on every machine.
  export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-only-managed}"
fi

# ap_mixed <path>: the form every pipeline-owned path is held in (see above).
# The identity everywhere but Windows.
ap_mixed() {
  if [ "$AP_OS" = windows ] && [ -n "$1" ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

# ap_posix <path>: the form a PATH entry needs. The identity everywhere but Windows.
ap_posix() {
  if [ "$AP_OS" = windows ] && [ -n "$1" ]; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}

# ── Files ────────────────────────────────────────────────────────────────────
# NOTE the absolute /usr/bin/stat on macOS: with GNU coreutils ahead of /usr/bin
# on PATH, GNU stat's `-f` means `--file-system`, so %z/%m there print a
# filesystem report instead and every numeric test silently no-ops. Everywhere
# else the stat on PATH IS GNU stat (Git for Windows ships it).

# ap_fsize <file>: size in bytes, 0 when it does not exist.
ap_fsize() {
  case "$AP_OS" in
    macos) /usr/bin/stat -f %z "$1" 2>/dev/null || echo 0 ;;
    *)     stat -c %s "$1" 2>/dev/null || echo 0 ;;
  esac
}

# ap_mtime <file>: modification time, Unix seconds; empty when it does not exist.
ap_mtime() {
  case "$AP_OS" in
    macos) /usr/bin/stat -f %m "$1" 2>/dev/null ;;
    *)     stat -c %Y "$1" 2>/dev/null ;;
  esac
}

# ap_stat_fsb <file>: "<flags> <size> <blocks>", the three fields lib/fs.sh
# decides "has local bytes" from. Only macOS has file flags (`dataless`); the
# others print "-", and the allocated-blocks test does the work: a Windows cloud
# placeholder (OneDrive, Google Drive in stream mode) reports its full size with
# no allocation, exactly like a macOS stub whose flag was missed.
ap_stat_fsb() {
  case "$AP_OS" in
    macos) /usr/bin/stat -f '%Sf %z %b' "$1" 2>/dev/null ;;
    *)     stat -c '- %s %b' "$1" 2>/dev/null ;;
  esac
}

# ap_sha256 <file>: the hex digest alone, empty on failure.
ap_sha256() {
  case "$AP_OS" in
    macos) /usr/bin/shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' ;;
    *)     sha256sum "$1" 2>/dev/null | awk '{print $1}' ;;
  esac
}

# ap_epoch_of "YYYY-MM-DD HH:MM:SS": that local time as Unix seconds, or empty.
ap_epoch_of() {
  case "$AP_OS" in
    macos) date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null ;;
    *)     date -d "$1" +%s 2>/dev/null ;;
  esac
}

# ── Host facts, for defaults ─────────────────────────────────────────────────

# ap_host_abi: the emulator ABI this host can run with hardware acceleration.
# Apple silicon and ARM64 Windows run arm64-v8a; an x86_64 host runs x86_64 --
# an arm64 image there has no accelerator at all, and a Zygisk module's arm64
# library cannot load into an x86_64 zygote. (Under x64 emulation on ARM64
# Windows, PROCESSOR_ARCHITECTURE says AMD64 and the W6432 twin says ARM64.)
ap_host_abi() {
  case "$AP_OS" in
    macos) echo arm64-v8a ;;
    windows)
      case "${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-}}" in
        ARM64) echo arm64-v8a ;;
        *) echo x86_64 ;;
      esac ;;
    *)
      case "$(uname -m 2>/dev/null)" in
        aarch64|arm64) echo arm64-v8a ;;
        *) echo x86_64 ;;
      esac ;;
  esac
}

# ap_host_mem_mb: physical memory in MB, 0 when unknown. /proc/meminfo is
# provided by the MSYS runtime on Windows as well as by Linux.
ap_host_mem_mb() {
  awk '/^MemTotal:/ { printf "%d\n", $2 / 1024; found=1 } END { if (!found) print 0 }' /proc/meminfo 2>/dev/null || echo 0
}

# ── Windows-only helpers ─────────────────────────────────────────────────────

# ap_ps <script>: run a PowerShell snippet, quietly, and print its output. For
# the two jobs bash cannot do on Windows: reading another process's command line
# and stopping a native process. ~0.5 s per call, so nothing calls it in a tight
# loop without a cheap test first (see ap_emu_pids in proc.sh).
#
# -EncodedCommand, never -Command: the script travels as base64 UTF-16, so no
# quote in it meets MSYS's argument quoting or PowerShell 5.1's own re-parsing
# of the command line (which disagree about \" ). Values go in through the
# environment, never spliced into the script text.
ap_ps() {
  local _enc
  _enc="$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$_enc" 2>/dev/null | tr -d '\r'
}

# ap_spawn_detached <log> <program> [args...]: start <program> in the
# background, stdout and stderr APPENDED to <log>, so that it outlives this shell
# and whatever terminal it runs in. For the emulator: `avd-start` exists to leave
# it running.
#
# macOS: nohup, as it always was. Windows: nohup is not enough -- a native
# program started from bash shares bash's CONSOLE, and closing the terminal
# window sends every process on that console CTRL_CLOSE_EVENT, emulator
# included. So it is started through lib/spawn-detached.sh by a bash that .NET
# creates with CREATE_NO_WINDOW: a console of its own that nothing can close,
# and bash's `>>` keeps the one appended log (see that file for why not cmd's).
# Arguments must not contain `"`; every caller passes flags, names and numbers.
AP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ap_spawn_detached() {
  local _log="$1"; shift
  if [ "$AP_OS" != windows ]; then
    nohup "$@" >>"$_log" 2>&1 &
    return 0
  fi
  local _cl _a _enc
  _cl="\"$(cygpath -m "$AP_LIB_DIR/spawn-detached.sh")\" \"$(ap_mixed "$_log")\""
  for _a in "$@"; do _cl="$_cl \"$_a\""; done
  _enc="$(cat <<'PS' | iconv -f UTF-8 -t UTF-16LE | base64 -w0
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $env:AP_SPAWN_EXE
$psi.Arguments = $env:AP_SPAWN_ARGS
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
[void][System.Diagnostics.Process]::Start($psi)
PS
)"
  # NOT through ap_ps: the child inherits PowerShell's standard handles, and
  # ap_ps's stdout is a pipe into `tr` -- which then waits for EOF until the
  # EMULATOR exits, so this "background" launch blocked boot_emulator for the
  # VM's whole life (measured). With PowerShell's handles on NUL, the child's
  # are too, and this returns in about a second.
  AP_SPAWN_EXE="$(cygpath -w /usr/bin/bash.exe)" AP_SPAWN_ARGS="$_cl" \
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$_enc" </dev/null >/dev/null 2>&1
}

# ap_winpid_alive <pid> [image]: is Windows process <pid> alive (and, when given,
# running <image>)? For locks written by a bash from a DIFFERENT Git
# installation, whose MSYS pids this one cannot see.
ap_winpid_alive() {
  local _q="PID eq $1"
  [ -n "${2:-}" ] || { tasklist.exe //NH //FO CSV //FI "$_q" 2>/dev/null | grep -q "\"$1\""; return; }
  tasklist.exe //NH //FO CSV //FI "$_q" //FI "IMAGENAME eq $2" 2>/dev/null | grep -q "\"$1\""
}
