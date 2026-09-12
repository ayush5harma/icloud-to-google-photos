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
import argparse
import datetime
import json
import logging
import os
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--username", required=True)
    ap.add_argument("--staging", required=True)
    ap.add_argument("--pending", required=True, help="file: staging-relative paths confirmed in Google Photos")
    ap.add_argument("--out", required=True, help="file: staging-relative paths reclaimed (deleted or not found)")
    ap.add_argument("--cookie-dir", default=os.path.expanduser("~/.pyicloud"))
    ap.add_argument("--keep-days", type=int, default=0, help="never delete an asset created within N days")
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
        if keep_after is not None and photo.created > keep_after:
            stats["kept"] += 1
            log.info("KEPT %s: created within the last %d day(s)", hit, a.keep_days)
            remaining.discard(hit)
            continue
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
        remaining.discard(hit)
        for c in companions:
            remaining.discard(c)
        if not remaining:
            break

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
