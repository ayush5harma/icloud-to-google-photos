#!/usr/bin/env python3
# Delete from iCloud exactly the photos Google Photos has CONFIRMED, and nothing
# else. Run by avd-photos-sync after its verify + prune step, through the Python
# library that icloudpd is built from:
#
#   uv run --python 3.13 \
#     --with "icloudpd @ git+https://github.com/icloud-photos-downloader/icloud_photos_downloader@v<ver>" \
#     avd-photos-reclaim.py --username <apple id> --staging <dir> \
#       --pending <file of staging-relative paths> --out <file> [--dry-run] [--keep-days N]
#
# WHY A SEPARATE STEP: icloudpd's own --delete-after-download deletes each item
# the moment its bytes land in staging, hours before Google Photos has it, gated
# only on some EARLIER run having confirmed uploads -- offload before backup. The
# deletion itself is still icloudpd's: delete_photo() posts the same
# records/modify with isDeleted=1.
#
# WHY THE LIBRARY AND NOT THE TOOL: a `uv tool` icloudpd is a self-contained
# binary with nothing importable in it, so the sync pins the pure wheel to that
# binary's own version (`icloudpd --version`) and the two share the ~/.pyicloud
# session unchanged. With no valid session this fails fast (stdin is /dev/null,
# so the console MFA prompt raises): exit 2, nothing deleted.
#
# MATCHING. An asset is identified by the staging path icloudpd would have
# written for it, rebuilt with icloudpd's own functions: the created date in
# LOCAL time under the {:%Y/%m} folder structure, the cleaned filename (unicode
# stripped, the default), and the name-size dedup suffix ("-<size>" before the
# extension) as a second candidate. A Live Photo is ONE asset with two staged
# files (IMG_1234.HEIC + IMG_1234_HEVC.MOV); it is deleted only when every staged
# companion is confirmed, else HELD for a later run. A pending path with no asset
# in the library is reported not-found and counts as reclaimed (there is nothing
# left to delete) -- the safe direction: a wrong match can only leave a photo in
# iCloud, never remove one that is not confirmed.
#
# FILENAME MATCHING IS NOT CONFIRMATION, which is why nothing here decides what
# to delete: of 1,525 files Google Photos had confirmed by dedup_key, 444 had a
# remote row with the same name and size, 109 the name only, and 972 no row by
# name at all -- Google Photos keeps its own names. The pending list comes from
# the dedup_key join in the sync, and only from there.
#
# THE SERVER'S ANSWER IS CHECKED. icloudpd's delete_photo posts and logs
# "Deleted" without reading the response; one of 14 deletions came back with the
# asset still in the library while the log said Deleted. delete_asset below sends
# the identical request and accepts only a response whose record carries
# isDeleted=1 and no serverErrorCode; anything else is an error, the path stays
# pending, and the next run (a fresh walk, a fresh recordChangeTag) tries again.
#
# THE KEEP LIST. "Google Photos has it" is not the same as "iCloud may lose it".
# Before anything is deleted, four questions are asked of the asset itself, and
# any one of them keeps it:
#
#   favourite      _asset_record["fields"]["isFavorite"], which CloudKit carries
#                  on every CPLAsset and pyicloud already asks for.
#   album          a member of an album a human made. lib.albums is the smart
#                  albums (PhotoLibrary.SMART_FOLDERS: Favorites, Live, Videos,
#                  Screenshots, Bursts, Panoramas, Slo-mo, Time-lapse, Hidden,
#                  Recently Deleted) plus one entry per real album, so the user
#                  albums are exactly what is left after those names are
#                  removed. Members match the walk by CPLAsset recordName
#                  (measured 2026-09-20 on the real library: 5 of 5 and 11 of
#                  11 matched).
#   saved-from-app what Photos shows as "Recently Saved". THAT ALBUM IS NOT
#                  EXPOSED OVER CLOUDKIT -- it is not among the smart albums
#                  above and not among the albums the server returns -- but the
#                  signal behind it is: every CPLMaster carries importedBy and
#                  importedByBundleIdentifierEnc (measured: com.apple.camera,
#                  com.apple.MobileSMS, net.whatsapp.WhatsApp, com.openai.chat,
#                  com.apple.sharingd, com.google.photos). Anything whose
#                  importer is not the device camera counts as saved from an
#                  app. pyicloud's own desiredKeys leave those fields out, so
#                  they are fetched with a batched records/lookup of the master
#                  records -- unrestricted, which is what returns them.
#   added-grace    added to the LIBRARY within N days: _asset_record's addedDate,
#                  never assetDate. The existing --keep-days floor is measured
#                  from the capture date and says nothing about how long the
#                  asset has been here: a photo re-imported from Google Photos
#                  arrives with a years-old capture date and would be past any
#                  capture-date floor on its first day in the library.
#
# A READ THAT FAILS KEEPS THE ASSET. An album listing that raises, a master
# lookup that errors, a record with no isFavorite or no addedDate: each of them
# keeps the asset and says which read failed. The rule everywhere in this file
# is that the safe direction is the one that leaves a photograph in iCloud.
#
# COLLECT, THEN DECIDE, THEN DELETE, in three passes rather than one: the album
# listing is one walk per album however many assets are pending, and the master
# lookups go 50 at a time instead of one request per candidate. It also means a
# --dry-run can report the whole keep set without a single delete being one
# branch away.
import argparse
import base64
import datetime
import json
import logging
import os
import sys
from pathlib import Path

