#!/usr/bin/env bash
# Shared dataless/evicted-file guard. Source via:
#   . "$LIB_DIR/fs.sh"
#
# iCloud and Google Drive ("Optimize Mac Storage" / "Stream files") can evict any
# synced file to a dataless stub, and READING one is not safe: there is no
# timeout, so a stub the provider cannot currently serve blocks forever (measured
# 2026-08-25: `head -c 1` on a 1.95 GB evicted file, 0 bytes on disk, zero
# progress, no error). Detection must therefore be METADATA ONLY.
#
# Semantics, decided once here:
#   - the `dataless` flag (BSD stat's %Sf) means NO local bytes, full stop.
#   - a ZERO-byte file HAS its bytes trivially -- nothing to fault in -- so it is
#     never "dataless" even though its allocated-blocks count is also 0. A caller
#     that needs "non-empty", not just "has bytes", checks the size itself.
#   - otherwise, allocated blocks (%b) decide: >0 is present, 0 is a stub the
#     flag check alone can miss.
#
# NOTE the absolute /usr/bin/stat: with GNU coreutils ahead of /usr/bin on PATH,
# GNU stat's `-f` means `--file-system`, so %z/%b/%Sf there print a filesystem
# report instead of size/blocks/flags and every numeric test below would silently
# no-op. BSD stat is the one with %z/%b/%Sf.

# has_local_bytes_fields <flags> <size> <blocks>: the pure decision, no I/O --
# split out so a caller that already has these three fields from a BATCHED stat
# (one `xargs stat` over a whole tree rather than one process per file) can reuse
# the exact same rule without a second stat per file.
has_local_bytes_fields() {
  local flags=$1 size=$2 blocks=$3
  case "$flags" in *dataless*) return 1 ;; esac
  [ "$size" -eq 0 ] 2>/dev/null && return 0
  [ "$blocks" -gt 0 ] 2>/dev/null
}

# has_local_bytes <path>: metadata only, never a read.
has_local_bytes() {
  local f=$1
  [ -f "$f" ] || return 1
  has_local_bytes_fields \
    "$(/usr/bin/stat -f %Sf "$f" 2>/dev/null || echo "")" \
    "$(/usr/bin/stat -f %z "$f" 2>/dev/null || echo 0)" \
    "$(/usr/bin/stat -f %b "$f" 2>/dev/null || echo 0)"
}

# is_dataless <path>: the flag alone, metadata only. The handoff's question is
# narrower than has_local_bytes's: not "are the bytes here" but "would reading
# this fault them in from the provider".
is_dataless() {
  case "$(/usr/bin/stat -f %Sf "$1" 2>/dev/null)" in *dataless*) return 0 ;; esac
  return 1
}

# hydrate_bounded <path> <secs>: THE ONE SANCTIONED READ OF A STUB. Reads the
# file whole to /dev/null so the provider materialises it, bounded on wall
# clock, then asks the flag again. A stub is not always stuck: on Drive's stream
# mode every staged file becomes one once Drive has uploaded it (measured
# 2026-09-26: all 4,371 staged files dataless; a 68 KB one came back in 1.97 s
# under a bounded read with its flag cleared, and a full cat after that took
# 5 ms). Skipping them all on the metadata check alone handed nothing to Google
# Photos for hours.
#   0    the read finished and the file is no longer dataless
#   1    the read finished and the file is still a stub
#   2    the read itself failed (an I/O error, a file gone mid-run, or macOS
#        refusing this process); HYDRATE_ERR then holds the reader's reason,
#        its errno text ("Operation not permitted" is TCC), for the caller
#   124  the read was still going at <secs> and was killed
# Polls every 0.1 s, because most reads take a second or two; the bound is
# checked against SECONDS as well, so the fork of each sleep cannot stretch it
# past <secs> + 1. After the kill it waits at most a second for the reader to
# go: a read blocked in the kernel may not die on SIGKILL, and a plain `wait`
# would then hang exactly the way the bound exists to prevent. That reap sits in
# a stderr-silenced group, or bash prints its "Killed: 9" job notice at the next
# command.
# The read itself, its own function so a test can make it fail the way TCC does.
# `exec`, so the background job IS the reader: the kill below must reach the
# process blocked in the read, not a subshell that would leave it behind.
hydrate_read() { exec /bin/cat -- "$1"; }

# HYDRATE_ERRF: a file the caller owns for the reader's stderr, reused by every
# read (mac_handoff sets one per handoff); unset, each read makes and removes
# its own.
HYDRATE_ERR="" HYDRATE_ERRF="${HYDRATE_ERRF:-}"
hydrate_bounded() {
  local f="$1" secs="$2" pid rc n=0 end errf="$HYDRATE_ERRF" own=0
  HYDRATE_ERR=""
  # 10#: a digits-only "08" is otherwise octal to $(( )) and aborts the caller.
  case "$secs" in ''|*[!0-9]*) secs=0 ;; *) secs=$((10#$secs)) ;; esac
  end=$((SECONDS + secs + 1))
  if [ -z "$errf" ]; then errf="$(mktemp)" && own=1 || errf=/dev/null; fi
  hydrate_read "$f" >/dev/null 2>"$errf" </dev/null & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge $((secs * 10)) ] || [ "$SECONDS" -ge "$end" ]; then
      kill -9 "$pid" 2>/dev/null
      { n=0; while kill -0 "$pid" && [ "$n" -lt 10 ]; do sleep 0.1; n=$((n + 1)); done
        kill -0 "$pid" || wait "$pid"; } 2>/dev/null
      [ "$own" -eq 1 ] && rm -f "$errf"
      return 124
    fi
    sleep 0.1; n=$((n + 1))
  done
  wait "$pid"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # "cat: <path>: Operation not permitted" -> the errno text alone, which
    # carries no path into a log line or the status file.
    HYDRATE_ERR="$(head -1 "$errf" 2>/dev/null)"; HYDRATE_ERR="${HYDRATE_ERR##*: }"
    [ "$own" -eq 1 ] && rm -f "$errf"
    return 2
  fi
  [ "$own" -eq 1 ] && rm -f "$errf"
  is_dataless "$f" && return 1
  return 0
}
