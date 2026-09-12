# The command line of bin/avd-photos-reclaim.py is an interface both syncs
# build: the macOS one in bash, the Windows one in PowerShell. --help needs no
# icloudpd (the script imports it inside main(), after parsing its arguments),
# so this runs on any machine with a Python.
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "bin" / "avd-photos-reclaim.py"


def run(*args):
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)


def test_accepts_every_flag_the_syncs_pass():
    r = run("--help")
    assert r.returncode == 0, r.stderr
    for flag in ("--username", "--staging", "--pending", "--out", "--keep-days", "--dry-run", "--cookie-dir"):
        assert flag in r.stdout, flag


def test_refuses_a_call_without_its_required_flags():
    r = run()
    assert r.returncode == 2
    assert "--username" in r.stderr
