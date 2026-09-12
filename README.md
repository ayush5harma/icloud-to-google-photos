# icloud-to-google-photos

An unattended pipeline that moves an iCloud photo library into Google Photos and
then reclaims the iCloud space, on a Mac, with no taps.

Every fifteen minutes it downloads new originals from iCloud with
[icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader),
pushes them into a rooted Android emulator whose device fingerprint is spoofed to
a Pixel, waits for Google Photos to actually upload them, checks each upload
against Google Photos' own database, and only then deletes those exact photos
from iCloud. A menu-bar ring shows which stage the current batch is in.

It runs on Windows 11 too -- the same pipeline, config and ledgers, driven by
Task Scheduler and a tray icon instead of launchd and the menu bar. See
[Windows](#windows).

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

This section and the four after it are the Mac's; Windows has its own under
[Windows](#windows).

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

---

## Windows

The same pipeline on Windows 11: the same icloudpd pass, the same rooted
emulator with the same spoof, the same `dedup_key` verification against Google
Photos' own database, and the same per-file, gated iCloud reclaim -- run by
`bin/avd-photos-reclaim.py` itself, unchanged. The config keys, ledgers, state
files, phase strings and status JSON are the same, so "How it works" above and
"Config and state contract" below hold on both platforms. What changes is the
machinery around it: PowerShell 7 scripts in `windows\` instead of bash, Task
Scheduler instead of launchd, a tray icon instead of the menu bar, and an
`x86_64` system image instead of `arm64-v8a`. Every Windows-specific decision
and the reason for it is in [`windows/DESIGN.md`](windows/DESIGN.md).

**Where the port stands.** It was written on a Mac and is checked on real
Windows by CI (`windows-latest`: every PowerShell file, the scheduled tasks as
Task Scheduler reads them back, the process and quoting rules, the reclaim
script's import path). No hosted runner can boot an Android emulator, so the
emulator, the Magisk patch, the Google sign-in and a real upload have not yet
run on Windows. "First run on Windows" at the end of this section says what to
watch and what to paste back if a step fails.

### Requirements (Windows)

- **Windows 11 on x64, with hardware virtualisation.** VT-x or AMD-V on in the
  firmware, and the **Windows Hypervisor Platform** feature, which the emulator
  uses (WHPX). In an elevated PowerShell:
  `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All`,
  then reboot. The alternative accelerator, AEHD, works only with Hyper-V and
  virtualisation-based security off. Windows on Arm is untested.
- **PowerShell 7.4 or newer**: `winget install Microsoft.PowerShell`. Every
  command below runs in `pwsh`, not in Windows PowerShell 5.1 or cmd.
- **A JDK 17 or newer** for the Android SDK tools: `winget install Microsoft.OpenJDK.21`.
- **Git** (`winget install Git.Git`): for the clone, and because the reclaim
  runs against icloudpd's source at the installed version, which uv fetches
  with git.
- **uv and icloudpd**: `winget install astral-sh.uv`, then `uv tool install icloudpd`.
- **Nothing else.** The setup downloads the Android command-line tools
  (checked against the SHA-1 and size in Google's own repository manifest),
  the emulator, platform-tools (adb) and the system image into the pipeline's
  own SDK root. There is no `sqlite3` to install: Google Photos' database is
  read with Python's `sqlite3` under the same uv.
- About **16 GB of RAM** (the guest takes 6 GB) and **30 GB of disk**, plus
  the staging tree at its peak.
- **ASCII-only paths** for the SDK root and the AVD directory: the emulator
  mishandles anything else, and the setup refuses such a path by name rather
  than failing somewhere obscure (see Troubleshooting).

### Install (Windows)

```powershell
git clone https://github.com/ayush5harma/icloud-to-google-photos
cd icloud-to-google-photos
.\windows\install.ps1
```

`install.ps1` puts `windows\bin` on your user PATH, writes the default config
if there is none (readable by you and SYSTEM only, the Windows form of 0600),
creates two Start Menu shortcuts ("Photo Sync" and "Google Photos (AVD)"),
registers four scheduled tasks and starts the tray. Options: `-Copy` (a
self-contained copy under `%LOCALAPPDATA%\avd-photos\app`, so the checkout can
be deleted), `-NoTasks`, `-NoTray`, `-VisibleConsole` (see Troubleshooting),
`-Uninstall`. Run it as yourself, not as administrator: the tasks run as the
user who registers them. If you downloaded the repository as a ZIP rather than
cloning it, run `Get-ChildItem -Recurse | Unblock-File` in it first.

**Nothing syncs yet.** The sync task is registered but every tick exits
immediately until you arm it.

Then, in a **new** PowerShell 7 window (so the PATH change applies), in order:

1. `avd-photos-config` - check the config; set `ICLOUD_USERNAME`, and
   `STAGING` if you want it somewhere other than
   `%USERPROFILE%\Pictures\icloud-photos-staging`. The file is
   `%APPDATA%\avd-photos\config`; on Windows it is read, not executed, so a
   path with spaces needs no quotes (see the contract below).
2. `icloudpd --username <your apple id> --directory "<staging>" --recent 1` -
   the one-time interactive Apple login, including two-factor. It also stores
   the password in Windows Credential Manager, which is what lets a later
   unattended run re-authenticate when the session expires.
3. `avd-photos-setup` - builds the whole rooted stack, exactly as on macOS
   (long, several GB, resumable; the "done" marker is written only after the
   last phase succeeds).
4. `avd-signin` - boots the emulator in software GL. Open Google Photos, sign
   in, and register the device id the setup printed at
   <https://www.google.com/android/uncertified/> as that same account. Turn
   Backup ON and confirm the backup screen says `Quality: Original`.
5. `avd-photos-check` - reports Magisk, Zygisk, the spoof module, Google
   Photos and the Play Store, and changes nothing.
6. `avd-photos-offload -DryRun` - which photos the reclaim would match in your
   library, without deleting anything.
7. `avd-photos-arm` - prints exactly what arming switches on, then stops.
   `avd-photos-arm -Yes` **arms it**. `avd-photos-arm -Off` disarms.

### The one-time human steps (Windows)

The macOS four, minus the file-provider grant (Windows has no per-app gate on
a cloud folder), plus the hypervisor:

- **The Windows Hypervisor Platform feature**, once per machine, as
  administrator, with a reboot (Requirements above).
- **The Apple ID session for icloudpd** (step 2). Two-factor, interactive.
- **The Google sign-in inside the emulator** (step 4), in software GL.
- **The uncertified-device registration**, once per Google account, with the
  device id from GMS' `Checkin.xml` (the setup prints it; `avd-photos-check`
  reports it while the emulator runs). If sign-in still fails afterwards,
  force a check-in with `adb -s <serial> shell am broadcast -a android.server.checkin.CHECKIN`,
  where `<serial>` is the `device:` line of `avd-photos-check`, and try again.

### Monitoring (Windows)

**The tray** shows the same ring as the menu bar, in the same colours for the
same states (a neutral spin while iCloud downloads, yellow on the device, blue
while Google Photos confirms, purple while iCloud space is reclaimed, a green
check when everything is confirmed, orange or red with an exclamation when
the pipeline has stopped tracking reality, dim when not armed). A tray icon
cannot draw a count beside itself, so the count the Mac shows next to the ring
is in the icon's tooltip. Its menu carries the same ledger, the live phase,
"Check iCloud now" and "Offload from iCloud" (offered only once a batch has
been confirmed). "Quit Photo Sync" stays quit until the next logon, or until
you open "Photo Sync" from the Start Menu.

**The command line** (PowerShell 7):

```powershell
avd-photos-status | ConvertFrom-Json | Select-Object -ExpandProperty backup
Get-Content -Wait "$env:LOCALAPPDATA\avd-photos\logs\sync.log"
avd-photos-check
avd-photos-arm -Status
Get-ScheduledTask -TaskName 'com.ayushsharma.icloud-to-google-photos.*' |
    Get-ScheduledTaskInfo | Format-Table TaskName, LastRunTime, LastTaskResult, NextRunTime
```

**Actions:**

```powershell
avd-photos-offload             # reclaim iCloud space now (still gated on a confirmed batch)
avd-photos-offload -DryRun     # what WOULD leave iCloud; deletes nothing
avd-start; avd-stop            # the emulator, with the right flags
avd-signin                     # the emulator in software GL, for sign-in
avd-photos-app -Open           # what the "Google Photos (AVD)" shortcut runs
```

The same redaction note applies before you paste a log anywhere: `sync.log`
names your Apple ID and `reclaim.log` carries photo filenames and dates.

### Uninstall (Windows)

```powershell
.\windows\install.ps1 -Uninstall
```

Removes the four scheduled tasks, stops the tray, takes the commands off your
PATH (only the entry the installer added), removes a `-Copy` install and the
two Start Menu shortcuts. It deliberately leaves your config, the ledgers, the
logs, the staging tree, the emulator and the SDK root in place, and prints
where each of them is.

### Troubleshooting (Windows)

**The setup stops at "no hardware acceleration".** The Windows Hypervisor
Platform feature is off, or virtualisation is off in the firmware. Check with
`& "$env:LOCALAPPDATA\android-avd-sdk\emulator\emulator.exe" -accel-check`.

**The setup refuses a path with non-ASCII characters in it.** Usually the
user name. Move both the AVD directory and the SDK root to ASCII paths: set
`ANDROID_AVD_HOME` for your user (`[Environment]::SetEnvironmentVariable('ANDROID_AVD_HOME', 'C:\avd', 'User')`),
put `AVD_SDK_ROOT=C:\android-avd-sdk` in the config, and open a new window.

**`java` is not found, or `sdkmanager` fails at once.** Install the JDK
(Requirements) and open a new window.

**The log says `icloudpd has NO SAVED SESSION`**, or icloudpd's own output
says `None of providers gave password`. Run the interactive login from step 2.
On Windows the unattended run asks icloudpd for the keyring password only,
never the console: Windows' `getpass()` reads the keyboard rather than stdin,
so a console prompt in a scheduled task would wait forever while holding the
sync lock.

**A console window flashes every 15 minutes, or the tasks never start.** The
background tasks run under `conhost.exe --headless`, which is undocumented.
If `LastTaskResult` above is not 0 or the tasks never run, reinstall with
`.\windows\install.ps1 -VisibleConsole`, which runs them as a hidden `pwsh`
(a brief flash per run, but nothing undocumented).

**"Sign in" does nothing.** GPU mode, as on macOS: use `avd-signin`, not
`avd-start`.

**Pushes fail for some files, and the log mentions a long path.** `adb.exe`
cannot read a path longer than 260 characters. Use a shorter `STAGING`, or
enable long paths (as administrator:
`Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1`).

**The log counts files as "evicted-skipped".** They are cloud placeholders
(Google Drive streaming, OneDrive files on demand): reading one would make
Windows download it first, possibly for a long time, so they are skipped until
their bytes are local, as dataless files are on macOS.

**The emulator will not boot after rooting.** The original ramdisk is kept as
`ramdisk.img.backup` beside the patched one, under
`%LOCALAPPDATA%\android-avd-sdk\system-images\android-<API>\google_apis\x86_64\`;
restore it and re-run. The x86_64 ramdisk is the part of the Magisk patch no
Windows machine has run yet -- see "First run on Windows".

**`avd-photos-check` says `zygiskd not running`.** The spoof cannot inject
without it. To rule SELinux in or out, boot once by hand with it permissive
(`avd-stop`, then
`& "$env:LOCALAPPDATA\android-avd-sdk\emulator\emulator.exe" -avd gphotos-tablet -no-snapshot -selinux permissive`,
then `avd-photos-check`). If Zygisk runs permissive and not enforcing, the
one sepolicy rule the setup appends did not take: stop the emulator and re-run
`avd-photos-setup`. Do not leave it permissive -- the pipeline is built and
tested enforcing, on both platforms.

**Everything is slow.** Real-time antivirus scanning of the SDK and the AVD
directory costs the emulator dearly; excluding those two directories in
Windows Security is optional and needs administrator rights.

### What differs on Windows, and why

- **x86_64 images.** An x86 host runs x86_64 guests; the Magisk APK carries
  `lib/x86_64`, and the ramdisk is patched on the device exactly as on macOS
  (`magiskboot` has no Windows build, and the macOS setup never ran it on the
  host either). The on-device patch script is a byte-for-byte copy, and a test
  fails if the two ever differ.
- **No `-selinux permissive`, no `-writable-system`.** The macOS setup uses
  neither: SELinux stays enforcing with one sepolicy rule, and modules reach
  `/system` through Magisk's magic mount. Windows keeps that measured setup.
- **No app-bundle indirection.** The macOS sync runs as a child of Photo
  Sync.app because macOS gates a cloud folder per app. Windows has no such
  gate, so the task runs the script directly.
- **icloudpd runs with `--password-provider keyring`** (the getpass trap in
  Troubleshooting), and every Python child with `PYTHONUTF8=1`, so a filename
  outside the ANSI code page survives the ledgers and the reclaim's lists.
- **The Photos database is read with Python**, and the query travels in a
  file: a 1,000-file `IN (...)` list is about 55,000 characters, and a Windows
  command line stops at 32,767.
- **The config file is read, not sourced** (rules in the contract below).
- **Locks record the owner's start time as well as its pid**, because Windows
  reuses pids quickly enough to keep a stale lock alive.
- **The bootstrap task is not started at install** (launchd's RunAtLoad
  starts it at once on macOS): step 3 runs the same setup in front of you, and
  a background copy would only hold the lock against it.
- **Quit means quit** for the tray until the next logon; launchd's KeepAlive
  would relaunch it at once. A crash is still restarted a minute later.

### First run on Windows

What has been proven, and where:

| Proven | Where |
| --- | --- |
| Every PowerShell file parses; PSScriptAnalyzer is clean; the Pester suites pass | CI, `windows-latest` (and on macOS) |
| The four scheduled tasks as Task Scheduler reads them back: triggers, 15-minute repetition, battery, time limit, instances, logon type, priority | CI, `windows-latest` |
| The user PATH keeps its registry type; the config ACL is owner-only; `.bat` arguments survive `cmd.exe`; a timed-out process tree dies; the emulator launch is detached and logged | CI, `windows-latest` |
| `uv tool install icloudpd`, the version pin, and `bin/avd-photos-reclaim.py`'s imports under uv's Python 3.13 with `PYTHONUTF8=1` | CI, `windows-latest`, `ubuntu-latest`, `macos-latest` |
| A whole sync against a fake device and a real SQLite copy of the Photos tables, the reclaim gates, the status JSON, the tray's states and menu | Pester, on macOS and on `windows-latest` |

What a Windows user runs first, and what to paste back if it fails (redact
your Apple ID and filenames):

| Step | If it fails, paste back |
| --- | --- |
| Emulator boot (`avd-photos-setup`) | its console output; `& "$env:LOCALAPPDATA\android-avd-sdk\emulator\emulator.exe" -accel-check`; `Get-Content "$env:LOCALAPPDATA\avd-photos\logs\emulator.log" -Tail 60` |
| The Magisk patch on the x86_64 ramdisk | `Get-Content "$env:LOCALAPPDATA\avd-photos\logs\setup.log" -Tail 80`; `avd-photos-check` |
| NeoZygisk, the spoof, the Play Store | `avd-photos-check` |
| Google sign-in | whether the page renders under `avd-signin`; the device id from `avd-photos-check` |
| icloudpd's unattended re-authentication | `icloudpd --username <id> --directory "<staging>" --recent 1 --password-provider keyring --only-print-filenames` |
| The scheduled tasks actually running | `Get-ScheduledTask -TaskName 'com.ayushsharma.icloud-to-google-photos.*' \| Get-ScheduledTaskInfo \| Format-List` |
| A real upload confirmed and reclaimed | `avd-photos-status`; `Get-Content "$env:LOCALAPPDATA\avd-photos\logs\sync.log" -Tail 80`; `avd-photos-offload -DryRun`, then `reclaim.log` |

---

## Config and state contract

Everything a configuration manager needs in order to drive this without editing
the scripts.

### Config file

`~/.config/avd-photos/config`, shell syntax, sourced by every script, **0600**
(it holds an Apple ID and may hold a `GITHUB_TOKEN`; the installer tightens an
existing one). Precedence is **environment > config file > default**, decided by
whether the caller SET a variable rather than whether it is non-empty, so
`KEEP_ICLOUD_DAYS= avd-photos-sync` means "no floor for this run" and beats a
value in the config file exactly as an empty value in the config file beats the
default. `AVD_PHOTOS_CONFIG_DIR`, `AVD_PHOTOS_STATE_DIR` and `AVD_PHOTOS_LOG_DIR`
are environment-only, since they decide where the config is read from in the
first place.

**On Windows** the file is `%APPDATA%\avd-photos\config`, with the same keys
and the same precedence, but it is **read, not sourced**: `KEY=value` per line,
the value is the rest of the line (so `STAGING=C:\Users\John Smith\Pictures`
needs no quotes), backslashes are literal, `'...'` is taken as written, and
`$NAME`, `${NAME}` and `%NAME%` expand anywhere else. A line the parser cannot
use is reported by `avd-photos-config` and in the logs rather than dropped.
cmd cannot create an empty environment variable (`set KEY=` deletes it), so
there the way to say "no floor for this run" is `KEEP_ICLOUD_DAYS=0`. The file
is readable by its owner and SYSTEM only, the Windows form of 0600.

| Key | Default | What it is |
| --- | --- | --- |
| `ICLOUD_USERNAME` | (unset) | Apple ID for icloudpd. The sync refuses to run without it. |
| `ICLOUDPD` | `icloudpd` | The icloudpd command. |
| `STAGING` | `~/Pictures/icloud-photos-staging` | Where originals land and wait for confirmation. |
| `ICLOUD_DIR` | `~/Library/Mobile Documents/com~apple~CloudDocs` | iCloud Drive root; only the default parent of `SHARED_CACHE_DIR`. |
| `SHARED_CACHE_DIR` | `$ICLOUD_DIR/avd-photos` | Where the extracted Play Store APK is cached so a second Mac skips a 2.7 GB extraction. |
| `GOOGLE_ACCOUNT` | (unset) | The account the emulator signs in as. Only ever printed. |
| `AVD_NAME` | `gphotos-tablet` | The emulator's name. |
| `AVD_SDK_ROOT` | `~/.local/share/android-avd-sdk` | The pipeline's own writable SDK root (its `ANDROID_HOME`). |
| `AVD_ABI` / `AVD_TAG` / `AVD_DEVICE` | `arm64-v8a` / `google_apis` / `pixel_tablet` | Image selection. `google_apis_playstore` is deliberately unusable here. |
| `AVD_RES` / `AVD_DPI` | `2560x1440` / `210` | Density decides which Photos layout renders; above ~384dpi it flips to the phone UI. |
| `AVD_RAM` / `AVD_CORES` / `AVD_DISK` / `AVD_HEAP` | `6144` / `8` / `16384M` / `512M` | Guest tuning. |
| `AVD_GPU` | `host` | `host` for speed; `swiftshader_indirect` is the only mode that renders Google's sign-in. |
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

The Windows defaults that differ, each for a platform reason
(`windows/DESIGN.md` has them):

| Key | Windows default | Why |
| --- | --- | --- |
| `STAGING` | `%USERPROFILE%\Pictures\icloud-photos-staging` | The Windows Pictures folder. |
| `ICLOUD_DIR` | `%USERPROFILE%\iCloudDrive` | Where iCloud for Windows mounts iCloud Drive. |
| `AVD_SDK_ROOT` | `%LOCALAPPDATA%\android-avd-sdk` | Machine-local, writable, never roamed. |
| `AVD_ABI` | `x86_64` | An x86 host runs x86_64 guests; arm64 images do not boot on it. |
| `AVD_CORES` | `4` | The macOS 8 is an M2 Pro's performance cores; a laptop guest with as many vCPUs as the host has cores starves it. |

The emulator's AVD directory is `%USERPROFILE%\.android\avd` unless
`ANDROID_AVD_HOME` (or `ANDROID_USER_HOME`) says otherwise; the Windows port
honours those, as the emulator does.

Also read from the environment, never from the config: `AVD_RECREATE=1` (recreate
the emulator onto a newer API), `AVD_REROOT=1` (re-patch the ramdisk),
`PLAYSTORE_DONOR_API`, `DEV_TIMEOUT`, `BOOT_WAIT`, `AVD_APP_NAME`, `AVD_APP_DIR`,
`PHOTO_SYNC_APP_NAME`, `PHOTO_SYNC_APP_DIR`. **Nothing in the environment tells
the app where the commands are**, deliberately: whatever decides what the app
runs decides what inherits the app's privacy grants, so that answer lives in the
signed bundle's own Info.plist (below).

### Arming

`~/.config/avd-photos/ENABLED` (Windows: `%APPDATA%\avd-photos\ENABLED`) - an empty file. Present means armed. Absent means
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

All under `~/.cache/avd-photos` (`AVD_PHOTOS_STATE_DIR`; on Windows
`%LOCALAPPDATA%\avd-photos`), with the same names and the same line formats on
both, so a ledger is portable: paths are staging-relative with `/` separators
on Windows too, which is also what the reclaim script compares against.

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
| `sync.lock/pid`, `setup.lock/pid` | Single-flight locks (mkdir is the atomic test-and-set; macOS has no `flock`). Windows adds `started` beside `pid`: the owner's start time, since Windows reuses pids quickly. |
| `setup-complete` | Written only after the LAST setup phase succeeds. The login bootstrap keys on this. |
| `stamps/` | Release tags of the flashed modules (so a re-run re-flashes only when upstream moves) and `sha-<asset>-<tag>`, the sha256 that tag must keep producing. |
| `phonesky/` | The extracted Play Store APK. |

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

### Scheduled tasks (Windows)

`windows\install.ps1` registers four tasks in the root of Task Scheduler's
library, named with the same labels:

| Suffix | When | What |
| --- | --- | --- |
| `.sync` | every 15 minutes + at logon | `avd-photos-sync.ps1` under `conhost --headless`. Below-normal priority. |
| `.setup` | Saturday 05:30 | `avd-photos-setup.ps1 -Headless` - the update. |
| `.bootstrap` | at logon | `avd-photos-setup.ps1 -Bootstrap` - builds or resumes; a no-op once complete. |
| `.tray` | at logon, restarted on failure | `avd-photos-tray.ps1`, Photo Sync. Normal priority. |

All of them run as you, with the Interactive logon type (a task that runs
"whether logged on or not" runs in session 0, where your Drive and iCloud
mounts and the Credential Manager entry are not visible), start and keep
running on battery, have no time limit, and never run twice at once. The
`.app` agent has no Windows twin: it rebuilt a Dock icon for the light/dark
appearance, and a Start Menu shortcut needs no rebuilding.

### The app's CLI

macOS only. `Photo Sync.app/Contents/MacOS/PhotoSync` handles exactly one argument before any
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
Sources/ main.swift (the menu-bar app)  icon.swift (its artwork, drawn at build time)
build.sh          builds Photo Sync.app with swiftc; no Xcode project
install.sh        commands, app, agents; --uninstall
launchd/          the five agent templates
windows/          the Windows port (PowerShell 7; see windows/DESIGN.md)
  install.ps1     commands on PATH, config, scheduled tasks, shortcuts; -Uninstall
  bin/            the same commands as bin/, as .ps1, plus avd-photos-tray.ps1
  lib/            the AvdPhotos module (Core, Setup, Sync, Status, Tray, Install)
                  and sqlite_query.py
  device/         patch-ramdisk.sh, byte-identical to the macOS setup's heredoc
  tests/          Pester and Python suites; Invoke-Checks.ps1 runs them all
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