# The bundle identifier of the device camera. Everything else that put an asset
# into the library -- Messages, WhatsApp, AirDrop, a browser, Photos' own
# import -- counts as "saved from an app" and is what Photos groups under
# "Recently Saved".
CAMERA_BUNDLES = {"com.apple.camera", "com.apple.camera.CameraMessagesApp"}
# Master records per records/lookup call. CloudKit takes a list; 50 keeps the
# request small enough to retry cheaply and still costs one round trip per 50
# candidates instead of one per candidate.
LOOKUP_BATCH = 50


def _dec(v):
    """A CloudKit *Enc field: base64 of UTF-8. None when there is nothing."""
    if not v:
        return None
    try:
        return base64.b64decode(v).decode("utf-8", "replace")
    except Exception:
        return None


def user_albums(library):
    """Every album a human made, as (name, PhotoAlbum) pairs. A LIST, not a dict.

    pyicloud's own `library.albums` is keyed by NAME (photos.py:
    `albums[folder_name] = album`), so two albums called the same thing collapse
    to one entry and the shadowed one's members are invisible -- which here
    would mean they silently lose their "in an album you made" protection and
    could be deleted from iCloud. Measured on the real library 2026-09-20: five
    albums on the server, two of them both named "App Icons", and the dict held
    four. The same naming also lets a user album called "Videos" or "Favorites"
    replace the smart album of that name.

    So the folder list is read directly and each album is built the way
    pyicloud builds it, in the same order, skipping the two root containers and
    anything deleted. Smart albums are not in this list at all: membership of
    them is automatic and would keep the whole library.
    """
    from pyicloud_ipd.services.photos import PhotoAlbum

    out = []
    for name, folder_id in album_folders(library._fetch_folders()):
        out.append((name, PhotoAlbum(
            library.params, library.session, library.service_endpoint, name,
            "CPLContainerRelationLiveByAssetDate",
            f"CPLContainerRelationNotDeletedByAssetDate:{folder_id}",
            [{"fieldName": "parentId", "comparator": "EQUALS",
              "fieldValue": {"type": "STRING", "value": folder_id}}],
            zone_id=library.zone_id,
        )))
    return out


def album_folders(records):
    """(name, recordName) for every real album in a CPLAlbumByPositionLive list.

    The pure half of user_albums, so the filtering can be tested without an
    iCloud session: the two root containers and anything deleted are dropped,
    and a duplicated NAME is kept as its own entry -- that is the whole point.
    """
    out = []
    for folder in records:
        if folder.get("recordName") in ("----Root-Folder----", "----Project-Root-Folder----"):
            continue
        fields = folder.get("fields", {})
        if fields.get("isDeleted") and fields["isDeleted"].get("value"):
            continue
        enc = fields.get("albumNameEnc", {}).get("value")
        name = _dec(enc)
        if name is None:
            # A folder whose name cannot be read is still an album, and its
            # members still deserve keeping: raise rather than skip it, so the
            # caller records album_listing_failed and keeps everything.
            raise RuntimeError("an album's name could not be decoded: %r" % (folder.get("recordName"),))
        out.append((name, folder["recordName"]))
    return out


