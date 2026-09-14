#!/usr/bin/env bash
# The other half of ap_spawn_detached on Windows (lib/os.sh): run "$@" with its
# stdout and stderr APPENDED to the log named in $1. Started through .NET with
# CREATE_NO_WINDOW, so it has a console of its own that closing a terminal
# cannot reach.
#
# Why bash and not cmd.exe's `>>`: cmd opens the file for exclusive write, so a
# second launch appending to the same emulator.log while the first launcher is
# still exiting fails with "being used by another process" -- and the second
# emulator (the Play Store donor, after an `emu kill`) silently never starts.
# Cygwin opens it shared.
log="$1"; shift
exec "$@" >>"$log" 2>&1
