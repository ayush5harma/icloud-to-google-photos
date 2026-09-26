# icloud-to-google-photos

An unattended pipeline that moves an iCloud photo library into Google Photos and
then reclaims the iCloud space, on a Mac, with no taps.

Every fifteen minutes it downloads new originals from iCloud with
[icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader),
hands them to a Google Photos that uploads them as a 2016 Pixel would, waits for
Google to actually confirm each one, and only then deletes those exact photos
from iCloud. A menu-bar ring shows which stage the current batch is in.

The Pixel is the only interesting part: Google Photos gives original-quality
backup, with no counting against Google One storage, to a 2016 Pixel. There are
two ways to be one, and the Mac's CPU picks:

- **Apple silicon: Google Photos for iPhone and iPad, running natively on the
  Mac.** The App Store IPA, converted to a Mac app by
  [ipa-install-on-mac](https://github.com/ayush5harma/ipa-install-on-mac), with
  the [Gunshot](https://github.com/tqmane/gunshot) tweak inside it: Gunshot's
  GoToHP engine uploads through Google's own API with a Pixel XL profile, and
  this project's `ios/gp-bridge.m` feeds that engine from a folder. No
  emulator, no root, no device registration, a 30-second run for a small batch.
- **Intel: a rooted Android emulator** whose device fingerprint is spoofed to a
  Pixel by a Magisk module, with Google Photos for Android backing up from its
  camera folder. An Intel Mac cannot run an iOS app, so this is its only path.

Everything else here exists to make that reliable and to make sure nothing
leaves iCloud before it is provably somewhere else.

**Read "What this actually is" before installing.** Either way this is a spoof
of a device Google no longer sells, backing up photographs you probably cannot
re-take. It is built to fail safe, but it is not a product.

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

### On Apple silicon: Google Photos for Mac

```
  iCloud ──icloudpd──> staging dir ──cp──> ~/Pictures/Google Photos Upload/
                                                        │
                                       gp-bridge (inside Google Photos):
                                       begin / append / seal into GoToHP
                                                        │
                                          GoToHP uploads, Google replies
                                          with a media key per item
                                                        │
                                   ledger.json: name -> state, media key
                                                        │
                                              delete from iCloud
```

1. **`icloudpd` first**, exactly as below.
1. **Ask before uploading.** Every staged file the ledger has not seen is
   looked up in Google Photos' **own** database first
   (`~/Library/Containers/com.google.photos/.../store/photos-<accountId>.db`,
   copied with its `-wal` and `-shm` once per run and read from the copy --
   never the live file). `ServerPhotos` holds one row per item Google has,
   keyed by `localDedupKey` = `base64url(sha1(the file's bytes))` without
   padding, 27 characters. A file with a row is **already backed up**: it is
   recorded with that media key, put on the reclaim list and never uploaded.
   A row carrying a **tombstone** does not count: a photo deleted in Google
   Photos keeps its `ServerPhotos` row, and without that exclusion the file
   would answer "present" and its iCloud original would be deleted too -- gone
   from both sides. More than one account database on the Mac is an unknown
   rather than a choice, since nothing local says which account the app is
   signed into now.
   A Live Photo is one item at Google, keyed by the still's bytes, so only the
   still is hashed and its answer carries the `.MOV` beside it: for
   `IMG_1234_HEVC.MOV`, icloudpd's own Live Photo name, the stem is the
   evidence; for a bare `IMG_1234.MOV`, which is also what a standalone video
   is called, the two files must share an mtime as well, because iPhone
   filenames recycle and a stem match alone would pair a video with an
   unrelated photo.
   This matters most for a library some other device already backed up: this
   backend confirms from the reply to its own upload, so without the check it
   cannot tell, and hands the whole library over again for Google to discard
   one file at a time. Measured on a 4,346-file staging tree: 3,207 of them
   (73.8%) needed no upload at all.
   **Unknown is never "present"**: no database, no sha1, or a staging file
   whose bytes a cloud folder has not materialised all mean "upload it", and a
   run bounded by `PRESENCE_BUDGET` hands over whatever it did not reach.
   `PRESENCE_CHECK=0` turns the whole thing off.
2. **Hand over** every staged file the Mac ledger has not seen, up to
   `PUSH_CAP` and `MAC_INBOX_MAX` waiting at once: a copy (`cp -p`, so the
   photo keeps its date, which becomes the item's timestamp) written under a
   dot-name and renamed into place, named after the staged path
   (`2026/05/IMG_2885.HEIC` -> `2026_05_IMG_2885.HEIC`) so the ledger maps every
   name back exactly. The staging tree is never touched. A staged file a
   cloud folder has evicted to an online-only placeholder is first fetched by
   a read bounded per file (`MAC_HYDRATE_TIMEOUT`) and per run
   (`MAC_HYDRATE_BUDGET`), because reading a stub has no timeout of its own;
   one still a placeholder afterwards waits for the next run. The log line
   counts both (`hydrated N`, `evicted-skipped N`).
3. **Google Photos is launched in the background** (`open -g`) if it is not
   running and there is something to hand over or to wait for; a tick with
   nothing new and nothing waiting is one listing and one read of the
   bridge's ledger, and never launches it. The bridge inside it scans the folder every 3 s, waits for a file's
   inode to be quiet for 5 s, pairs a Live Photo's still and video by stem, and
   imports each item into the engine, which uploads it with the Pixel XL
   original-quality profile. The engine uploads only while the app has a
   visible window and a network; the menu bar says so when it cannot.
4. **Verify.** The engine's job state, read through `.bridge/ledger.json`. A
   file is confirmed when its job **completed with a media key** - the reply
   of Google's own commit call - and the bridge moves it to `Uploaded/`. The
   sync records the confirmation, puts the staged path on the reclaim list, and
   deletes the moved copy. A job the engine gave up on lands in `Failed/`; the
   sync hands the file over again on a later run, three times, then leaves it.
   A handoff the bridge never picked up - no entry in its ledger six hours
   later: a copy that never settled, a folder emptied by hand - counts as
   one of those failures and is handed over again; a job the bridge does
   hold is the engine's however long it takes, since it uploads one item at
   a time and only while the app is visible and online. A file that used up
   its three tries is left alone and counted in the menu bar's **Given up**
   row; `avd-photos-sync --retry-given-up` is the only way back in.
   `remote_live_photo_component_exists` - Google already holds one half of a
   Live Photo pair, by hash - is neither: the pair's row reads `exists` and
   it stays in iCloud, because which half matched is not reported.
5. **Reclaim iCloud space** for exactly the confirmed paths, the same step as
   the emulator's.

**Duplicates.** The engine fingerprints every import (sizes and content
hashes): a second drop of the same bytes is cancelled and the first job's
result is used. Google deduplicates by content on its side too: forcing bytes
it already holds came back with the *same* media key, not a second item. A
file the emulator path had already confirmed is not re-sent at all: the first
Mac run marks everything on the reclaim lists as handled.

**Install it with `gphotos-mac-setup`** (the login agent does; `--check`
reports): it downloads the IPA named by `GPHOTOS_IPA_URL` - Google Photos
7.92.0 with `GunshotJailed.dylib` injected, a release asset of this repo -
verifies `GPHOTOS_IPA_SHA256`, and runs `ipa-install-on-mac <ipa> --dylib
ios/gp-bridge.m`. A reinstall keeps the sign-in. The app runs in the sandbox
the converter gives every iOS app - its own container, the standard user
folders (Pictures, Downloads, Movies, Music) and the devices an iOS app may ask
for, each behind macOS's usual prompt - and the bridge only ever touches the
upload folder. Then open it once and sign in to Google; that is the whole
human part.

### On Intel: the rooted emulator

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

#### The keep list

Confirmed in Google Photos is not the same as safe to lose from iCloud, so
before anything is deleted the asset is asked four more questions. Any one of
them keeps it, and the reason is logged and written to
`~/.cache/avd-photos/keep-set.tsv` (record id, reason, staged path; rewritten
each run, dry runs included, for the reports to read):

- **a favourite** - `isFavorite` on the CloudKit asset record;
- **in an album you made** - read from the server's own folder list rather than
  from pyicloud's album dict, which is keyed by NAME: two albums called the
  same thing collapse to one entry there and the shadowed album's members lose
  this protection silently (measured on a real library: five albums, two of
  them both "App Icons", four entries in the dict). Smart albums (Favorites,
  Live, Videos, Screenshots, Bursts, Panoramas, Slo-mo, Time-lapse, Hidden,
  Recently Deleted) are not part of the rule at all. Name albums in
  `KEEP_ICLOUD_ALBUMS_EXCLUDE` to stop them counting;
- **saved into the library by another app** - what Photos shows as "Recently
  Saved". That album is *not* exposed over CloudKit, but the signal behind it
  is: every master record carries `importedBy` and
  `importedByBundleIdentifierEnc` (`com.apple.camera`, `com.apple.MobileSMS`,
  `net.whatsapp.WhatsApp`, `com.apple.sharingd`, ...), and anything whose
  importer is not the device camera counts. `KEEP_ICLOUD_SAVED_FROM_APPS=0`
  turns it off - worth knowing that on a library fed by Messages or WhatsApp
  this rule alone can keep most of it;
- **added to the library within `KEEP_ICLOUD_ADDED_DAYS`** (default 30). The
  older `KEEP_ICLOUD_DAYS` floor reads the *capture* date, which says nothing
  about how long the asset has been here: a photo re-imported from Google
  Photos arrives with a years-old capture date and is past any capture-date
  floor on its first day.

**A read that fails keeps the asset**, and says which read: an album listing
that raises, an importer lookup that errors, a record with no `isFavorite` or
no `addedDate`. The direction of every doubt here is "leave it in iCloud".

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

### Messages as a second source (off by default)

iCloud Photos is not the only place originals pile up. On the Mac this was built
for, `~/Library/Messages/Attachments` held 1,435 attachment rows and 3.17 GB by
the database's own sizes; the first real scan, on 2026-09-20, took the media
among them: **1,171 image and video attachments, 1.96 GB on disk, of which 97
videos carried 1.24 GB** -- 8 % of the files and 63 % of the bytes. Of those
1,161 new attachments, **19 were already in Google Photos** and the other 1,142
were backed up nowhere at all, so deleting a conversation took them with it.

`MESSAGES_SOURCE=1` turns on a scan that runs between the iCloud download and
the upload backend, so what it stages goes up in the same tick:

1. **Read a copy of `chat.db`**, taken with its `-wal` and `-shm` together. The
   live file is never opened: Messages holds it open in WAL mode, so the `.db`
   alone is a stale view, and a writer-shaped open of the live file is how a
   Messages database gets corrupted. Only ids are read -- `attachment.guid`, the
   file path, the date, `chat.ROWID` and `chat.chat_identifier`. Never
   `message.text`, never `chat.display_name`.
2. **Take images and videos only**, by extension (`heic heif jpg jpeg png gif
   webp mov mp4 m4v`). `pluginPayloadAttachment` (219 files here: rich links and
   stickers), `.caf` audio and documents are skipped by name.
3. **Hash each new file and ask `gp_present` first.** An attachment Google Photos
   already holds -- usually the same photo, sent from the phone that also backs
   it up -- is recorded as confirmed and never staged, so the common case costs
   one hash and no bytes.
4. **Stage the rest** at `<staging>/messages/YYYY/MM/<8 hex of sha1>-<its own
   name>`, where the normal upload path finds them with no other change. The
   `messages/` prefix also keeps them out of the iCloud reclaim's reach: it
   rebuilds candidate paths as `YYYY/MM/<name>`, which no `messages/...` path can
   equal, so a Messages attachment can never cause an iCloud deletion.

The ledger is `messages-state.tsv`, keyed by the attachment's GUID **and** the
SHA-1 of its bytes, so a re-scan never re-stages; it carries the size too, so a
15-minute tick skips a known attachment before reading it rather than hashing
2 GB again. `MESSAGES_BUDGET` (300 s) bounds what one tick spends on the files
it does not yet know -- the first scan of a large Messages library takes as
many ticks as it needs, and a file is only ever recorded once it is dealt
with.

**Full Disk Access is the prerequisite**, and a process without it gets EPERM on
the folder itself -- which is indistinguishable from "no such folder" unless you
keep stderr, which this does. An unreadable folder logs one line and the tick
carries on: a Messages source that failed a photo sync would be a bad trade.

The menu bar shows this source on its own **Messages** rows, apart from the
photo sync: `Attachments  <n> synced`, `skipped: needs Full Disk Access` or
`off`. The sync runs as a child of `Photo Sync.app`, so that app is what needs
the grant; when the scan was refused, **Grant Full Disk Access…** opens that
pane of Privacy & Security and reveals the app in Finder to add. A `Backup` row
beside it reads system-config's Messages backup from
`~/.local/state/system-config/messages-backup.json` when that file exists.

**Nothing in Messages is ever modified or deleted by this.**

### The two reports

Both are rewritten on every tick into `MESSAGES_REPORT_DIR` (or, where
`/etc/system-config/paths.env` exists, that host's own Drive under
`[01] Personal/[05] Media & Chats/Messages Backup`; where neither resolves, the
reports are skipped with one log line rather than a folder being invented).

| Report | What it is for |
| --- | --- |
| `messages-cleanup-report.md` | Per conversation, the attachments CONFIRMED in Google Photos, videos listed one by one with their dates and photos summarised per month -- the list to work through by hand in Messages. A staged-but-unconfirmed attachment is named as waiting, never as deletable. |
| `gphotos-duplicates-report.md` | The account's own library grouped by `localDedupKey` (`base64url(SHA-1(bytes))`, Google's content fingerprint): groups with two or more copies, the excess copies and what they cost, by month -- the list to work through by hand in Google Photos. 8,186 groups and 11,599 excess copies on the account this was measured against. |

Neither deletion has a safe programmatic path -- Apple ships no supported way to
delete a Messages attachment, and this pipeline has no Google Photos deletion
path at all -- so both reports exist to be acted on by a human, and both say so
in their own first paragraph.

**Identifiers only**, because these land in a synced folder: a chat id, a handle
id (a phone number, an email or a group id), a date, a size and eight hex
characters of a content hash. No contact name, no message text and no file name;
a file staged as `<hash>-<its own name>` is reported by its hash alone.

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

The other side of the bytes leaving the disk is that a file Drive has already
uploaded is an online-only placeholder by the time the handoff reaches it
(measured 2026-09-26: a whole 4,371-file backlog). The handoff fetches each one
back with a bounded read before copying it (a 68 KB photo took 1.97 s), up to
the run's cap and within `MAC_HYDRATE_BUDGET`, and never reads a placeholder
without a bound.

Those reads can be refused outright: the same day, the launchd-run sync had
every one refused ("Operation not permitted") until `Photo Sync.app` was given
**Full Disk Access**, while a terminal that had it read the same files. The
first refusal now stops the reading for that run, with one log line naming
the grant, and the menu shows `Staging  cannot read cloud files: needs Full
Disk Access` and a **Grant Full Disk Access…** action.

---

## Requirements

- **macOS 14 or newer.** Apple silicon runs Google Photos for Mac; Intel runs
  the emulator (`x86_64` image; the tuning defaults assume roughly 8 cores and
  16 GB).
- **Apple silicon: Xcode** (the bridge is compiled for Mac Catalyst against the
  macOS SDK, which the Command Line Tools alone do not carry), and about 600 MB
  of disk for the app.
- **Intel: Xcode Command Line Tools** (`xcode-select --install`) for `swiftc`.
  Full Xcode is optional: with it, the app icon gets light and dark variants
  through `actool`; without it, a light-only `.icns`.
- **Intel: Android SDK command-line tools** - `sdkmanager` on PATH is enough to
  bootstrap. Everything else (the emulator, platform-tools, the system image) is
  downloaded by `avd-photos-setup` into its own writable SDK root. It must be
  writable: rooting rewrites `ramdisk.img` in place.
- **`uv` and `icloudpd`**: `uv tool install icloudpd`.
- **`jq`, `curl`, `python3`** (`python3` is macOS's own), and `sqlite3` (macOS
  ships it).
- **A Google account** you are willing to sign in to on a modified Google
  Photos, and an **Apple ID** for icloudpd.
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
3. `avd-photos-setup` - on Apple silicon this is `gphotos-mac-setup`: it
   downloads and installs Google Photos for Mac in about a minute. On Intel it
   builds the whole rooted stack. That is long (a multi-GB system image, a
   rooted ramdisk, three reboots, and the Play Store extraction) and resumable:
   the "done" marker is written only after the last phase succeeds, so an
   interrupted build resumes at the next login rather than declaring victory.
4. Sign in. Apple silicon: `avd-start` opens Google Photos for Mac; sign in to
   Google in it. Intel: `avd-signin` boots the emulator in software GL. Open
   Google Photos, sign in, and register the device id the setup printed at
   <https://www.google.com/android/uncertified/> as that same account. Turn
   Backup ON and confirm the backup screen says `Quality: Original`.
5. `avd-photos-check` - reports what is installed (on Intel: Magisk, Zygisk,
   the spoof module, Google Photos and the Play Store), and changes nothing.
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
dim and the menu says so. The dropdown carries the ledger (staged, backlog,
verified, iCloud freed, last run, and the backend's own rows: uploading, given
up and the Google Photos app's state on the Mac backend; on device and the
emulator's state on the emulator), the live phase line of a running sync,
"Check iCloud now", and "Offload from iCloud" - which is offered only once a
batch has actually been confirmed, because it deletes from the real photo
library. The menu shows only one backend's rows: the one the collector reports,
or, before its first answer, `PHOTOS_BACKEND` from the config file, else the
host default (Apple silicon: the Mac backend).

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

| Key | Default | What it is |
| --- | --- | --- |
| `ICLOUD_USERNAME` | (unset) | Apple ID for icloudpd. The sync refuses to run without it. |
| `ICLOUDPD` | `icloudpd` | The icloudpd command. |
| `STAGING` | `~/Pictures/icloud-photos-staging` | Where originals land and wait for confirmation. |
| `ICLOUD_DIR` | `~/Library/Mobile Documents/com~apple~CloudDocs` | iCloud Drive root; only the default parent of `SHARED_CACHE_DIR`. |
| `SHARED_CACHE_DIR` | `$ICLOUD_DIR/avd-photos` | Where the extracted Play Store APK is cached so a second Mac skips a 2.7 GB extraction. |
| `GOOGLE_ACCOUNT` | (unset) | The account the emulator signs in as. Only ever printed. |
| `PHOTOS_BACKEND` | `mac` on arm64, `avd` otherwise | `mac` = Google Photos for Mac (Apple silicon only); `avd` = the emulator. |
| `GPHOTOS_APP` | `/Applications/GooglePhotos.app` | Where `gphotos-mac-setup` installs the app (named after the IPA's bundle by the converter). |
| `GPHOTOS_IPA_URL` / `GPHOTOS_IPA_SHA256` | this repo's release asset | The IPA to install and the hash it must have. |
| `IPA_INSTALL` | `ipa-install-on-mac` | The converter; fetched at a pinned revision when not on PATH. |
| `MAC_INBOX_MAX` | `300` | Files waiting in the upload folder at once (the engine keeps a second copy of each while it uploads). |
| `MAC_HYDRATE_TIMEOUT` / `MAC_HYDRATE_BUDGET` | `120` / `600` | Seconds per file, and per run in all, spent fetching online-only staged files before handing them over. `MAC_HYDRATE_TIMEOUT=0` skips them unread. |
| `PRESENCE_CHECK` | `1` | Look a staged file up in Google Photos' own database before uploading it. 0 uploads everything as before. |
| `PRESENCE_BUDGET` | `300` | Seconds per run spent on that lookup (it reads each candidate's bytes). Whatever it does not reach is handed over as usual. |
| `AVD_NAME` | `gphotos-tablet` | The emulator's name. |
| `AVD_SDK_ROOT` | `~/.local/share/android-avd-sdk` | The pipeline's own writable SDK root (its `ANDROID_HOME`). |
| `AVD_ABI` / `AVD_TAG` / `AVD_DEVICE` | `arm64-v8a` on arm64, `x86_64` otherwise / `google_apis` / `pixel_tablet` | Image selection. `google_apis_playstore` is deliberately unusable here. |
| `AVD_RES` / `AVD_DPI` | `2560x1440` / `210` | Density decides which Photos layout renders; above ~384dpi it flips to the phone UI. |
| `AVD_RAM` / `AVD_CORES` / `AVD_DISK` / `AVD_HEAP` | `6144` / `8` / `16384M` / `512M` | Guest tuning. |
| `AVD_GPU` | `host` | `host` for speed; `swiftshader_indirect` is the only mode that renders Google's sign-in. |
| `AVD_SPOOF` | `module` | `module` = GPhotosUnlimited; `vector` = Vector + PixelifyPhotos. Never both. |
| `DEST_DCIM` | `/sdcard/DCIM/Camera` | Where files are pushed. Any other folder is opt-in for backup and will silently never upload. |
| `RECENT` / `UNTIL_FOUND` | `2000` / `50` | icloudpd's incremental walk. |
| `PUSH_CAP` | `1000` | Files handed to Google Photos per run. |
| `UPLOAD_WAIT` | `900` | Floor on the wait for Google Photos, plus 2 s per file on the device. |
| `ADB_TIMEOUT` / `RECLAIM_TIMEOUT` | `120` / `1800` | Wall-clock bounds. |
| `DELETE_FROM_ICLOUD` | `1` | 0 makes this a one-way copier. |
| `KEEP_ICLOUD_DAYS` | `7` | Never delete anything newer than N days. 0 (or empty) reclaims as soon as a photo is confirmed. |
| `KEEP_ICLOUD_ADDED_DAYS` | `30` | Never delete an asset ADDED to the library within N days (`addedDate`, not the capture date). 0 turns it off. |
| `KEEP_ICLOUD_ALBUMS_EXCLUDE` | (empty) | Album names that are not a reason to keep their members, one per line or comma-separated. |
| `KEEP_ICLOUD_SAVED_FROM_APPS` | `1` | Keep anything another app saved into the library (Photos' "Recently Saved"). 0 turns it off. |
| `PRUNE_DEVICE_AFTER_UPLOAD` | `1` | Drop confirmed copies from the emulator. |
| `STOP_EMULATOR_WHEN_IDLE` | `1` | Stop the VM once drained and confirmed. |
| `GITHUB_TOKEN` | (unset) | Raises the release-lookup rate limit. Optional. |
| `MESSAGES_SOURCE` | `0` | 1 scans Messages attachments and stages new images and videos (needs Full Disk Access). |
| `MESSAGES_DIR` / `MESSAGES_DB` | `~/Library/Messages/Attachments` / `~/Library/Messages/chat.db` | What that scan reads. The database is always copied, with its `-wal` and `-shm`, and never opened in place. |
| `MESSAGES_BUDGET` | `300` | Seconds the scan may spend reading new attachments per tick; what it does not reach waits for the next one. 0 removes the bound. |
| `MESSAGES_REPORT_DIR` | (unset) | Where the two reports go. Empty follows `SC_PATHS_ENV`'s `SC_MY_DRIVE`, and skips the reports when that resolves to nothing. |
| `SC_PATHS_ENV` | `/etc/system-config/paths.env` | A declared-paths file to read `SC_MY_DRIVE` from. Read as data, never sourced. |

Also read from the environment, never from the config: `AVD_RECREATE=1` (recreate
the emulator onto a newer API), `AVD_REROOT=1` (re-patch the ramdisk),
`PLAYSTORE_DONOR_API`, `DEV_TIMEOUT`, `BOOT_WAIT`, `AVD_APP_NAME`, `AVD_APP_DIR`,
`PHOTO_SYNC_APP_NAME`, `PHOTO_SYNC_APP_DIR`. **Nothing in the environment tells
the app where the commands are**, deliberately: whatever decides what the app
runs decides what inherits the app's privacy grants, so that answer lives in the
signed bundle's own Info.plist (below).

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
| `reclaim-pending.list` | Confirmed by Google Photos, not yet deleted from iCloud. Fed by the prune step and by the presence check. |
| `mac-present.tsv` | `<staged path>\t<media key>\t<when>` for every file the presence check found Google already had. Kept out of `mac-state.tsv`, which the menu bar reads and the logs quote. |
| `keep-set.tsv` | The last reclaim's keep set: record id, the rule that kept it, the staged path. Rewritten each run, dry runs included. |
| `reclaimed.list` | Deleted from iCloud, or found already gone. |
| `last-upload-confirmed` | Unix time of the last clean verify. **Its presence gates every iCloud deletion.** |
| `upload-status` | `<uploaded> <on-device> <failed> <written-at>` for the menu bar. |
| `device.id` | The emulator's `android_id`; a change resets the ledger. |
| `device-busy` | A batch is on the device between push and confirmation. |
| `messages-state.tsv` | The Messages source's ledger: guid, sha1, state (`staged`/`present`), stamp, staged path, chat id, handle id, date, bytes, kind. Keyed by guid+sha1. |
| `staging-access` | `<epoch>\t<ok\|denied>\t<reason>` from the last handoff that read an online-only staged file; `avd-photos-status` reports it as `staging_access`. |
| `messages-status` | `<epoch>\t<ok\|skipped>\t<ledger rows>\t<reason>` from the last Messages scan; `avd-photos-status` reports it as its `messages` object. |
| `phase` | The running step, or `failed: <why>` from the last run. Removed on a clean exit. |
| `sync.lock/pid`, `setup.lock/pid` | Single-flight locks (mkdir is the atomic test-and-set; macOS has no `flock`). |
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

---

## Layout

```
bin/     gphotos-mac-setup     install and update Google Photos for Mac (Apple silicon)
         avd-photos-setup      build and update the rooted emulator (Intel; on
                               Apple silicon it runs gphotos-mac-setup)
         avd-photos-sync       the sync job
         avd-photos-reclaim.py the iCloud deletion, run by the sync
         avd-photos-status     the JSON the menu bar reads
         avd-photos-app        the Dock launcher for Google Photos in the emulator
         avd-photos-config     write and inspect the configuration
         avd-photos-arm        arm / disarm
         avd-photos-offload    reclaim iCloud space now
         avd-photos-check      report every version, change nothing
         avd-start avd-stop avd-signin
lib/     config.sh  log.sh  proc.sh  fs.sh  mac.sh (the Mac backend of the sync)
         presence.sh  is this file already in Google Photos? (gp_present)
         messages.sh  the Messages source     reports.sh  the two reports
test/    mac.sh       the Mac backend's bookkeeping, on a scratch state
         presence.sh  the presence check, on a fixture database
         keep.py      the reclaim's keep list, on fixtures
         messages.sh  the Messages source, on a fixture chat.db
         reports.sh   the two reports, on a fixture ledger and database
         menu.sh      the menu's rows per backend (compiles Sources/model.swift)
ios/     gp-bridge.m  the folder-to-GoToHP bridge linked into Google Photos for Mac
Sources/ main.swift (the menu-bar app)  model.swift (its ledger and backend, no AppKit)
         icon.swift (its artwork, drawn at build time)
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
GPhotosUnlimited module, the Vector Xposed framework and PixelifyPhotos, Google's
own emulator and system images, and on Apple silicon the
[Gunshot](https://github.com/tqmane/gunshot) tweak (GPL-3.0, itself built on
[gotohp](https://github.com/xob0t/gotohp), MIT) and
[ipa-install-on-mac](https://github.com/ayush5harma/ipa-install-on-mac).
The emulator path redistributes none of them: each is fetched from its own
upstream at run time, and the Play Store comes out of Google's own certified
image rather than any third-party mirror. The Mac path's IPA is published as a
release of this repo because `gphotos-mac-setup` needs one fixed, hash-checked
file; it is Google's binary with Gunshot's dylib inside, and `GPHOTOS_IPA_URL`
points anywhere else you would rather host it.
