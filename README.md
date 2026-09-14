# icloud-to-google-photos

An unattended pipeline that moves an iCloud photo library into Google Photos and
then reclaims the iCloud space, on a Mac or a Windows PC, with no taps.

Every fifteen minutes it downloads new originals from iCloud with
[icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader),
pushes them into a rooted Android emulator whose device fingerprint is spoofed to
a Pixel, waits for Google Photos to actually upload them, checks each upload
against Google Photos' own database, and only then deletes those exact photos
from iCloud. A menu-bar ring shows which stage the current batch is in.

The same scripts run on Windows under Git for Windows' bash, with a tray icon
in the notification area where the Mac has its menu-bar item, Task Scheduler
where the Mac has launchd, and an x86_64 emulator where Apple silicon runs an
arm64 one. See [Windows](#windows).

The reason for the emulator is the only interesting part: Google Photos gives
original-quality backup, with no counting against Google One storage, to a 2016
Pixel. A rooted Android emulator running a Magisk module that spoofs those device
fields is treated as one. Everything else here exists to make that reliable and
to make sure nothing leaves iCloud before it is provably somewhere else.

**Read "What this actually is" before installing.** This is a spoof of a device
Google no longer sells, running on a rooted emulator, backing up photographs you
probably cannot re-take. It is built to fail safe, but it is not a product.

---

## What this actually is

Honest, in order of how much it should worry you.

**A rooted emulator with a spoofed device identity.** The stack is Google's own
`google_apis` system image (a `userdebug` build, which is what makes it rootable)
patched with Magisk, plus NeoZygisk and the GPhotosUnlimited module, which spoof
`Build` fields, native properties and `PackageManager.hasSystemFeature()`. Google
Photos then reports "Unlimited storage" in the account menu and `Quality:
Original` on the backup screen. **Google can withdraw or detect this at any
time**, and if it does, this pipeline's uploads simply start counting against
your Google storage - the verification still works, so nothing is lost, but the
free ride ends. Do not build a storage plan on it.

**Google refuses sign-in until you register the device by hand.** An uncertified
`dev-keys` build cannot sign in to a Google account until its device id is
registered at <https://www.google.com/android/uncertified/>. That is one form,
once, per Google account. The trap is where the id is: the usual
`content query --uri content://com.google.android.gsf.gservices` answers **"No
result found"** on this image, because the GSF package is inert here and never
creates its database - which reads as "this device has no id and can never be
registered", and is wrong. The real id lives in GMS, in two places that agree:
`/data/data/com.google.android.gms/shared_prefs/Checkin.xml` and
`.../databases/gservices.db`. `avd-photos-setup` reads it and prints it beside
the registration URL.

**The GPU mode is a trade-off, and getting it wrong looks like something else
entirely.** `-gpu host` routes the guest's GL through Metal and is much faster
for everything the pipeline does - but Google's login page is a Chromium WebView
that cannot render under it (it stalls forever on the Play Services splash;
`-gpu auto` hard-crashes on `EGL_BAD_CONFIG` before drawing a pixel). What a
person sees is the Sign in button doing nothing at all, with no error anywhere,
which reads as Google refusing the device and sends you off chasing Play
certification. Only software GL paints the form. So: `avd-signin` for the
one-time sign-in, `avd-start` (Metal) for everything else.

**Two different reboots, and using the wrong one silently loses the work.** After
patching `ramdisk.img` on the host, the emulator PROCESS must be restarted - QEMU
reads the ramdisk exactly once, at VM start, so a guest-level `adb reboot`
re-runs the same in-memory copy and every later phase fails against a device that
is simply not rooted. After installing a Magisk MODULE it must be a graceful
`adb reboot` and never `adb emu kill`, which hard-stops the VM, discards
unflushed writes, and lands module files as zero bytes with `/data/adb/modules`
wiped at the next boot. `avd-photos-setup` keeps these as two separate functions
on purpose; do not collapse them.

**Magisk's "Requires Additional Setup" is a third, unasked-for reboot.** The
setup refills `/data/adb/magisk` from the APK itself (Magisk's own staged
copies land as zero bytes on this emulator), and for a long time it copied only
what the daemon runs. The Magisk APP judges the install with `env_check`
(`assets/app_functions.sh`), which also demands `boot_patch.sh` beside the
binaries - so opening the app offered "Additional Setup" and, on OK, rebooted
the VM (seen on Windows, the first time the emulator ran with a window). It was
harmless, since root, the modules and Zygisk all survived, but it was a reboot
nobody chose, in the middle of whatever the sync was doing. The refill now
copies the whole set Magisk's own fix installs (`boot_patch.sh`, `addon.d.sh`,
`init-ld`, `chromeos/`), and `env_check` passes.

**Nothing is version-pinned, and a re-run is the update.** The SDK tools, the
system image, Magisk, NeoZygisk and the spoof module all resolve to "newest" on
every run, and the weekly agent is exactly that re-run. Two updates are
deliberately NOT automatic, because both destroy a working signed-in instance and
no scheduled job could undo them: recreating the emulator onto a newer API level
(userdata cannot migrate - opt in with `AVD_RECREATE=1`) and re-patching the
ramdisk for a newer Magisk (can leave it unbootable - `AVD_REROOT=1`). Both are
reported instead.

**Everything it flashes is an unsigned artefact from someone's GitHub release.**
Magisk, NeoZygisk and the spoof module are fetched at run time from their
upstream releases, over TLS, and TLS only says the bytes came from GitHub -- not
that the release is the one anybody reviewed. They are then given root on the
emulator. Nothing here is version-pinned, by design (a re-run is the update), so
hashes committed to this repository would be wrong by the next release and are
not on offer. What is on offer is that **a release tag cannot change under you**:
the first time a tag is seen its sha256 is recorded in `stamps/`, and a later
download of that same tag must match or nothing is flashed. That catches a
re-uploaded asset and a truncated download. It does not catch a malicious NEW
release, and neither does anything else here -- if one of those projects is
compromised, this pipeline installs the compromise at its next weekly run. The
mitigations that actually apply are the ones you already have: the emulator is
disposable and holds nothing but photographs on their way out, and it is the only
thing being rooted. Pin `AVD_REROOT`/`AVD_RECREATE` off (they are), read the
release notes if that is not enough, and remember that the Play Store here comes
out of Google's own certified image rather than any third-party mirror.

**It fails quietly unless you make it noisy.** Every interesting bug in this
pipeline's history reported success while doing nothing:

- `icloudpd` with no saved session falls back to `getpass()` and blocks forever
  in a launchd job. Its stdin is `/dev/null` now, so it fails fast and the log
  prints the exact interactive login command.
- A packaged `icloudpd` that aborted on every invocation passed the
  `command -v icloudpd` guard, and its non-zero exit was logged as "often just
  'no new items'". The whole pipeline was a no-op for days while the menu bar
  said "All backed up". Death by signal and exit 127 are fatal errors now, not
  routine ones.
- `uv tool install` puts `icloudpd` in `~/.local/bin`, which is on a shell's PATH
  and not in launchd's environment, so every scheduled run skipped for five days
  while the one interactive run of those five days worked. Every script seeds
  that directory first.
