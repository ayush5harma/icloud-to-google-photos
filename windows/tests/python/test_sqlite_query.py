# windows/lib/sqlite_query.py stands in for the sqlite3 CLI in the Windows
# sync's verify step, so it is held to what the sync relies on: the CLI's
# default list-mode output, exit 1 on any SQLite error (a malformed copy must
# read as "not coherent", never as zero rows), and a copy of a WAL-mode
# database that sees the rows still in the WAL only when the -wal and -shm
# travel with it -- which is why the sync copies all three in one su call.
import os
import pathlib
import shutil
import sqlite3
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HELPER = ROOT / "windows" / "lib" / "sqlite_query.py"


def run(db, sql, tmp_path, env_extra=None):
    q = tmp_path / "q.sql"
    q.write_text(sql + "\n", encoding="utf-8")
    env = dict(os.environ)
    env.update(env_extra or {})
    return subprocess.run([sys.executable, str(HELPER), str(db), str(q)],
                          capture_output=True, env=env)


def make_photos_db(path):
    c = sqlite3.connect(path)
    c.executescript(
        "create table local_media (filepath text, dedup_key text, in_camera_folder integer,"
        " has_upload_permanently_failed integer);"
        "create table remote_media (dedup_key text);"
    )
    c.commit()
    return c


def test_wal_rows_are_seen_only_when_the_wal_travels_with_the_db(tmp_path):
    dev = tmp_path / "device"
    dev.mkdir()
    src = dev / "gphotos0.db"
    c = make_photos_db(src)
    c.execute("pragma journal_mode=wal")
    c.execute("pragma wal_autocheckpoint=0")
    # The schema lands in the main file; the rows stay in the WAL, as they do
    # on a device where Photos writes continuously.
    c.execute("pragma wal_checkpoint(truncate)")
    c.executemany("insert into local_media values (?, ?, 1, 0)",
                  [(f"/storage/emulated/0/DCIM/Camera/{i}.HEIC", f"k{i}") for i in range(3)])
    c.commit()
    assert (dev / "gphotos0.db-wal").stat().st_size > 0

    together = tmp_path / "together"
    together.mkdir()
    for suffix in ("", "-wal", "-shm"):
        shutil.copy(dev / f"gphotos0.db{suffix}", together / f"photos.db{suffix}")
    alone = tmp_path / "alone"
    alone.mkdir()
    shutil.copy(src, alone / "photos.db")
    c.close()

    r = run(together / "photos.db", "select count(*) from local_media;", tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout == b"3\n"
    r = run(alone / "photos.db", "select count(*) from local_media;", tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout == b"0\n"


def test_prints_list_mode_rows_with_null_as_empty(tmp_path):
    db = tmp_path / "p.db"
    c = make_photos_db(db)
    c.executemany("insert into local_media values (?, ?, ?, ?)",
                  [("/a/1.jpg", "k1", 1, 0), ("/a/2.jpg", None, 1, None)])
    c.commit()
    c.close()
    r = run(db, "select filepath, dedup_key, in_camera_folder, has_upload_permanently_failed"
                " from local_media order by filepath;", tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout == b"/a/1.jpg|k1|1|0\n/a/2.jpg||1|\n"


def test_prints_nothing_for_no_rows_and_runs_every_statement(tmp_path):
    db = tmp_path / "p.db"
    make_photos_db(db).close()
    r = run(db, "select filepath from local_media;", tmp_path)
    assert r.returncode == 0 and r.stdout == b""
    r = run(db, "select 1; select 'a;b';", tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout == b"1\na;b\n"


def test_a_sqlite_error_is_exit_1_with_the_message_on_stderr(tmp_path):
    db = tmp_path / "p.db"
    make_photos_db(db).close()
    r = run(db, "select count(*) from no_such_table;", tmp_path)
    assert r.returncode == 1
    assert b"no_such_table" in r.stderr
    assert r.stdout == b""


def test_a_malformed_database_is_exit_1(tmp_path):
    db = tmp_path / "p.db"
    db.write_bytes(b"SQLite format 3\x00" + b"\xff" * 4096)
    r = run(db, "select count(*) from local_media;", tmp_path)
    assert r.returncode == 1


def test_a_missing_database_is_exit_1_and_is_not_created(tmp_path):
    db = tmp_path / "missing.db"
    r = run(db, "select 1;", tmp_path)
    assert r.returncode == 1
    assert not db.exists()


def test_a_1000_file_in_list_goes_through_the_file(tmp_path):
    db = tmp_path / "p.db"
    c = make_photos_db(db)
    names = [f"/storage/emulated/0/DCIM/Camera/2026_05_IMG_{i:04d} it''s.HEIC" for i in range(1000)]
    c.executemany("insert into local_media values (?, ?, 1, 0)",
                  [(n.replace("''", "'"), f"k{i}") for i, n in enumerate(names)])
    c.commit()
    c.close()
    inlist = ",".join(f"'{n}'" for n in names)
    sql = f"select count(distinct filepath) from local_media where in_camera_folder=1 and filepath in ({inlist});"
    assert len(sql) > 32767
    r = run(db, sql, tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout == b"1000\n"


def test_a_non_ascii_filepath_round_trips_under_utf8_mode(tmp_path):
    db = tmp_path / "p.db"
    c = make_photos_db(db)
    # Built from code points: the repository is ASCII only.
    name = "/storage/emulated/0/DCIM/Camera/2026_05_Caf" + chr(0xE9) + " " + chr(0x5199) + chr(0x771F) + ".HEIC"
    c.execute("insert into local_media values (?, 'k', 1, 0)", (name,))
    c.commit()
    c.close()
    sql = "select filepath from local_media where filepath in ('" + name + "');"
    r = run(db, sql, tmp_path, {"PYTHONUTF8": "1"})
    assert r.returncode == 0, r.stderr
    assert r.stdout.decode("utf-8") == name + "\n"
