#!/usr/bin/env bash
# Shared log-file rotation + append helpers. Every script here owns exactly one
# log under $LOG_DIR, rotates it at 5 MB and writes every line there itself, so
# the launchd agents can send stdout to /dev/null and keep only StandardErrorPath
# (where the things a script cannot log about itself land: a missing binary, a
# crash before logging is set up). Source via:
#   . "$LIB_DIR/log.sh"
#
# A script whose log() ALSO echoes to stdout (for a human running it by hand),
# tees, or uses a different timestamp format keeps its own log() and calls
# log_init from inside it, so the mkdir+rotate mechanics stay identical.

# log_init <file> [max_bytes]: create <file>'s parent directory and rotate it to
# "<file>.1" (clobbering any previous .1) if it is already past max_bytes
# (default 5 MiB = 5242880). Does NOT set any global variable -- callers that
# keep their message in $LOG still assign it themselves, so a script rotating a
# SECOND, differently-named log can call this without disturbing its primary.
log_init() {
  local _file="$1"
  local _max="${2:-5242880}"
  mkdir -p "$(dirname "$_file")" 2>/dev/null
  if [ -f "$_file" ] && [ "$(/usr/bin/stat -f %z "$_file" 2>/dev/null || echo 0)" -gt "$_max" ]; then
    mv -f "$_file" "$_file.1"
  fi
}

# log <message>: append a timestamped line to $LOG. File only -- no stdout echo.
# "YYYY-MM-DD HH:MM:SS <message>". Callers set $LOG themselves (log_init does
# not), typically right before calling log_init.
log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}