- On Android 17, `cmd media rescan` and `cmd media scan` do not exist, and the
  legacy `MEDIA_MOUNTED` broadcast RETURNS SUCCESS while indexing nothing. The
  only thing that works is
  `content call --uri content://media --method scan_file --arg <path>`, and it is
  asynchronous, so it has to be polled.
- Listing a cloud-provider staging tree from a launchd job is refused by macOS
  with "Operation not permitted" on every directory, while the same listing from
  a terminal returns instantly. That is why the sync runs as a child of the app
  bundle (see "Staging" below), why it never trusts a single listing, and why an
  `Operation not permitted` is an immediate named failure rather than "nothing
  new".

The rule those add up to: **liveness is the age of the last COMPLETED run**, not
the age of a log file, because a job that bails writes the log too. A healthy
no-op still ends in `done (0 pushed this run)`.

**Deleting from iCloud is gated on Google Photos' own database, per file.** See
the next section. If you want none of that, set `DELETE_FROM_ICLOUD=0` and the
pipeline becomes a one-way copier.

---

## How it works

```
  iCloud ──icloudpd──> staging dir ──adb push──> emulator DCIM/Camera
                                                        │
                                          MediaStore scan_file
                                                        │
                                              Google Photos backup
                                                        │
                            local_media ⋈ remote_media on dedup_key
                                                        │
                              ┌─────────────────────────┴──────────────┐
                       prune the device copy                  delete from iCloud
```

One run, step by step:

1. **`icloudpd` first, before the emulator.** Its incremental pass
   (`--until-found 50 --recent 2000`, about a minute against a saved session) IS
   the "is there anything new" check. A quiet tick therefore costs one icloudpd
   pass and no VM.
2. **Decide whether to boot at all.** If nothing is staged that the ledger has
   not seen, and the last batch was confirmed, the emulator stays off and the run
   ends in `nothing new: N staged, all pushed and confirmed`.
3. **Boot headless**, wait for `sys.boot_completed`.
4. **Push what the ledger has not seen**, up to `PUSH_CAP` per run, into
   `DCIM/Camera` - not a folder of your own, because every other device folder is
   opt-in under "Back up device folders" and that preference starts empty. Each
   staged path becomes one flat device name (`2026/05/IMG_2885.HEIC` ->
   `2026_05_IMG_2885.HEIC`), because DCIM is flat and iCloud names repeat across
   months. Every push's landed size is checked against the source: `adb push` has
   reported success while writing a file empty.
5. **Index and foreground**: `scan_file` per path, batched 100 per `adb` call,
   polled until MediaStore has rows, then Google Photos is brought to the front.
6. **Verify.** Google Photos keeps one row per device file in
   `/data/data/com.google.android.apps.photos/databases/gphotos0.db`. A file is
   uploaded when its `dedup_key` appears in `remote_media`. That is the ONLY
   authoritative signal: the file on disk, a MediaStore row, a thumbnail in the
   UI and a running backup job are all satisfied long before a byte is uploaded,
   and `first_backup_timestamp` is stamped at QUEUE time, not on success.
7. **Prune the device copy** of every confirmed file, and put its staged path on
   the reclaim list. The emulator is disposable staging; left alone its DCIM
   grows with the entire library until the disk fills.
8. **Reclaim iCloud space** for exactly the paths on that list, and nothing else.
9. **Stop the emulator** once the device is drained and the batch is confirmed.

### How the verification is actually done

Three things about that query were each a false "UPLOAD CONFIRMED" once, and all
three are in the SQL now:

- **Scope it to the camera folder AND to the files currently on the device, by
  path.** `local_media` keeps rows for files earlier runs already pruned, so
  "camera-folder rows, all uploaded" was once satisfied by a set that was mostly
  stale: 500 pushed, `UPLOAD CONFIRMED: 135`, 365 not yet registered.
- **Count DISTINCT files, never join rows.** `remote_media` holds more than one
  row per `dedup_key` (on a library much of which reached Google Photos from a
  phone already, 7,393 keys were shared), so `count(*)` reported 1,894 uploaded
  for 1,393 files on the device and declared success eleven seconds after a
  1,000-file push.
- **Re-announce what Photos has not registered.** Google Photos syncs MediaStore
  incrementally and never revisits what it skipped: an hour after indexing, 369
  files still had no `local_media` row. A `touch` plus `scan_file` bumps the row's
  generation and Photos picks them up (146 registered went to 468 in one pass).

When every file on the device is confirmed with zero permanent failures, the run
writes `last-upload-confirmed`. **A run that cannot confirm DELETES that stamp**,
and the reclaim step checks for it before it deletes anything -- including a run
that inherits a pending list from a healthier one -- so a pipeline that breaks
stops reclaiming on the very next run rather than quietly eating a photo library.

### How the iCloud deletion is done

`avd-photos-reclaim.py` runs against the same library `icloudpd` uses, pinned to
the installed tool's version and sharing its `~/.pyicloud` session. It:

- takes ONLY the list of paths the `dedup_key` join confirmed - **filename
  matching is not confirmation** and is never used: of 1,525 confirmed files, 444
  had a remote row with the same name and size, 109 the name only, and 972 no row
  by name at all, because Google Photos keeps its own names;
- rebuilds each asset's staged path with icloudpd's own functions (created date
  in local time under `{:%Y/%m}`, the cleaned filename, the `-<size>` dedup
  suffix as a second candidate);
- holds a Live Photo until both of its staged files are confirmed;
- skips anything newer than `KEEP_ICLOUD_DAYS`, **which defaults to 7** -- a net
  for the first armed runs, since that is when a mis-set staging path or a
  half-finished sign-in shows up. Set it to 0 to reclaim a photo as soon as it is
  confirmed;
- refuses to map a device file back to a staged path when the basename matches
  more than one ledger entry (iCloud basenames repeat across months), so an
  ambiguous file simply stays in iCloud;
- **reads the server's answer.** icloudpd's own `delete_photo` posts and logs
  "Deleted" without checking the response; one deletion in fourteen came back
  with the asset still in the library. This sends the identical request and
  accepts only a record with `isDeleted=1` and no `serverErrorCode`. A rejected
  deletion stays pending and is retried on the next run;
- treats a pending path with no asset in the library as "already gone" - the safe
  direction, since a wrong match can only leave a photo in iCloud.

iCloud keeps a deleted asset in Recently Deleted for 30 days, where it still
counts against the quota until it expires or the album is emptied by hand.

**Try it before you arm it.** `avd-photos-offload --dry-run` (equivalently
`avd-photos-sync --reclaim-dry-run`) runs exactly this step against your library
in dry-run mode: it needs no emulator and no arming, deletes nothing, changes no
ledger, and writes a per-file decision -- deleted / held / kept / not found -- to
`~/.cache/avd-photos/logs/reclaim.log`. It is the honest answer to "will it find
the right photos", and a lot of `NOT FOUND` lines mean the staged-path rebuild
does not match your library, which is worth understanding before anything is
deleted for real.

### Staging

