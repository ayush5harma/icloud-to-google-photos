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
