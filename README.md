# icloud-to-google-photos

An unattended pipeline that moves an iCloud photo library into Google Photos and
then reclaims the iCloud space, on a Mac, with no taps.

Every fifteen minutes it downloads new originals from iCloud with
[icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader),
pushes them into a rooted Android emulator whose device fingerprint is spoofed to
a Pixel, waits for Google Photos to actually upload them, checks each upload
against Google Photos' own database, and only then deletes those exact photos
from iCloud. A menu-bar ring shows which stage the current batch is in.

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
and the iCloud reclaim is gated on it, so a pipeline that breaks stops reclaiming
on the very next run rather than quietly eating a photo library.

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
- skips anything newer than `KEEP_ICLOUD_DAYS`;
- **reads the server's answer.** icloudpd's own `delete_photo` posts and logs
  "Deleted" without checking the response; one deletion in fourteen came back
  with the asset still in the library. This sends the identical request and
  accepts only a record with `isDeleted=1` and no `serverErrorCode`. A rejected
  deletion stays pending and is retried on the next run;
- treats a pending path with no asset in the library as "already gone" - the safe
  direction, since a wrong match can only leave a photo in iCloud.

iCloud keeps a deleted asset in Recently Deleted for 30 days, where it still
counts against the quota until it expires or the album is emptied by hand.

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
`/Applications`, writes the default config if there is none, and loads the five
launchd agents. Options: `--prefix`, `--app-dir`, `--copy`, `--no-agents`,
`--no-app`, `--uninstall`.

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
6. `avd-photos-arm` - **arms it.** From here the pipeline runs on its own.

### The one-time human steps

Four, and no automation can do any of them:

- **The Apple ID session for icloudpd** (step 2 above). Two-factor, interactive,
  once per Mac.
- **The Google sign-in inside the emulator** (step 4), in software GL.
- **The uncertified-device registration**, once per Google account, with the
  device id from GMS' `Checkin.xml` - not from the GSF provider, which answers
  "No result found" here. If sign-in still fails afterwards, force a check-in
  with `adb -s emulator-5554 shell am broadcast -a android.server.checkin.CHECKIN`
  and try again.
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
avd-start / avd-stop              # the emulator, with the right flags
avd-signin                        # the emulator in software GL, for sign-in
avd-photos-app                    # rebuild the Dock launcher and its icon
```

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

## Config and state contract

Everything a configuration manager needs in order to drive this without editing
the scripts.

### Config file

`~/.config/avd-photos/config`, shell syntax, sourced by every script. Precedence
is **environment > config file > default**. `AVD_PHOTOS_CONFIG_DIR`,
`AVD_PHOTOS_STATE_DIR` and `AVD_PHOTOS_LOG_DIR` are environment-only, since they
decide where the config is read from in the first place.

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
| `KEEP_ICLOUD_DAYS` | (unset) | Never delete anything newer than N days. |
| `PRUNE_DEVICE_AFTER_UPLOAD` | `1` | Drop confirmed copies from the emulator. |
| `STOP_EMULATOR_WHEN_IDLE` | `1` | Stop the VM once drained and confirmed. |
| `GITHUB_TOKEN` | (unset) | Raises the release-lookup rate limit. Optional. |

Also read from the environment, never from the config: `AVD_RECREATE=1` (recreate
the emulator onto a newer API), `AVD_REROOT=1` (re-patch the ramdisk),
`PLAYSTORE_DONOR_API`, `DEV_TIMEOUT`, `BOOT_WAIT`, `AVD_APP_NAME`, `AVD_APP_DIR`,
`PHOTO_SYNC_APP_NAME`, `PHOTO_SYNC_APP_DIR`, `AVD_PHOTOS_BIN_DIR` (where the app
looks for the scripts; the agents set it).

### Arming

`~/.config/avd-photos/ENABLED` - an empty file. Present means armed. Absent means
every sync tick exits immediately. `avd-photos-arm` and `avd-photos-arm --off`
create and remove it; a configuration manager can do the same.

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
| `sync.lock/pid`, `setup.lock/pid` | Single-flight locks (mkdir is the atomic test-and-set; macOS has no `flock`). |
| `setup-complete` | Written only after the LAST setup phase succeeds. The login bootstrap keys on this. |
| `stamps/` | Release tags of the flashed modules, so a re-run re-flashes only when upstream moves. |
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

### The app's CLI

`Photo Sync.app/Contents/MacOS/PhotoSync` handles two arguments before any UI
exists:

- `--sync [args...]` runs `avd-photos-sync` as its child and waits, passing the
  arguments through and forwarding SIGTERM so the script's exit trap runs.
- `--run <program> [args...]` does the same for anything else.

Both spawn and wait, never `exec`: `exec` would swap the image and the identity
with it. They are handled before the first line that touches AppKit, because
`NSStatusBar.system` registers the process with LaunchServices as a running copy
of the app and the UI's single-instance sweep would then kill a `--run` parent
mid-sync.

Bundle identifier: `local.ayushsharma.icloud-to-google-photos`. It resolves the
scripts through `AVD_PHOTOS_BIN_DIR`, then `~/.local/bin`, `/usr/local/bin`,
`/opt/homebrew/bin`.

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
