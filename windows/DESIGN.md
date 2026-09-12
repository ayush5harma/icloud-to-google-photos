# Windows port: spec and plan

The same pipeline as the macOS one -- iCloud -> staging -> rooted Android
emulator -> Google Photos -> verified against Google Photos' own database ->
reclaimed from iCloud -- on Windows 11, installed by following the README and
nothing else. This file is the spec the port was built against, the decisions
and the reason for each, and what is and is not proven. It was written before
the code (2026-09-13) and is kept current with it.

## Goal and non-goals

Goal: a Windows 11 user with PowerShell 7, a JDK, Git, `uv` and hardware
virtualisation can clone this repository, run `windows\install.ps1`, do the
same four human steps the macOS README lists, arm it, and get the macOS
behaviour: a 15-minute sync, the weekly re-run that is the update, the login
bootstrap, and a tray icon that shows the same states as the menu-bar ring.

Non-goals:

- **No change to macOS behaviour.** The author's flake pins rev 97d1164. Nothing
  under `bin/`, `lib/`, `launchd/`, `Sources/`, `build.sh` or `install.sh`
  changes; the Windows tree only reads `bin/avd-photos-reclaim.py` (as-is) and
  the on-device patch script (copied, with a test that fails if the copies
  drift).
- No compile step for the Windows user, and no Windows-on-Arm support claim
  (the emulator there is untested; `AVD_ABI` can be set, nothing more).
- No new behaviour on either platform. Where Windows forces a difference it is
  listed below with the reason.

## What is shared, and how

| Piece | macOS | Windows |
| --- | --- | --- |
| iCloud reclaim | `bin/avd-photos-reclaim.py` | the same file, run the same way (`uv run --python 3.13 --with "icloudpd @ git+...@v<ver>"`) |
| On-device ramdisk patch | heredoc in `bin/avd-photos-setup` | `windows/device/patch-ramdisk.sh`, byte-identical (Pester drift test) |
| Config keys, defaults, precedence | `lib/config.sh` | `windows/lib/Core.ps1`; the key list is drift-tested against `AP_KEYS` |
| Ledgers and state files | `~/.cache/avd-photos/*` | `%LOCALAPPDATA%\avd-photos\*`, same names, same line format (staging-relative paths with `/`, so a ledger is portable) |
| Phase strings, status JSON | `avd-photos-sync`, `avd-photos-status` | same strings, same JSON fields and types |
| Arming | `~/.config/avd-photos/ENABLED` | `%APPDATA%\avd-photos\ENABLED` |
| Scheduling | five launchd agents | four scheduled tasks with the same labels (`com.ayushsharma.icloud-to-google-photos.<suffix>`) |
| Status UI | `Photo Sync.app` (Swift) | `avd-photos-tray.ps1` (WinForms `NotifyIcon`, no compile step) |

## Decisions, each with its reason

1. **PowerShell 7 for everything, WinForms for the tray.** pwsh 7 gives
   `ProcessStartInfo.ArgumentList`-correct quoting, `Kill(entireProcessTree)`,
   UTF-8 by default and the same language as the tests. The tray needs no
   compiled .NET app: `NotifyIcon`, `ContextMenuStrip` and `System.Drawing` are
   all reachable from PowerShell. Icons are built as in-memory `.ico` streams,
   never `Bitmap.GetHicon()`, because an HICON per frame leaks a GDI handle and
   the spinner draws eight frames a second (the 10,000-handle quota would go in
   about twenty minutes).

2. **x86_64 system images.** A Windows host runs `x86_64` images under WHPX or
   AEHD; `arm64-v8a` images do not boot on x86 hosts. `AVD_ABI` defaults to
   `x86_64` on Windows. The Magisk APK carries `lib/x86_64/`, so the on-device
   flow is unchanged apart from that directory name (the macOS script hardcodes
   `lib/arm64-v8a` in `magisk_complete_env`; the Windows port uses `$AVD_ABI`).

3. **The ramdisk is patched on the device, exactly as on macOS.** `magiskboot`
   has no Windows host build, and the macOS script never ran it on the host
   anyway: it pushes the Magisk APK and `ramdisk.img.backup` to
   `/data/local/tmp/magiskpatch`, runs the patch script there, and pulls
   `ramdiskpatched.img` back, stage-then-rename. The Windows port does the same
   with the same script. The script must reach the device with LF line endings
   (a CRLF `sh` script fails on its first line), so `.gitattributes` pins
   `windows/device/*.sh` to LF and the writer normalises again before a push.

4. **No `-selinux permissive`, no `-writable-system`.** The macOS setup uses
   neither: SELinux stays enforcing with one appended sepolicy rule for Zygisk's
   memfd, and modules reach `/system` through Magisk's magic mount, which needs
   no writable system image. The Windows port keeps that measured configuration
   rather than weakening it. Troubleshooting shows how to boot once with
   `-selinux permissive` by hand to rule SELinux in or out.

