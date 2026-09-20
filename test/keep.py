#!/usr/bin/env python3
# The keep list, judged on fixtures: keep_reason() out of avd-photos-reclaim.py
# against fake CloudKit records and a fake album membership set. No network, no
# iCloud session, nothing imported from icloudpd -- the predicate is pure on
# purpose, so the rule that decides whether a photograph may be deleted can be
# read and tested without an account.
#
# Usage: test/keep.py        (also: python3 test/keep.py)

import datetime
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "reclaim", os.path.join(HERE, "..", "bin", "avd-photos-reclaim.py"))
reclaim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reclaim)

NOW = datetime.datetime(2026, 9, 20, tzinfo=datetime.timezone.utc)
PASS = []
FAIL = []


def check(what, got, want):
    if got == want:
        PASS.append(what)
        print("  PASS  %s" % what)
    else:
        FAIL.append(what)
        print("  FAIL  %s (got %r, wanted %r)" % (what, got, want))


class Photo:
    """As much of pyicloud's PhotoAsset as the predicate touches."""

    def __init__(self, record_name="A1", master="M1", favorite=0,
                 added_days_ago=400, fields=None, added_raises=False):
        f = {"isFavorite": {"value": favorite}} if fields is None else fields
        self._asset_record = {"recordName": record_name, "fields": f}
        self._master_record = {"recordName": master, "fields": {}}
        self._added = NOW - datetime.timedelta(days=added_days_ago)
        self._added_raises = added_raises

    @property
    def added_date(self):
        if self._added_raises:
            raise KeyError("addedDate")
        return self._added


def reason(photo, members=frozenset(), album_error=False, importers=None, added_days=30):
    return reclaim.keep_reason(photo, members, album_error, importers or {}, added_days, NOW)


print("nothing holds it")
check("an ordinary old asset is deletable", reason(Photo()), None)

print("favourite")
check("a favourite is kept", reason(Photo(favorite=1)), "favourite")
check("isFavorite=0 is not a reason", reason(Photo(favorite=0)), None)
# THE FIELD ITSELF MISSING IS NOT "not a favourite": it is a read that did not
# answer, and an unanswered read keeps the asset.
check("a record with no isFavorite is kept, not assumed", reason(Photo(fields={})), "favourite_field_missing")

print("albums")
check("a member of a user album is kept", reason(Photo(record_name="A2"), members={"A2"}), "album")
check("a non-member is not", reason(Photo(record_name="A2"), members={"A9"}), None)
# An empty set means "listed, and in no album"; None means "not listed at all",
# which only happens when the rule is off -- a listing that FAILED sets the
# error flag instead.
check("no album listing at all is not a reason", reason(Photo(), members=None), None)
check("a failed album listing keeps everything", reason(Photo(), album_error=True), "album_listing_failed")
check("and it outranks every other rule", reason(Photo(favorite=1), album_error=True), "album_listing_failed")

print("saved from another app (Photos' \"Recently Saved\")")
check("the device camera is not 'saved from an app'",
      reason(Photo(), importers={"M1": "com.apple.camera"}), None)
check("WhatsApp is", reason(Photo(), importers={"M1": "net.whatsapp.WhatsApp"}), "saved_from_app")
check("Messages is", reason(Photo(), importers={"M1": "com.apple.MobileSMS"}), "saved_from_app")
check("the Messages camera is still the camera",
      reason(Photo(), importers={"M1": "com.apple.camera.CameraMessagesApp"}), None)
check("a lookup that failed keeps it", reason(Photo(), importers={"M1": False}), "import_lookup_failed")
check("a record with no importer field keeps it", reason(Photo(), importers={"M1": None}), "import_field_missing")
check("a master nobody asked about is simply not in the rule",
      reason(Photo(master="M9"), importers={"M1": "net.whatsapp.WhatsApp"}), None)

print("the added-to-the-library grace")
# THE POINT OF THIS RULE: a photo re-imported from Google Photos carries its
# original capture date, so a capture-date floor is already past on its first
# day here. This one is measured from addedDate.
check("added yesterday is kept", reason(Photo(added_days_ago=1)), "added_grace")
check("added 29 days ago is kept", reason(Photo(added_days_ago=29)), "added_grace")
check("added 30 days ago is not (the window is N days, not N+1)", reason(Photo(added_days_ago=30)), None)
check("added 400 days ago is not", reason(Photo(added_days_ago=400)), None)
check("0 days turns the rule off", reason(Photo(added_days_ago=0), added_days=0), None)
check("an unreadable addedDate keeps it", reason(Photo(added_days_ago=1, added_raises=True)), "added_date_missing")

print("precedence")
check("favourite before album", reason(Photo(record_name="A2", favorite=1), members={"A2"}), "favourite")
check("album before saved-from-app",
      reason(Photo(record_name="A2"), members={"A2"}, importers={"M1": "net.whatsapp.WhatsApp"}), "album")
check("saved-from-app before the added grace",
      reason(Photo(added_days_ago=1), importers={"M1": "net.whatsapp.WhatsApp"}), "saved_from_app")

print("albums: the folder list, not pyicloud's name-keyed dict")
# MEASURED ON THE REAL LIBRARY 2026-09-20: five albums on the server, two of
# them both called "App Icons". pyicloud keys its album dict by NAME, so it
# held four and one album's members were invisible -- and an invisible album
# means its members silently lose their "in an album you made" protection.


def folder(rn, name, deleted=False):
    import base64
    f = {"recordName": rn, "fields": {}}
    if name is not None:
        f["fields"]["albumNameEnc"] = {"value": base64.b64encode(name.encode()).decode()}
    if deleted:
        f["fields"]["isDeleted"] = {"value": 1}
    return f


recs = [
    folder("----Root-Folder----", None),
    folder("----Project-Root-Folder----", None),
    folder("A", "WhatsApp"),
    folder("B", "App Icons"),
    folder("C", "App Icons"),
    folder("D", "Old", deleted=True),
]
check("both albums of one name survive", reclaim.album_folders(recs),
      [("WhatsApp", "A"), ("App Icons", "B"), ("App Icons", "C")])
check("the root containers are not albums", [n for n, _ in reclaim.album_folders(recs)].count("WhatsApp"), 1)
try:
    reclaim.album_folders([folder("E", None)])
    check("an unreadable album name raises rather than vanishing", "did not raise", "raised")
except RuntimeError:
    check("an unreadable album name raises rather than vanishing", "raised", "raised")

print("the *Enc decoder")
check("base64 of utf-8 decodes", reclaim._dec("bmV0LndoYXRzYXBwLldoYXRzQXBw"), "net.whatsapp.WhatsApp")
check("nothing decodes to nothing", reclaim._dec(None), None)
check("rubbish decodes to nothing rather than raising", reclaim._dec("!!!not base64!!!"), None)

print("%d passed, %d failed" % (len(PASS), len(FAIL)))
sys.exit(1 if FAIL else 0)