def keep_reason(
    photo,
    album_members,
    album_error,
    importers,
    keep_added_days,
    now,
):
    """Why this asset must stay in iCloud, or None if nothing holds it.

    Pure: everything it needs has already been fetched. album_members is the
    set of CPLAsset recordNames in user albums (None when that listing could
    not be read at all), importers maps a master recordName to its bundle
    identifier or to the sentinel False when the lookup failed; a master this
    run did not ask about is simply absent and the rule does not apply.
    """
    rec = photo._asset_record
    fields = rec.get("fields", {})

    if album_error:
        return "album_listing_failed"

    fav = fields.get("isFavorite")
    if fav is None:
        return "favourite_field_missing"
    if fav.get("value"):
        return "favourite"

    if album_members is not None and rec.get("recordName") in album_members:
        return "album"

    master = photo._master_record.get("recordName")
    if master in importers:
        who = importers[master]
        if who is False:
            return "import_lookup_failed"
        if who is None:
            # The field is absent on a record we did ask about: unknown
            # provenance, so the asset is kept and the reason says so.
            return "import_field_missing"
        if who not in CAMERA_BUNDLES:
            return "saved_from_app"

    if keep_added_days > 0:
        try:
            added = photo.added_date
        except Exception:
            return "added_date_missing"
        if (now - added).days < keep_added_days:
            return "added_grace"

    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--username", required=True)
    ap.add_argument("--staging", required=True)
    ap.add_argument("--pending", required=True, help="file: staging-relative paths confirmed in Google Photos")
    ap.add_argument("--out", required=True, help="file: staging-relative paths reclaimed (deleted or not found)")
    ap.add_argument("--cookie-dir", default=os.path.expanduser("~/.pyicloud"))
    ap.add_argument("--keep-days", type=int, default=0, help="never delete an asset created within N days")
    ap.add_argument("--keep-added-days", type=int, default=0,
                    help="never delete an asset ADDED to the library within N days (addedDate, not the capture date)")
    ap.add_argument("--keep-album-exclude", action="append", default=[], metavar="NAME",
                    help="an album name that is not a reason to keep; repeatable")
    ap.add_argument("--keep-saved-from-apps", action="store_true",
                    help="keep anything another app saved into the library (Photos' \"Recently Saved\")")
    ap.add_argument("--keep-state", help="file: the run's keep set, rewritten each run, for the reports")
    ap.add_argument("--present", help="file: staged paths confirmed from Google Photos' own database, for the counts")
    ap.add_argument("--max-assets", type=int, default=0, help="stop walking after N assets (0 = whole library)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s", stream=sys.stderr)
    log = logging.getLogger("reclaim")

    from tzlocal import get_localzone
    from icloudpd.authentication import authenticator
    import urllib.parse
    from icloudpd.base import build_filename_cleaner, dummy_password_writter, lp_filename_concatinator
    from icloudpd.filename_policies import create_filename_builder
    from icloudpd.mfa_provider import MFAProvider
    from icloudpd.status import StatusExchange
    from pyicloud_ipd.file_match import FileMatchPolicy
    from pyicloud_ipd.raw_policy import RawTreatmentPolicy
    from pyicloud_ipd.utils import get_password_from_keyring
    from pyicloud_ipd.version_size import AssetVersionSize, LivePhotoVersionSize

    staging = Path(a.staging)
    pending = {ln.strip() for ln in Path(a.pending).read_text().splitlines() if ln.strip()}
    if not pending:
        print(json.dumps({"pending": 0, "walked": 0, "deleted": 0, "held": 0, "kept": 0,
                          "kept_by": {}, "would_delete": 0, "present_confirmed": 0,
                          "not_found": 0, "dry_run": a.dry_run}))
        return 0

    try:
        icloud = authenticator(
            log, "com",
            {"keyring": (get_password_from_keyring, dummy_password_writter)},
            MFAProvider.CONSOLE, StatusExchange(), a.username, lambda: None,
            None, a.cookie_dir, os.environ.get("CLIENT_ID"),
        )
    except Exception as e:  # no session, MFA needed, network: nothing is deleted
        log.error("authentication failed: %s", e)
        return 2
    library = icloud.photos

    def delete_asset(photo) -> None:
        url = f"{library.service_endpoint}/records/modify?{urllib.parse.urlencode(library.params)}"
        body = json.dumps({
            "atomic": True,
            "desiredKeys": ["isDeleted"],
            "operations": [{
                "operationType": "update",
                "record": {
                    "fields": {"isDeleted": {"value": 1}},
                    "recordChangeTag": photo._asset_record["recordChangeTag"],
                    "recordName": photo._asset_record["recordName"],
                    "recordType": "CPLAsset",
                },
            }],
            "zoneID": library.zone_id,
        })
        resp = library.session.post(url, data=body, headers={"Content-type": "application/json"})
        try:
            rec = resp.json()["records"][0]
        except Exception as e:
            raise RuntimeError(f"unexpected response ({resp.status_code}): {resp.text[:200]}") from e
        if rec.get("serverErrorCode") or rec.get("reason"):
            raise RuntimeError(f"{rec.get('serverErrorCode')}: {rec.get('reason')}")
        if rec.get("fields", {}).get("isDeleted", {}).get("value") != 1:
            raise RuntimeError(f"isDeleted not set in response: {json.dumps(rec)[:200]}")

    filename_builder = create_filename_builder(FileMatchPolicy.NAME_SIZE_DEDUP_WITH_SUFFIX, build_filename_cleaner(False))
    tz = get_localzone()
    keep_after = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=a.keep_days)) if a.keep_days > 0 else None

    remaining = set(pending)
    reclaimed: list[str] = []
    stats = {"pending": len(pending), "walked": 0, "deleted": 0, "held": 0, "kept": 0,
             "not_found": 0, "errors": 0, "dry_run": a.dry_run}
    # How many of the pending paths were confirmed from Google Photos' own
    # database rather than by an upload of ours (lib/presence.sh). Reported,
    # never acted on: the two kinds of confirmation are equally good evidence
    # that Google holds the bytes, and telling them apart is for the human
    # reading the dry run.
    if a.present:
        try:
            present_rels = {ln.split("\t")[0] for ln in Path(a.present).read_text().splitlines() if ln.strip()}
        except OSError:
            present_rels = set()
        stats["present_confirmed"] = len(pending & present_rels)
    kept_by: dict[str, int] = {}
    keep_set: list[tuple[str, str, str]] = []   # (CPLAsset recordName, reason, staged path)
    matched: list[tuple[object, str, list[str]]] = []

    # ── Pass 1: the walk. It matches pending paths to assets and decides
    # nothing that needs another request.
    for photo in library.all:
        stats["walked"] += 1
        if a.max_assets and stats["walked"] > a.max_assets:
            break
        try:
            created = photo.created.astimezone(tz)
        except (ValueError, OSError):
            created = photo.created
        date_path = "{:%Y/%m}".format(created)
        name = filename_builder(photo)
        stem, ext = os.path.splitext(name)
        candidates = [f"{date_path}/{name}"]
        try:
            size = photo.versions[AssetVersionSize.ORIGINAL].size
            candidates.append(f"{date_path}/{stem}-{size}{ext}")
        except Exception:
            pass
        hit = next((c for c in candidates if c in remaining), None)
        if hit is None:
            if not remaining:
                break
            continue
        # Live Photo companion: staged beside the still, confirmed separately.
        companions = []
        try:
            if LivePhotoVersionSize.ORIGINAL in photo.versions_with_raw_policy(RawTreatmentPolicy.AS_IS):
                for lp in {lp_filename_concatinator(name), f"{stem}.MOV"}:
                    rel = f"{date_path}/{lp}"
                    if (staging / rel).exists():
                        companions.append(rel)
        except Exception:
            pass
        unconfirmed = [c for c in companions if c not in pending]
        if unconfirmed:
            stats["held"] += 1
            log.info("HELD %s: companion not yet confirmed: %s", hit, ", ".join(unconfirmed))
            remaining.discard(hit)
            continue
        matched.append((photo, hit, companions))
        remaining.discard(hit)
        for c in companions:
            remaining.discard(c)
        if not remaining:
            break

    # ── Pass 2: the keep list. Every request it needs is made once, for the
    # whole candidate set, rather than once per asset.
    album_members: set[str] | None = None
    album_error = False
    excluded = {n.strip() for n in a.keep_album_exclude if n.strip()}
    if matched:
        try:
            album_members = set()
            for name, album in user_albums(library):
                if name in excluded:
                    continue
                n_before = len(album_members)
                for member in album:
                    album_members.add(member._asset_record["recordName"])
                log.info("album %r: %d member(s)", name, len(album_members) - n_before)
        except Exception as e:
            # KEEPS EVERYTHING. A listing that raised says nothing about which
            # assets are in an album, and "no albums" is indistinguishable from
            # "could not read the albums" unless this is recorded.
            album_error = True
            album_members = None
            log.error("album listing failed (%s: %s) — every candidate is KEPT this run", type(e).__name__, e)

    importers: dict[str, object] = {}
    if matched and a.keep_saved_from_apps and not album_error:
        # pyicloud's desiredKeys leave importedBy off the master record, so it
        # is fetched here: an unrestricted records/lookup returns every field.
        masters = []
        seen_masters = set()
        for photo, _hit, _c in matched:
            m = photo._master_record.get("recordName")
            if m and m not in seen_masters:
                seen_masters.add(m)
                masters.append(m)
        lurl = f"{library.service_endpoint}/records/lookup?{urllib.parse.urlencode(library.params)}"
        for i in range(0, len(masters), LOOKUP_BATCH):
            batch = masters[i:i + LOOKUP_BATCH]
            try:
                resp = library.session.post(
                    lurl,
                    data=json.dumps({"records": [{"recordName": m} for m in batch], "zoneID": library.zone_id}),
                    headers={"Content-type": "text/plain"},
                )
                got = resp.json()["records"]
            except Exception as e:
                log.error("importer lookup failed for %d master record(s) (%s: %s) — they are KEPT",
                          len(batch), type(e).__name__, e)
                for m in batch:
                    importers[m] = False
                continue
            for rec in got:
                name = rec.get("recordName")
                if not name:
                    continue
                if rec.get("serverErrorCode"):
                    importers[name] = False
                    continue
                importers[name] = _dec(rec.get("fields", {}).get("importedByBundleIdentifierEnc", {}).get("value"))
            for m in batch:            # a record the server did not answer for
                importers.setdefault(m, False)

    now = datetime.datetime.now(datetime.timezone.utc)
    to_delete = []
    for photo, hit, companions in matched:
        # The capture-date floor first: it is the oldest rule here and the one
        # the config has always had.
        if keep_after is not None and photo.created > keep_after:
            reason = "capture_grace"
        else:
            reason = keep_reason(photo, album_members, album_error, importers, a.keep_added_days, now)
        if reason:
            stats["kept"] += 1
            kept_by[reason] = kept_by.get(reason, 0) + 1
            keep_set.append((photo._asset_record.get("recordName", "?"), reason, hit))
            log.info("KEPT %s: %s", hit, reason)
            continue
        to_delete.append((photo, hit, companions))
    stats["kept_by"] = kept_by
    stats["would_delete"] = len(to_delete)

    # THE KEEP SET IS WRITTEN BEFORE THE FIRST DELETION, not after the last:
    # the caller kills this process at RECLAIM_TIMEOUT, pass 3 is the long part,
    # and the record of what was deliberately kept must survive that kill -- it
    # is what avd-photos-status reports from. Rewritten whole through a
    # temporary file so a reader never sees half of it. A DRY RUN WRITES IT
    # TOO: it records what would have been kept and cannot make anything look
    # reclaimed, which is the only thing --out is guarded against.
    if a.keep_state:
        try:
            tmp = a.keep_state + ".tmp"
            with open(tmp, "w") as f:
                f.write("# recordName\treason\tstagedPath  (run %d, dry_run=%d)\n"
                        % (int(now.timestamp()), 1 if a.dry_run else 0))
                for rn, reason, rel in keep_set:
                    f.write("%s\t%s\t%s\n" % (rn, reason, rel))
            os.replace(tmp, a.keep_state)
        except OSError as e:
            log.error("could not write the keep set to %s: %s", a.keep_state, e)

    # ── Pass 3: the deletions, and only what pass 2 left.
    for photo, hit, companions in to_delete:
        try:
            if a.dry_run:
                log.info("[DRY RUN] would delete %s (%s)", hit, photo.id)
            else:
                delete_asset(photo)
                log.info("Deleted %s in iCloud (%s)", hit, photo.id)
            stats["deleted"] += 1
            reclaimed.append(hit)
            reclaimed.extend(companions)
        except Exception as e:
            stats["errors"] += 1
            log.error("delete failed for %s: %s", hit, e)

    # What the walk never met is not in the library: nothing left to reclaim. A
    # small "walked" count is a small library, not a truncated walk -- one run
    # reported "walked 25, deleted 8, not_found 992" and the library really did
    # hold 19 assets, everything else having been reclaimed already.
    for rel in sorted(remaining):
        if rel in reclaimed:
            continue
        stats["not_found"] += 1
        log.info("NOT FOUND in iCloud (already gone): %s", rel)
        reclaimed.append(rel)

    # A DRY RUN WRITES NOTHING TO --out. The caller appends that file to its
    # reclaimed ledger and drops those paths from its pending list, so a dry
    # run's would-have-deleted paths landing there would record photos as
    # reclaimed while they are still in iCloud, and nothing would ever retry
    # them. The caller refuses a dry run's output as well; this is the other
    # half of that guard, at the only place that can be sure.
    if not a.dry_run:
        with open(a.out, "a") as f:
            for rel in reclaimed:
                f.write(rel + "\n")
    else:
        log.info("[DRY RUN] %d path(s) would have been recorded as reclaimed; --out not written",
                 len(reclaimed))
    print(json.dumps(stats))
    return 0 if stats["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