5. **icloudpd gets `--password-provider keyring` on Windows.** On macOS, a job
   with no saved session fails fast because `getpass()` falls back to stdin,
   which is `/dev/null`. On Windows `getpass()` reads the console through
   `msvcrt.getwch()` and ignores stdin (read in icloudpd v1.32.3,
   `icloudpd/base.py:ask_password_in_console`), so the same job would block
   forever holding the sync lock. With only the keyring provider, a missing
   session ends in `None of providers gave password` within seconds; the
   interactive login stores the password in Windows Credential Manager
   (icloudpd writes a console-entered password to every provider), so a
   session that expires can still re-authenticate unattended. Two-factor
   prompts use `input()`, which does read stdin, and stdin is an empty file.

6. **`PYTHONUTF8=1` for every Python child.** Without UTF-8 mode, Python on
   Windows writes redirected output and opens files in the ANSI code page, so
   icloudpd can die on `UnicodeEncodeError` logging a filename, and the reclaim
   script would read the UTF-8 pending list and write its `--out` list in
   cp1252 -- a non-ASCII path would then never match its ledger entry. UTF-8
   mode fixes both without touching the Python.

7. **Host-side SQLite through Python, SQL through a file.** Windows ships no
   `sqlite3`, and the macOS notes say the device has none either, so the Photos
   database is copied off the device (db, `-wal` and `-shm` in one `su` call,
   pulled together) and queried by `windows/lib/sqlite_query.py` under the same
   `uv`-managed Python the reclaim uses. The query goes in a file, never on the
   command line: the `IN (...)` list for a 1,000-file batch is about 55,000
   characters and a Windows command line stops at 32,767.

8. **Every process goes through one runner with file redirection.**
   `Invoke-AvdProcess` starts the child with stdout and stderr redirected to
   files, stdin from an empty file, a wall-clock bound, and a process-tree kill
   on expiry (exit 124, as `run_bounded`). Files, not pipes, because a
   grandchild that inherits a pipe (an adb server started on demand) keeps it
   open and a pipe reader then never sees end-of-file. `.bat` tools
   (`sdkmanager.bat`, `avdmanager.bat`) are run through `cmd.exe /d /s /c` with
   every argument quoted, since `cmd` splits unquoted arguments on `;` and `&`.

9. **Locks record the owner's start time as well as its pid.** Windows reuses
   pids quickly, so "is pid N alive" can be answered yes by a stranger and a
   stale `sync.lock` would then block every later run. The lock is still
   `sync.lock\pid` (the status reader and the docs name it); a `started` file
   beside it holds the owner's start time, and liveness needs both to match.
   The lock itself is taken with an exclusive create of the `pid` file, which
   is atomic on NTFS where PowerShell's `New-Item -ItemType Directory` is not.

10. **The config file is read, not sourced.** Same path semantics, same keys,
    same precedence (environment > file > default, decided by whether the
    caller SET a variable). `KEY=value` per line; the value is the rest of the
    line, quotes optional; backslashes are literal (`C:\Users\me` must not lose
    its separators the way an unquoted shell word would); `$NAME`, `${NAME}`
    and `%NAME%` expand except inside single quotes. One Windows limit is
    documented rather than worked around: cmd and PowerShell cannot easily
    create an empty environment variable, so "no floor for this run" is
    `KEEP_ICLOUD_DAYS=0`.

