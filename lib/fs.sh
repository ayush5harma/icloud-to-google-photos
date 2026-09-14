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
# The three fields come from ap_stat_fsb (lib/os.sh), which knows which stat
# this OS has -- on macOS the absolute BSD /usr/bin/stat, never a GNU one ahead
# of it on PATH. Windows has no `dataless` flag, and a cloud placeholder there
# (OneDrive, Google Drive streaming) is caught by the same zero-blocks rule.

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
  local f=$1 flags size blocks
  [ -f "$f" ] || return 1
  read -r flags size blocks <<<"$(ap_stat_fsb "$f")"
  has_local_bytes_fields "${flags:-}" "${size:-0}" "${blocks:-0}"
}
