#!/usr/bin/env python3
# The sqlite3 CLI of the Windows sync's verify step:
#
#   uv run --no-project -q --python 3.13 sqlite_query.py <db> <sql-file>
#
# WHY IT EXISTS: the verify step reads Google Photos' own database, and on
# macOS it does that with the sqlite3 CLI the OS ships. Windows ships none, and
# the macOS notes say not every emulator image does either (`su -c sqlite3`
# then fails to a silent empty string, and the verifier polled "0 done" for a
# whole UPLOAD_WAIT). So the database is copied to the host -- db, -wal and -shm
# together, in one su call -- and queried here, under the same uv-managed
# Python the iCloud reclaim already needs, so nothing new is installed.
#
# THE SQL COMES FROM A FILE, NEVER ARGV: the IN list for a 1,000-file batch is
# about 55,000 characters and a Windows command line stops at 32,767.
#
# Output is the CLI's default list mode, which is what the sync parses: one
# row per line, columns joined by '|', NULL as an empty string. Any SQLite
# error is exit 1 with the message on stderr and nothing on stdout, so a
# malformed copy (a db and a -wal captured seconds apart) reads as "not
# coherent" to the caller and never as a count of zero.
#
# The copy is opened read-write on purpose: it is the caller's own copy, and
# replaying the WAL may need to write the -shm. mode=rw also refuses a missing
# file instead of creating an empty database in its place.
import pathlib
import sqlite3
import sys


def cell(v) -> str:
    if v is None:
        return ""
    if isinstance(v, bytes):
        return v.decode("utf-8", errors="replace")
    if isinstance(v, float):
        s = "%.15g" % v
        return s if any(ch in s for ch in ".eEn") else s + ".0"
    return str(v)


def statements(sql: str):
    # Split on ';' but only where sqlite3 agrees a statement is complete, so a
    # ';' inside a quoted filename does not end one.
    buf = ""
    for piece in sql.split(";"):
        buf += piece + ";"
        if sqlite3.complete_statement(buf):
            if buf.strip(" \t\r\n;"):
                yield buf
            buf = ""
    if buf.strip(" \t\r\n;"):
        yield buf


def main(argv) -> int:
    # UTF-8 and LF whatever the console code page: the sync compares these
    # paths byte for byte with the device's, and PYTHONUTF8 may be unset when
    # a person runs this by hand.
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    if len(argv) != 3:
        print("usage: sqlite_query.py <db> <sql-file>", file=sys.stderr)
        return 2
    db, sql_file = argv[1], argv[2]
    try:
        sql = pathlib.Path(sql_file).read_text(encoding="utf-8")
    except OSError as e:
        print(f"cannot read {sql_file}: {e}", file=sys.stderr)
        return 1
    try:
        uri = pathlib.Path(db).resolve().as_uri() + "?mode=rw"
        conn = sqlite3.connect(uri, uri=True)
        try:
            out = []
            for stmt in statements(sql):
                for row in conn.execute(stmt):
                    out.append("|".join(cell(v) for v in row))
        finally:
            conn.close()
    except sqlite3.Error as e:
        print(f"sqlite error: {e}", file=sys.stderr)
        return 1
    # Only after every statement succeeded: a failure part-way prints nothing.
    for line in out:
        sys.stdout.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