11. **Tasks run interactively, as the user, through a headless console.** The
    tasks use the Interactive logon type -- the launchd `gui/<uid>` domain's
    equivalent -- because an S4U or "whether logged on or not" task runs in
    session 0, where the user's Google Drive and iCloud Drive mounts, and the
    Credential Manager entry icloudpd needs, are not visible. They launch
    `conhost.exe --headless pwsh.exe ...` so a 15-minute job does not flash a
    console window. They allow battery start and do not stop on battery (the
    defaults would never sync a laptop on battery and would kill a run
    mid-push when it is unplugged), set no execution time limit (a first run
    against a real library is hours long), and ignore a new instance while one
    runs (launchd's behaviour; the script is single-flight as well).

12. **No app-bundle indirection.** On macOS the sync runs as a child of
    `Photo Sync.app` because TCC gates a cloud-provider mount per app. Windows
    has no per-app file-provider grant, so the task runs the script directly.
    The staging listing still fails loudly on access denied, as on macOS.

13. **Cloud placeholders are skipped, not read.** Files with
    `RECALL_ON_DATA_ACCESS` or `OFFLINE` set (Google Drive streaming, OneDrive
    Files On-Demand) are the Windows form of the macOS `dataless` stub:
    reading one hydrates it, which can block. They are counted as
    evicted-skipped and mirrored on a later run.

14. **Paths.** Config `%APPDATA%\avd-photos`, state `%LOCALAPPDATA%\avd-photos`,
    logs `%LOCALAPPDATA%\avd-photos\logs`, the pipeline's SDK root
    `%LOCALAPPDATA%\android-avd-sdk`, AVDs where the emulator looks
    (`ANDROID_AVD_HOME`, else `ANDROID_USER_HOME\avd`, else
    `%USERPROFILE%\.android\avd`), staging `%USERPROFILE%\Pictures\icloud-photos-staging`.
    The emulator mishandles non-ASCII characters in the AVD and SDK paths, so
    setup refuses such a path by name and says to set `ANDROID_AVD_HOME` and
    `AVD_SDK_ROOT` to an ASCII directory. `config.ini` on Windows writes
    `image.sysdir.1` with backslashes, so the API parser accepts both
    separators.

## Layout

```
windows/
  DESIGN.md              this file
  install.ps1            PATH entry, config, scheduled tasks, shortcuts; -Uninstall
  bin/                   the commands, same names as bin/ with .ps1 (thin wrappers)
  lib/AvdPhotos.psm1     module loader
  lib/Core.ps1           config, paths, logging, files, locks, processes, adb
  lib/Setup.ps1          the setup phases (port of bin/avd-photos-setup)
  lib/Sync.ps1           the sync and the reclaim step (port of bin/avd-photos-sync)
  lib/Status.ps1         the status JSON (port of bin/avd-photos-status)
  lib/Tray.ps1           the tray's pure model: states, menu, formatting, .ico writer
  lib/sqlite_query.py    host-side SQLite reader standing in for the sqlite3 CLI
  device/patch-ramdisk.sh  the on-device patch script, byte-identical to macOS
  tests/                 Pester suites, Python tests, Invoke-Checks.ps1
.gitattributes           LF for the device scripts on a Windows checkout
.github/workflows/windows.yml
```

The orchestration lives in module functions and the scripts in `bin/` only
parse arguments and call them, so the tests can drive a whole sync against a
fake device (every adb call goes through one mockable function) and a real
SQLite copy of the Photos tables.

## Plan (one commit or more per step, each leaving the checks green)

1. This spec, `.gitattributes`, the test scratch ignore.
2. Core module and its tests; `Invoke-Checks.ps1` (parse every `.ps1`,
   PSScriptAnalyzer, Pester); the CI workflow skeleton.
3. Setup port and device script (with the drift test).
4. Sync and status ports, the SQLite helper, the fake-device suite.
5. Tray model and tray host.
6. Installer, scheduled tasks, the small commands.
7. README: a Windows section mirroring Install, the one-time human steps,
   Monitoring, Uninstall and Troubleshooting, and a Windows column in the
   config and state contract.

## Verification criteria, decided before the code

Proven on this Mac (pwsh 7.6 from nixpkgs, scratch HOME inside the worktree,
no emulator, no real config):

- every `.ps1` parses; PSScriptAnalyzer reports no warning or error;
- Pester: config parsing and precedence, defaults per platform, paths and the
  AVD home, ledger read/write (LF, no BOM), locks with pid reuse, the process
  runner (timeout, exit codes, quoting), adb output parsing, the setup's pure
  helpers (manifest, `config.ini`, API parsing, asset pinning), the sync's pure
  helpers and a whole sync against a fake device, the status JSON, the tray
  state machine and menu against the Swift code's cases;
- Python: `sqlite_query.py` against a WAL-mode database copied db+wal+shm, the
  reclaim script's imports and empty-pending path against the pinned icloudpd;
- `git diff 97d1164 -- bin lib launchd Sources build.sh install.sh` is empty.

Proven on real Windows by GitHub Actions (`windows-latest`):

- all of the above, plus: scheduled task registration round trip (triggers,
  repetition, battery and instance settings read back from Task Scheduler),
  the config ACL, `.bat` quoting through `cmd.exe`, process-tree kill, the
  ring icons drawn with `System.Drawing` and loaded as `System.Drawing.Icon`,
  a LF device script after a checkout with `core.autocrlf=true`, and the
  reclaim script's import path under `uv` with `PYTHONUTF8=1`.

Python on ubuntu-latest and macos-latest: the same Python tests.

Not provable here or in CI, and first run by a Windows user (with the
diagnostics they should paste back, listed in the README): emulator boot under
WHPX, the Magisk patch on an x86_64 ramdisk, NeoZygisk and the spoof module,
the Play Store extraction, the Google sign-in, the icloudpd login and keyring
path, and an actual upload confirmed and reclaimed.

## Risks and unknowns

- **The x86_64 ramdisk may use a codec or layout the patch script has not
  met.** The script detects the codec from `magiskboot decompress` and falls
  back to `lz4_legacy`; a failure keeps `ramdisk.img.backup`, and the README
  says how to restore it.
- **`conhost.exe --headless` is undocumented.** If a task never starts,
  `install.ps1 -VisibleConsole` registers plain `pwsh -WindowStyle Hidden`
  (a brief console flash per run) instead.
- **The icloudpd Windows build's keyring backend** may be the fail backend in
  a frozen executable. The failure is fast either way; the cost would be that
  an expired session needs the interactive login again.
- **Whether `-gpu host` renders Google's sign-in on Windows** is unknown (the
  macOS trap was Metal-specific); `avd-signin` uses software GL regardless.
- **A child emulator's lifetime.** A task's child processes are expected to
  outlive the task's own process, as launchd's do; the sync stops the emulator
  itself when idle, so the failure mode would be a reboot per batch, not lost
  work.