`STAGING` is where downloaded originals land and where they stay until Google
Photos has confirmed them, so for the minutes-to-hours in between **it holds the
only copy outside iCloud's Recently Deleted**. Any directory works, and it must
not be a cache directory (those are prunable by design).

This pipeline was built against a Google Drive folder in stream mode, for two
reasons: the staging tree gets its own off-machine backup for free, and the bytes
leave the local disk again once Drive has uploaded them, so a 200 GB library does
not need 200 GB of free space. That choice has one cost, and it is the reason for
an odd piece of design here: **a cloud-provider mount is permission-gated per
app**, and a launchd job's responsible process is its own executable, so a bare
`/bin/bash` gets "Operation not permitted" on every directory of the mount while
the same listing from a terminal returns in milliseconds. So the sync agent runs
`Photo Sync.app`'s binary with `--sync`, which spawns the sync script as the
app's child; the child inherits the app's file-provider grant. If your staging
directory is a plain local folder, that indirection is harmless and you can
ignore it.

---

## Requirements

These are the Mac's; a Windows PC needs far less, because its installer fetches
everything itself - see [Windows](#windows).

- **Apple silicon Mac, macOS 14 or newer.** The emulator is `arm64-v8a` and the
  tuning defaults assume roughly 8 performance cores and 16 GB.
- **Xcode Command Line Tools** (`xcode-select --install`) for `swiftc`. Full
  Xcode is optional: with it, the app icon gets light and dark variants through
  `actool`; without it, a light-only `.icns`.
- **Android SDK command-line tools** - `sdkmanager` on PATH is enough to
  bootstrap. Everything else (the emulator, platform-tools, the system image) is
  downloaded by `avd-photos-setup` into its own writable SDK root. It must be
  writable: rooting rewrites `ramdisk.img` in place.
- **`uv` and `icloudpd`**: `uv tool install icloudpd`.
- **`jq`, `curl`, `python3`** (`python3` is macOS's own), and `sqlite3` (macOS
  ships it).
- **A Google account** you are willing to sign in to on a rooted emulator, and an
  **Apple ID** for icloudpd.
- **Google Drive for Desktop** only if you put the staging directory on Drive.
- About **30 GB of disk** for the SDK, the system image and the emulator's data
  partition, plus whatever the staging tree holds at its peak.

---

## Install

```sh
git clone <this repo> icloud-to-google-photos
cd icloud-to-google-photos
./install.sh
```

`install.sh` symlinks `bin/` into `~/.local/bin`, builds `Photo Sync.app` into
`/Applications`, writes the default config if there is none (0600, and it
tightens an existing one), and loads the five launchd agents. Options:
`--prefix`, `--app-dir`, `--copy` (a self-contained copy under `libexec`, so the
checkout can be deleted), `--no-agents`, `--no-app` (which also skips the two
agents that ARE the app), `--uninstall` (which removes only symlinks that resolve
back into this checkout).

**Nothing syncs yet.** The sync agent is loaded but every tick exits immediately
until you arm it.

Then, in order:

1. `avd-photos-config` - check the config; set `ICLOUD_USERNAME`, and `STAGING`
   if you want it somewhere other than `~/Pictures/icloud-photos-staging`.
2. `icloudpd --username <your apple id> --directory <staging> --recent 1` - the
   one-time interactive Apple login, including two-factor. Nothing unattended can
   do this, and without it every run says "no saved session".
3. `avd-photos-setup` - builds the whole rooted stack. This is long (a multi-GB
   system image, a rooted ramdisk, three reboots, and the Play Store extraction)
   and it is resumable: the "done" marker is written only after the last phase
   succeeds, so an interrupted build resumes at the next login rather than
   declaring victory.
4. `avd-signin` - boots the emulator in software GL. Open Google Photos, sign in,
   and register the device id the setup printed at
   <https://www.google.com/android/uncertified/> as that same account. Turn
   Backup ON and confirm the backup screen says `Quality: Original`.
5. `avd-photos-check` - reports Magisk, Zygisk, the spoof module, Google Photos
   and the Play Store, and changes nothing.
6. `avd-photos-offload --dry-run` - see which photos the reclaim would match in
   your library, without deleting anything.
7. `avd-photos-arm` - prints exactly what arming switches on (the Apple ID, the
   staging directory, whether iCloud deletion is on and what it keeps) and then
   stops. `avd-photos-arm --yes` **arms it**: from here the pipeline runs on its
   own, deletions included. (With `DELETE_FROM_ICLOUD=0` the plain command arms
   it, since nothing can be deleted.) `avd-photos-arm --off` disarms.

### The one-time human steps

Four, and no automation can do any of them:

- **The Apple ID session for icloudpd** (step 2 above). Two-factor, interactive,
  once per Mac.
- **The Google sign-in inside the emulator** (step 4), in software GL.
- **The uncertified-device registration**, once per Google account, with the
  device id from GMS' `Checkin.xml` - not from the GSF provider, which answers
  "No result found" here. If sign-in still fails afterwards, force a check-in
  with `adb -s <serial> shell am broadcast -a android.server.checkin.CHECKIN`,
  where `<serial>` is the one `avd-photos-check` prints as `device:` while the
  emulator is running (do not assume `emulator-5554` — see "Which emulator is
  ours"), and try again.
- **The file-provider grant for `Photo Sync.app`**, only if your staging
  directory lives on a cloud mount. macOS asks the first time the app's child
  reads it; answer yes. (For Google Drive it is the per-app File Provider
  permission; for an iCloud Drive staging directory, grant the app Full Disk
  Access in System Settings > Privacy & Security.) Until it is granted, the sync
  fails with a named error rather than reporting "nothing new" - that is
  deliberate.

On Windows the list is the same minus the last item - Windows has no per-app
file-provider grant, so a staging directory on a synced drive needs nothing -
plus one step before all of them: **turning on the Windows Hypervisor
Platform**, which needs an administrator and a reboot (see
[Windows](#windows)).

---

## Windows

The pipeline is the same bash scripts, run by Git for Windows' bash (MSYS2),
with the OS differences in ONE file, `lib/os.sh`: stat, hashing, dates, the
emulator's process, detached launches. Everything that decides what gets
downloaded, pushed, confirmed and deleted is the code described above,
unchanged. What differs is the plumbing around it: a tray app instead of the
menu-bar app, Task Scheduler instead of launchd, an installer written in
PowerShell, and an x86_64 emulator on an Intel or AMD PC.

### Requirements

- **Windows 10 or 11, x64 or ARM64.** The emulator ABI follows the host
  (`AVD_ABI` defaults to `x86_64` on Intel/AMD and `arm64-v8a` on ARM64): an
  arm64 image has no accelerator on an x86_64 host, and a Zygisk module's arm64
  library cannot load into an x86_64 zygote. Magisk, NeoZygisk and the spoof
  module all ship x86_64 builds.
- **A hypervisor: the Windows Hypervisor Platform (WHPX).** The one step that
  needs an administrator, once, followed by a reboot:

  ```powershell
  Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
  ```

  `avd-photos-setup` asks the emulator itself (`emulator -accel-check`) and
  stops with that command if there is no usable hypervisor. Without one the
  failure is otherwise a boot that never finishes.
- **About 30 GB of disk**, as on a Mac. On a PC with a small system drive, put
  `AVD_SDK_ROOT` and `AVD_HOME` on a bigger one (see the config table).
- **Nothing else.** No administrator rights, and nothing preinstalled: not Git,
  not Python, not Java, not an Android SDK. The installer and the setup fetch
  their own, and ignore whatever the machine already has - see below.

### Install

Double-click `install.cmd`, or from a terminal in the checkout:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

(`install.cmd` exists because a stock Windows refuses to run PowerShell scripts
at all - execution policy "Restricted" - so it runs the installer with the
policy bypassed for that one process only.)

Options, the counterparts of `install.sh`'s: `-ToolsDir <dir>` (its own Git,
.NET SDK and NuGet cache; default `%LOCALAPPDATA%\avd-photos\tools`),
`-Prefix <dir>` (commands in `<dir>\bin`; default `~\.local`), `-AppDir <dir>`
(the tray app; default `%LOCALAPPDATA%\Programs\Photo Sync`), `-Copy` (a
self-contained copy of `bin\` and `lib\` under `<prefix>\libexec\avd-photos`, so
the checkout can be deleted), `-UseInstalledGit` (an existing Git for Windows'
bash instead of the pipeline's own), `-NoTasks`, `-NoApp` (which also skips the
tasks, because every task runs the app), `-Uninstall`.

**Reproducible from an empty machine, on purpose.** A PC with Android Studio, a
system Python and Git installed gets exactly the same result as a fresh one -
which is also the only way to know it works on a fresh one. What it installs,
and why each is its own:

- **Git for Windows, portable**, into the tools directory: the bash the scripts
  need. Unpacked from the release's `PortableGit` archive - no installer, no
  admin, nothing registered - and checked against the sha256 GitHub records for
  that asset. It is the pipeline's own even when Git is installed, because on a
  stock Windows `bash` on PATH is WSL's, and a different bash is a different
  set of tools.
- **uv**, from Astral's installer, into `~\.local\bin` (which it adds to the
  user PATH), and **uv-managed Python 3.13**. Python on Windows is always uv's
  (`python3` is a function over `uv run` in `lib/config.sh`), never whatever
  `python3` resolves to.
- **icloudpd**, with `uv tool install`, into `~\.local\bin`.
- **jq**, the release's `jq-windows-amd64.exe`, checked against GitHub's digest.
- **A `.cmd` shim per command** in `~\.local\bin`, so cmd and PowerShell can run
  `avd-photos-setup` and the rest. Each names the ONE bash this install uses and
  puts that Git's `usr\bin` and `mingw64\bin` first on PATH.
- **The config**, through `avd-photos-config --ensure`: written only if absent,
  and made private (below).
- **A private .NET 10 SDK** in the tools directory, installed by Microsoft's
  `dotnet-install.ps1`, with NuGet's cache beside it, to build the tray app
  (`windows\build.ps1`). The app is published SELF-CONTAINED - .NET and the
  Windows App SDK runtime travel in its folder - so the PC needs neither
  installed.
- **The tray app** into `%LOCALAPPDATA%\Programs\Photo Sync`, with
  `PhotoSync.settings.json` beside the exe recording the commands directory
  and the bash. Start-menu shortcuts **Photo Sync** (the tray) and **Google
  Photos (AVD)** (`avd-photos-app`, below).
- **Four scheduled tasks** (below).
- **The tray icon, shown.** Windows 11 files every new notification icon under
  the `^` overflow, per exe path, so a meter installed on purpose would start out
  of sight. The installer promotes Photo Sync's own entry once it appears
  (Settings > Personalization > Taskbar > Other system tray icons hides it
  again).

Later, `avd-photos-setup` fetches the rest into the SDK root: **its own JDK**
(the Microsoft Build of OpenJDK 21, a plain zip, checked against the
`.sha256sum.txt` Microsoft publishes beside it) for the SDK's Java tools, and
**Google's cmdline-tools**, straight from the repository index `sdkmanager`
itself reads (`repository2-3.xml`) and checked against the checksum in it -
there is no `sdkmanager` on a fresh PC to bootstrap them with.

**Nothing syncs yet.** Then, in a NEW terminal (so PATH has the commands), the
same steps as on a Mac:

1. `avd-photos-config` - set `ICLOUD_USERNAME`; on a small `C:` also
   `AVD_SDK_ROOT` and `AVD_HOME` (any spelling works, quoted:
   `AVD_SDK_ROOT="D:\avd\sdk"`).
2. `icloudpd --username <your apple id> --directory <staging> --recent 1` - the
   Apple login, two-factor, once.
3. `avd-photos-setup` - builds the rooted stack on the x86_64
   `google_apis` image. Long, resumable, as on a Mac.
4. `avd-signin` - the sign-in mode, then register the device id at
   <https://www.google.com/android/uncertified/>. On Windows that mode is
   ANGLE (`-gpu angle_indirect`), not software GL (see the traps below). The
   **Google Photos (AVD)** shortcut uses it too until it has seen Photos signed
   in, so a first click there lands on a sign-in page that renders.
5. `avd-photos-check`.
6. `avd-photos-offload --dry-run`.
7. `avd-photos-arm` / `avd-photos-arm --yes` - arming starts the sync task at
   once (`schtasks /Run`) instead of kickstarting a launchd agent.

### The tray

A click on the icon - left or right, or Enter from the keyboard - opens a
Windows 11 flyout against the taskbar: Desktop Acrylic, rounded corners, gone
the moment it loses focus. It carries what the macOS dropdown carries, drawn
from the same `avd-photos-status` JSON by a line-for-line port of the menu-bar
app's state machine (`windows/PhotoSync/Status.cs`), so the two can never
disagree about what a status means: the ring and a one-line conclusion, a
"Dormant" warning when not armed, the ledger (staged, backlog, on device,
verified, iCloud freed, last run, emulator), and the actions - **Check iCloud
now** (runs the scheduled sync task, so the run is Task Scheduler's and a tray
restart cannot kill it), **Offload from iCloud** (offered only once a batch is
confirmed, exactly as on the Mac), **Open Google Photos (emulator)** - plus
refresh, the logs folder and quit. The icon itself is the ring alone, drawn at
the exact pixel size the shell asks for (16 px at 100% scaling), in the same
muted colours; the tooltip carries the one short count the Mac shows beside
it. It re-adds itself when Explorer restarts, repaints when the taskbar
switches light/dark, and refreshes on wake.

It is WinUI 3 on the Windows App SDK, unpackaged. The notify icon is
`Shell_NotifyIcon` through P/Invoke and the ring is drawn from pixels, so the
Windows App SDK is its one package dependency.

### Task Scheduler

The launchd agents' twins, in the Task Scheduler folder
`\icloud-to-google-photos\`, all running as the logged-on user, none needing
elevation:

| Task | When | What |
| --- | --- | --- |
| `sync` | every 15 min + at logon | `PhotoSync.exe --sync`. Below-normal priority, allowed on battery, no time limit, a second instance is ignored. |
| `setup` | Saturday 05:30 | `PhotoSync.exe --setup --headless` - the update. |
| `bootstrap` | at logon | `PhotoSync.exe --setup --bootstrap` - builds or resumes; a no-op once complete. |
| `tray` | at logon + every 5 min | `PhotoSync.exe --background` - the tray. The 5-minute tick is KeepAlive's twin: Task Scheduler's own restart settings only retry a task that fails to *start*, so a tray that dies later is started again by the next tick (while it runs, the tick is ignored). |

**Every task runs `PhotoSync.exe`, never bash.** Task Scheduler gives a console
program a visible console window, so a bash started straight from a task would
flash one every fifteen minutes. `PhotoSync.exe` is a windowless program that
starts bash hidden and waits for it, so the task's status is the script's exit
code. There is no `.app` identity to inherit on Windows; the console is the
whole reason.

### The tray app's CLI

`PhotoSync.exe` handles its arguments before WinUI starts:

- no argument - the tray; a second launch opens the running one's flyout and
  exits (the Start-menu shortcut's job).
- `--background` - the tray, without opening the flyout (the logon task).
- `--sync [args...]` - `avd-photos-sync`, arguments passed through.
- `--setup [--headless|--bootstrap]` - `avd-photos-setup`, those flags only.
- `--open-photos` - `avd-photos-app --launch`: boot the emulator if needed,
  open Google Photos in it, bring its window forward. The **Google Photos
  (AVD)** Start-menu shortcut runs this; it is what `avd-photos-app` builds on
  Windows in place of the Dock launcher, with the same generated pinwheel icon
  as a multi-size `.ico`.

Each mode names one fixed script and there is no general "run this", for the
macOS app's reason: whatever decides WHAT this exe runs decides what runs every
fifteen minutes. The commands directory and the bash come only from
`PhotoSync.settings.json` beside the exe, written by `windows\build.ps1` at
install time; the environment is not consulted. stderr of each run goes to
`logs\<mode>.task.log` - the `*.launchd.log` twin, empty in normal operation.

### The Windows traps

Every one of these was hit during the port, and most of them failed silently:

- **Git checks scripts out with CRLF.** Git for Windows installs with
  `core.autocrlf=true`, and bash then reads `set -uo pipefail\r` and dies on
  line one. `.gitattributes` forces LF for everything except the
  Windows-native files.
- **MSYS rewrites device paths.** Handing a native program an argument that
  starts with `/` converts it, so `adb push f /sdcard/x` reaches adb.exe as
  `... C:/Program Files/Git/sdcard/x` and the push lands nowhere, with no
  error. The emulator's path prefixes are excluded (`MSYS2_ARG_CONV_EXCL` in
  `lib/os.sh`); host paths still convert, which mktemp's `/tmp/...` needs.
- **Environment variables are NOT converted.** `ANDROID_HOME=/c/sdk` reaches
  the emulator as the literal string. So every path the pipeline owns is held
  in mixed form, `C:/Users/me/...`, which bash, cygwin's stat and native
  programs all read; `HOME` is normalised first and every config path key is
  normalised after the config is read. A PATH entry is the one place mixed
  form breaks (`C:` is a separator there), so `ap_seed_path` converts back.
- **`python3` is an advert.** On a stock Windows it is the Microsoft Store's
  App Execution Alias, which prints a message and exits 9009. Hence uv's.
- **Native programs write CRLF**, and `$(...)` keeps the `\r`: a tag read as
  `v30.7\r` matches no stamp and builds a URL curl rejects. `jq` runs with
  `--binary` and the Python wrapper strips `\r`.
- **cmdline-tools 23 turned `sdkmanager` into a shim** over the new Android CLI
  (`android sdk ...`), and on Windows that shim is worse than it looks. It
  lists packages as `system-images/android-37.0/...` rather than with `;`
  (`latest_api` reads both). It is a `.bat`, and cmd splits an unquoted
  argument at `;` before the shim sees it, so `system-images;android-37.0;...`
  arrives as four packages - the setup passes the `/` form. `android.exe`
  exits **127 after a successful install exactly as after a failed one**, so
  on Windows its status carries no information and the setup judges the state
  instead: the package directory exists, the listing actually lists images.
  And **it cannot replace itself**: updating `cmdline-tools/latest` from the
  `android.exe` inside it crashed with `AccessDeniedException` half-way through
  deleting the directory, because Windows will not delete a running
  executable. So the setup runs it from a private copy under the state
  directory, refreshed whenever `latest` changes, and installs or updates
  nothing while anything is running out of the SDK root (it stops its own adb
  server for that; a running emulator makes it skip the update and say so).
- **Closing a terminal kills an emulator started from it.** A native program
  started from bash shares bash's console, and closing the window sends every
  process on it `CTRL_CLOSE_EVENT`; `nohup` does not help. So the emulator is
  started by a bash that .NET creates with `CREATE_NO_WINDOW` - a console of its
  own - running `lib/spawn-detached.sh` (`ap_spawn_detached`). Two first drafts
  of that each failed quietly: `cmd.exe`'s `>>` opens the log for EXCLUSIVE
  write, so the Play Store donor VM, launched while our VM's launcher was still
  exiting, silently never started; and a launcher whose own stdout was a pipe
  handed that pipe to the emulator, so the "background" launch blocked until the
  VM exited. The launcher now runs with its handles on NUL.
- **adb writes CRLF.** `adb shell echo ok` arrives as `ok\r\n`, and every exact
  test on a device answer - `grep -q '^ok$'` for the preinit device, a module,
  the sepolicy rule - would read "no": modules re-flashed and a reboot on every
  run, and no preinit device, which is the zero-byte-modules failure. The one
  capture every device query goes through (`dev_capture`) strips it.
- **icloudpd's password prompt ignores stdin.** Its last password provider,
  `console`, is Python's `getpass`, which on Windows reads the CONSOLE through
  msvcrt - so the `</dev/null` that makes it fail fast on a Mac does nothing, and
  a lapsed session would block the sync forever in a hidden console, holding its
  lock. On Windows the sync asks only the `parameter` and `keyring` providers,
  and a missing session fails at once with the usual "NO SAVED SESSION" line.
- **A bare `usr\bin\bash.exe` has no `/usr/bin` on PATH**, and every script
  resolves its own directory with `dirname` and `readlink` before `lib/` can
  fix anything: `dirname: command not found`. Whoever starts bash - the shims,
  the tray, the installer - puts Git's `usr\bin` and `mingw64\bin` first.
- **Windows will not replace an open file.** A patched `ramdisk.img` may not
  swap in while QEMU still holds the one it booted from; the setup then stops
  the VM, swaps, and boots - the same process restart, in the only order
  Windows allows. Likewise the Play Store donor VM must be gone before its
  image is deleted.
- **Google's sign-in on Windows: neither the Mac's fast mode nor its slow
  one.** `-gpu host` stalls on the same "Checking info..." splash as on a Mac
  (measured: `MinuteMaidActivity` loads, the WebView never paints). Software GL
  paints it, but draws the 2560x1440 tablet screen on the CPU, and on a 4-core
  laptop System UI and Photos answered "isn't responding" to every tap. ANGLE
  (`-gpu angle_indirect`, Direct3D underneath) renders the login page and leaves
  the CPU to the guest, so it is `avd-signin`'s Windows default
  (`AVD_SIGNIN_GPU` overrides). And the first click is where people meet this,
  so the Photos shortcut starts in sign-in mode until it has seen Photos'
  signed-in database (`photos-signed-in` in the state directory).
- **The first minutes after a boot are unusable on a spinning disk.** Android
  dex-optimises and updates Play services right after booting; with the
  emulator's images on a laptop's HDD the guest's load average was 28 and the
  host disk 124% busy, and every app opened then answered "isn't responding".
  It passes in a few minutes (the Photos shortcut waits for the load to fall
  before opening Photos), but an SSD is the real fix: `AVD_HOME` holds the
  writable disk that takes the random writes, and it is small (2-3 GB plus the
  batch on the device), so it is the one to put on an SSD if the SDK cannot be.
- **`config.ini` records the image with backslashes** on Windows
  (`image.sysdir.1=system-images\android-37.0\...`), which the API parse
  anchored on `/` never matched.
- **`adb -s "" emu kill`** (what `avd-stop` sent before it resolved a serial)
  addresses whichever single device is attached. `--stop` now resolves ours
  first, on both platforms.

---

## Monitoring

**The menu bar** is the ring. Its colour says which side of the pipeline the
current batch is on: a neutral spin while iCloud is downloading (with a running
tally), yellow while pushing, indexing or pruning on the device, blue while
Google Photos confirms, purple while iCloud space is being reclaimed, a green
check when everything staged is confirmed, and orange or red with an exclamation
when the pipeline has stopped tracking reality. When it is not armed the ring is
dim and the menu says so. The dropdown carries the ledger (staged, backlog, on
device, verified, iCloud freed, last run, emulator), the live phase line of a
running sync, "Check iCloud now", and "Offload from iCloud" - which is offered
only once a batch has actually been confirmed, because it deletes from the real
photo library.

**The command line:**

```sh
avd-photos-status | jq            # the same JSON the menu bar reads
tail -f ~/.cache/avd-photos/logs/sync.log
avd-photos-check                  # versions of everything, changes nothing
avd-photos-arm --status
```

**Actions:**

```sh
avd-photos-offload                # reclaim iCloud space now (still gated on
                                  # a confirmed batch; a no-op otherwise)
avd-photos-offload --dry-run      # what WOULD leave iCloud; deletes nothing
avd-start / avd-stop              # the emulator, with the right flags
avd-signin                        # the emulator in software GL, for sign-in
avd-photos-app                    # rebuild the Dock launcher and its icon
```

**On Windows** the tray is the ring, and the same commands run from cmd or
PowerShell through their `.cmd` shims (`avd-photos-status` prints the same
JSON; pipe it to `jq` or `ConvertFrom-Json`). The log is at the same place
under the profile:

```powershell
Get-Content -Wait $env:USERPROFILE\.cache\avd-photos\logs\sync.log
Get-ScheduledTask -TaskPath \icloud-to-google-photos\ | Get-ScheduledTaskInfo
```

`logs\*.task.log` is the `*.launchd.log` twin: what a scheduled `PhotoSync.exe`
run could not hand to the script's own log, empty in normal operation.
`avd-photos-app` on Windows refreshes the **Google Photos (AVD)** Start-menu
shortcut rather than a Dock tile.

**Before you paste a log into an issue**, note that `sync.log` names your Apple
ID: every run starts `start (user <apple id>)`, and icloudpd's own lines can
carry it too. `reclaim.log` carries photo filenames and dates. Redact both.

---

## Uninstall

```sh
./install.sh --uninstall
```

Unloads the agents, removes the rendered plists, removes the installed commands,
and removes both app bundles. It deliberately leaves your config, the ledgers,
the logs, the staging tree, the emulator and the SDK root in place, and prints
where each of them is. Remove those by hand when you mean to - in particular, the
ledgers are the record of what has already been pushed and reclaimed, and
deleting them makes the next run re-push everything.

On Windows:

```powershell
.\install.ps1 -Uninstall
```

Removes the four scheduled tasks and their folder, stops and removes the tray
app and both Start-menu shortcuts, removes only the command shims it wrote (a
`.cmd` without its marker line belongs to someone else and is left), the
`-Copy` libexec, and its own Git, .NET SDK and NuGet cache from the tools
directory. The same data stays - config, ledgers, logs, staging, emulator, SDK -
and so do uv, icloudpd and jq in `~\.local\bin`, which are shared tools
(`uv tool uninstall icloudpd` removes that one). Pass the same `-ToolsDir`,
`-Prefix` and `-AppDir` the install used.

---

## Troubleshooting

**"Sign in" does nothing, or the login page never appears.** GPU mode. Use
`avd-signin`, not `avd-start`.

**Sign-in is refused after the page renders.** The device is not registered. Get
the id from the `avd-photos-setup` epilogue (or `avd-photos-check`), register it,
force a check-in, wait a few minutes.

**The log says `icloudpd has NO SAVED SESSION`.** Run the interactive login from
step 2. The unattended job cannot answer a two-factor prompt and will not block
trying.

**The log says `FAILED: no access to the staging directory`.** macOS refused this
process the cloud mount. The sync must run as a child of `Photo Sync.app` (the
agent does that); if you are running the script by hand from a terminal, grant
the terminal the same access, or run
`"/Applications/Photo Sync.app/Contents/MacOS/PhotoSync" --sync`.

**The menu bar says `Stale - sync job silent 5h ago`.** The agent is not
completing runs. `launchctl print gui/$(id -u)/com.ayushsharma.icloud-to-google-photos.sync`
and the tail of `sync.log` say why; a failed run leaves `failed: <reason>` in the
phase file, which the menu shows verbatim.

**The menu bar says `Unverified`.** The counts look complete but the confirmation
stamp is absent, so the last verify pass could not confirm. iCloud reclaim is off
until a run confirms cleanly. This is the designed behaviour, not a bug.

**Nothing is uploading, but everything is on the device.** Check that Backup is
ON in Google Photos and that the account is still signed in (a force-stop with a
badly configured Play Integrity module used to drop it). `avd-photos-check`
reports the spoof module.

**`GitHub API rate limit reached`.** The release lookups are unauthenticated
(60/hour per IP). The run uses its cached answers and changes nothing - which is
correct, since nothing here is pinned. Set `GITHUB_TOKEN` in the config to raise
it.

**The emulator will not boot after a Magisk update.** Re-patching the ramdisk is
opt-in for exactly this reason. The original image is kept as `ramdisk.img.backup`
beside the patched one; restore it and re-run.

**Modules vanish after a reboot.** A preinit device was not resolved, or
something used `adb emu kill` after a module install. Re-run
`avd-photos-setup`; it resolves the preinit device and re-flashes.

**Windows: `the emulator reports no usable hypervisor`.** The Windows
Hypervisor Platform is off. Enable it from an administrator PowerShell
(`Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All`),
reboot, run the setup again.

**Windows: `SDK update skipped this run`.** Something is running out of the
SDK root - the emulator, typically - and the Android CLI would delete files
out from under it. Stop the emulator (`avd-stop`); the next run, or the weekly
task, updates.

**Windows: a command prints `dirname: command not found`** or `$'\r': command
not found`. It was started by a bash with no Git tools on PATH, or from a
checkout with CRLF line endings. Run it through its `.cmd` shim (a new terminal
after the install has them on PATH), and re-check out a CRLF tree
(`git rm --cached -r . && git reset --hard` in a clean checkout) so
`.gitattributes` applies.

---

## Config and state contract

Everything a configuration manager needs in order to drive this without editing
the scripts.

### Config file

`~/.config/avd-photos/config`, shell syntax, sourced by every script, **0600**
(it holds an Apple ID and may hold a `GITHUB_TOKEN`; the installer tightens an
existing one). On Windows it is `%USERPROFILE%\.config\avd-photos\config`, and
since NTFS has no mode bits the equivalent is an ACL with inheritance cut and a
single entry for the user. `avd-photos-config --ensure` writes the default only
if there is none and makes it private, one line each - what `install.ps1` runs,
and what a configuration manager can run. Precedence is **environment > config file > default**, decided by
whether the caller SET a variable rather than whether it is non-empty, so
`KEEP_ICLOUD_DAYS= avd-photos-sync` means "no floor for this run" and beats a
value in the config file exactly as an empty value in the config file beats the
default. `AVD_PHOTOS_CONFIG_DIR`, `AVD_PHOTOS_STATE_DIR` and `AVD_PHOTOS_LOG_DIR`
are environment-only, since they decide where the config is read from in the
first place.

| Key | Default | What it is |
| --- | --- | --- |
| `ICLOUD_USERNAME` | (unset) | Apple ID for icloudpd. The sync refuses to run without it. |
| `ICLOUDPD` | `icloudpd` | The icloudpd command. |
| `STAGING` | `~/Pictures/icloud-photos-staging` | Where originals land and wait for confirmation. |
| `ICLOUD_DIR` | `~/Library/Mobile Documents/com~apple~CloudDocs` (Windows: `~/iCloudDrive`) | iCloud Drive root; only the default parent of `SHARED_CACHE_DIR`. |
| `SHARED_CACHE_DIR` | `$ICLOUD_DIR/avd-photos` | Where the extracted Play Store APK is cached so a second Mac skips a 2.7 GB extraction. |
| `GOOGLE_ACCOUNT` | (unset) | The account the emulator signs in as. Only ever printed. |
| `AVD_NAME` | `gphotos-tablet` | The emulator's name. |
| `AVD_SDK_ROOT` | `~/.local/share/android-avd-sdk` | The pipeline's own writable SDK root (its `ANDROID_HOME`). On Windows it also holds the pipeline's JDK (`jdk/`). |
| `AVD_HOME` | `~/.android/avd` | Where the emulator's own directory lives (its `ANDROID_AVD_HOME`). A key because the data partition is `AVD_DISK` large and a laptop's system drive is often the small one. |
| `AVD_ABI` / `AVD_TAG` / `AVD_DEVICE` | host's ABI / `google_apis` / `pixel_tablet` | Image selection. The ABI default follows the host: `arm64-v8a` on Apple silicon and ARM64 Windows, `x86_64` on Intel/AMD. `google_apis_playstore` is deliberately unusable here. |
| `AVD_RES` / `AVD_DPI` | `2560x1440` / `210` | Density decides which Photos layout renders; above ~384dpi it flips to the phone UI. |
| `AVD_RAM` / `AVD_CORES` / `AVD_DISK` / `AVD_HEAP` | `6144` / `8` / `16384M` / `512M` | Guest tuning. On Windows the RAM and core defaults are a share of the host instead: a third of its memory in whole GB (3-6 GB) and half its logical processors (2-8), because a PC is anything from a 4-core, 8 GB laptop up. |
| `AVD_GPU` | `host` | `host` for speed; `swiftshader_indirect` is the only mode that renders Google's sign-in on a Mac, and what `avd-signin` uses everywhere. |
| `AVD_SPOOF` | `module` | `module` = GPhotosUnlimited; `vector` = Vector + PixelifyPhotos. Never both. |
| `DEST_DCIM` | `/sdcard/DCIM/Camera` | Where files are pushed. Any other folder is opt-in for backup and will silently never upload. |
| `RECENT` / `UNTIL_FOUND` | `2000` / `50` | icloudpd's incremental walk. |
| `PUSH_CAP` | `1000` | Files handed to the emulator per run. |
| `UPLOAD_WAIT` | `900` | Floor on the wait for Google Photos, plus 2 s per file on the device. |
| `ADB_TIMEOUT` / `RECLAIM_TIMEOUT` | `120` / `1800` | Wall-clock bounds. |
| `DELETE_FROM_ICLOUD` | `1` | 0 makes this a one-way copier. |
| `KEEP_ICLOUD_DAYS` | `7` | Never delete anything newer than N days. 0 (or empty) reclaims as soon as a photo is confirmed. |
| `PRUNE_DEVICE_AFTER_UPLOAD` | `1` | Drop confirmed copies from the emulator. |
| `STOP_EMULATOR_WHEN_IDLE` | `1` | Stop the VM once drained and confirmed. |
| `GITHUB_TOKEN` | (unset) | Raises the release-lookup rate limit. Optional. |

Also read from the environment, never from the config: `AVD_RECREATE=1` (recreate
the emulator onto a newer API), `AVD_REROOT=1` (re-patch the ramdisk),
`PLAYSTORE_DONOR_API`, `DEV_TIMEOUT`, `BOOT_WAIT`, `AVD_APP_NAME`, `AVD_APP_DIR`,
`PHOTO_SYNC_APP_NAME`, `PHOTO_SYNC_APP_DIR`. **Nothing in the environment tells
the app where the commands are**, deliberately: whatever decides what the app
runs decides what inherits the app's privacy grants, so that answer lives in the
signed bundle's own Info.plist (below). The Windows tray app follows the same
rule with `PhotoSync.settings.json` beside its exe.

Every script exports `ANDROID_HOME`, `ANDROID_SDK_ROOT` (both `AVD_SDK_ROOT`)
and `ANDROID_AVD_HOME` (`AVD_HOME`) to every tool it runs, so an Android Studio
install already on the machine - its own `ANDROID_HOME`, its own SDK - is
ignored rather than half-used: avdmanager resolving the image against a
different SDK answers "Package path is not valid", and an emulator booting from
it boots an image this pipeline never rooted.

### Arming

`~/.config/avd-photos/ENABLED` - an empty file. Present means armed. Absent means
every sync tick exits immediately. `avd-photos-arm --yes` and `avd-photos-arm
--off` create and remove it; a configuration manager can do the same by touching
the file, which is deliberately the whole mechanism.

### Which emulator is ours

Every device call resolves the serial by asking each attached emulator its AVD
name (`adb -s <serial> emu avd name`) and matching `AVD_NAME`, then asserts it
again once the guest has booted. `emulator-5554` is only the first free console
port, so another emulator on the Mac owns it whenever it started first, and the
pushes, queries, prunes and `emu kill`s here would have gone to a stranger's
device. The Play Store donor VM is found by its own name the same way.

### State and ledgers

All under `~/.cache/avd-photos` (`AVD_PHOTOS_STATE_DIR`):

| File | What it holds |
| --- | --- |
| `pushed.list` | The ledger: staging-relative paths already pushed. Keyed on the relative path, so a staging move does not confuse it. |
| `reclaim-pending.list` | Confirmed by Google Photos, not yet deleted from iCloud. Fed ONLY by the prune step. |
| `reclaimed.list` | Deleted from iCloud, or found already gone. |
| `last-upload-confirmed` | Unix time of the last clean verify. **Its presence gates every iCloud deletion.** |
| `upload-status` | `<uploaded> <on-device> <failed> <written-at>` for the menu bar. |
| `device.id` | The emulator's `android_id`; a change resets the ledger. |
| `device-busy` | A batch is on the device between push and confirmation. |
| `phase` | The running step, or `failed: <why>` from the last run. Removed on a clean exit. |
| `sync.lock/pid`, `setup.lock/pid` | Single-flight locks (mkdir is the atomic test-and-set; macOS has no `flock`). On Windows each also records `winpid`, the Windows pid: an MSYS pid is visible only to bashes of the same Git installation, and a run from the user's own Git Bash would otherwise read the tray's live lock as stale. |
| `setup-complete` | Written only after the LAST setup phase succeeds. The login bootstrap keys on this. |
| `stamps/` | Release tags of the flashed modules (so a re-run re-flashes only when upstream moves) and `sha-<asset>-<tag>`, the sha256 that tag must keep producing. |
| `phonesky/` | The extracted Play Store APK. |
| `cmdline-tools-run/` | Windows only: the copy of `cmdline-tools/latest` the SDK tool runs from, so it can replace the original (see [the Windows traps](#the-windows-traps)). |

Logs are `~/.cache/avd-photos/logs/{sync,setup,reclaim,emulator,launcher}.log`,
each rotated by its own writer at 5 MB, plus `*.launchd.log` for the agents'
stderr (empty in normal operation).

The phase strings are an interface: the menu bar parses `pushing N of M`,
`indexing in MediaStore: N of M`, `verifying uploads: N of M confirmed`,
`reclaiming iCloud space: N ...`, `downloading ...` and `failed: <why>`.

### launchd agents

Labels are `com.ayushsharma.icloud-to-google-photos.<suffix>`:

| Suffix | When | What |
| --- | --- | --- |
| `.sync` | every 900 s + at load | `Photo Sync.app`'s binary with `--sync` (see "Staging"). Background band. |
| `.setup` | Saturday 05:30 | `avd-photos-setup --headless` - the update. |
| `.bootstrap` | at load | `avd-photos-setup --bootstrap` - builds or resumes; a no-op once complete. |
| `.app` | at load | `avd-photos-app` - rebuilds the Dock launcher so its icon follows the light/dark appearance. |
| `.menubar` | at load, KeepAlive | `Photo Sync.app`. Interactive band. |

Templates are in `launchd/`, with `__LABEL__`, `__BIN_DIR__`, `__APP_BIN__` and
`__LOG_DIR__` substituted by `install.sh`.

On Windows the same jobs are Task Scheduler tasks in the folder
`\icloud-to-google-photos\` (`AP_TASK_FOLDER` in `lib/config.sh`), registered by
`install.ps1` - see [Task Scheduler](#task-scheduler). There is no `.app` task:
the Start-menu shortcut has no appearance to follow.

### The app's CLI

`Photo Sync.app/Contents/MacOS/PhotoSync` handles exactly one argument before any
UI exists: **`--sync [args...]`**, which runs `avd-photos-sync` as its child and
waits, passing the arguments through and forwarding SIGTERM so the script's exit
trap runs. It spawns and waits, never `exec`s (`exec` would swap the image and
the identity with it), and it is handled before the first line that touches
AppKit, because `NSStatusBar.system` registers the process with LaunchServices as
a running copy of the app and the UI's single-instance sweep would then kill a
`--sync` parent mid-run.

**There is no general `--run`.** An earlier version had one, restricted to the
pipeline's own commands, and that restriction was worth nothing: it resolved
those commands through an environment variable the caller sets, so
`AVD_PHOTOS_BIN_DIR=/tmp/evil PhotoSync --run sh` ran an arbitrary script with
the app's privacy grants. Whatever decides WHAT the app runs decides what
inherits those grants, so that decision now ignores the environment entirely:
the scripts are looked for in the directory named by the bundle's own
`AVDPhotosBinDir` Info.plist key -- written by `build.sh --bin-dir`, which
`install.sh` passes, BEFORE the bundle is signed, so the seal covers it and a
non-standard `--prefix` is recorded where only an installer can put it -- then
`~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`.

That key replaced a `Contents/Resources/bin` symlink, which `codesign --verify
--strict` rejects outright ("invalid destination for symbolic link in bundle").
Worth knowing why that mattered: this bundle's identity is also its TCC identity,
so a seal that passes only the lax check is a privacy grant that can evaporate at
an OS update.

Bundle identifier: `local.ayushsharma.icloud-to-google-photos`.

The Windows app's CLI is in [its own section](#the-tray-apps-cli).

---

## Layout

```
bin/     avd-photos-setup      build and update the rooted emulator
         avd-photos-sync       the sync job
         avd-photos-reclaim.py the iCloud deletion, run by the sync
         avd-photos-status     the JSON the menu bar reads
         avd-photos-app        the Dock launcher for Google Photos in the emulator
         avd-photos-config     write and inspect the configuration
         avd-photos-arm        arm / disarm
         avd-photos-offload    reclaim iCloud space now
         avd-photos-check      report every version, change nothing
         avd-start avd-stop avd-signin
lib/     config.sh  log.sh  proc.sh  fs.sh
         os.sh                 every macOS/Windows difference, in one place
Sources/ main.swift (the menu-bar app)  icon.swift (its artwork, drawn at build time)
build.sh          builds Photo Sync.app with swiftc; no Xcode project
install.sh        commands, app, agents; --uninstall
launchd/          the five agent templates

install.ps1       Windows: its own tools, command shims, tray app, tasks; -Uninstall
install.cmd       double-clickable install.ps1 (bypasses the execution policy)
windows/build.ps1 builds the tray app with a private .NET SDK, self-contained
windows/PhotoSync/ the tray app, WinUI 3 on the Windows App SDK:
         Program.cs (CLI, single instance)  App.xaml.cs (collect, paint, act)
         Status.cs (the menu-bar app's state machine, ported)  Ring.cs (the ring)
         TrayIcon.cs (Shell_NotifyIcon)  FlyoutWindow.xaml(.cs)  Pipeline.cs
```

The ring in the menu bar started life inside a personal menu-bar app called
Claude Meter; this project ships its own, and nothing here depends on that one.

---

## Licence

MIT. See [LICENSE](LICENSE).

The pieces this stands on are other people's: `icloudpd`, Magisk, NeoZygisk, the
GPhotosUnlimited module, the Vector Xposed framework and PixelifyPhotos, and
Google's own emulator and system images. Nothing here redistributes any of them -
each is fetched from its own upstream at run time, and the Play Store comes out
of Google's own certified image rather than any third-party mirror.
