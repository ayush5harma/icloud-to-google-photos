// Driver for test/menu.sh: compiled beside Sources/model.swift, it checks the
// rows the dropdown would show for each backend. Top-level code, so menu.sh
// copies it to a file named main.swift before compiling.

import Foundation

var pass = 0, fail = 0
func check(_ what: String, _ ok: Bool) {
    print("  \(ok ? "PASS" : "FAIL")  \(what)")
    if ok { pass += 1 } else { fail += 1 }
}
func labels(_ rows: [(String, String)]) -> [String] { rows.map { $0.0 } }

// ── Which backend ───────────────────────────────────────────────────────────
// The regression: with no report the menu assumed the emulator, so an Apple
// silicon Mac showed AVD rows before the first collection and whenever the
// collector failed.
check("no report, no config, arm64 -> mac",
      effectiveBackend(reported: nil, configText: nil, machine: "arm64") == .mac)
check("no report, no config, x86_64 -> avd",
      effectiveBackend(reported: nil, configText: nil, machine: "x86_64") == .avd)
check("the collector's report wins over the config and the host",
      effectiveBackend(reported: "avd", configText: "PHOTOS_BACKEND=mac\n", machine: "arm64") == .avd)
check("an unusable report falls through to the config",
      effectiveBackend(reported: "", configText: "PHOTOS_BACKEND=avd\n", machine: "arm64") == .avd)
check("an unreadable config falls back to the host",
      effectiveBackend(reported: "bogus", configText: nil, machine: "arm64") == .mac)

check("the written default's commented line is not an assignment",
      configBackend("# ── Google Photos for Mac ──\n#PHOTOS_BACKEND=mac\nICLOUD_USERNAME=a@b\n") == nil)
check("bare, quoted, single-quoted, export and trailing comment all read",
      configBackend("PHOTOS_BACKEND=avd") == .avd
      && configBackend("PHOTOS_BACKEND=\"avd\"") == .avd
      && configBackend("PHOTOS_BACKEND='avd'") == .avd
      && configBackend("  export PHOTOS_BACKEND=avd") == .avd
      && configBackend("PHOTOS_BACKEND=avd   # Intel") == .avd)
check("the last assignment wins, as when the file is sourced",
      configBackend("PHOTOS_BACKEND=avd\nPHOTOS_BACKEND=mac\n") == .mac)
check("a last assignment that is not a backend leaves the host default",
      configBackend("PHOTOS_BACKEND=mac\nPHOTOS_BACKEND=\n") == nil
      && configBackend("PHOTOS_BACKEND=mac\nPHOTOS_BACKEND=intel\n") == nil)
check("a similarly named key is not PHOTOS_BACKEND",
      configBackend("OLD_PHOTOS_BACKEND=avd\nPHOTOS_BACKEND_X=avd\n") == nil)

// ── Rows per backend ────────────────────────────────────────────────────────
let emulatorRows: Set = ["Emulator", "On device"]
let macRows: Set = ["Google Photos", "Uploading", "Given up"]

var s = Stats()
s.backend = "mac"; s.app = true; s.signedIn = true; s.appOnline = true
s.onDevice = 4; s.givenUp = 2; s.emulator = true   // a stray flag must not bring the emulator back
let mac = labels(ledgerRows(s, backend: .mac, haveStats: true))
check("mac: no emulator row of any kind", emulatorRows.isDisjoint(with: mac))
check("mac: Google Photos, Uploading and Given up are shown", macRows.isSubset(of: mac))

var a = Stats()
a.backend = "avd"; a.emulator = true; a.onDevice = 3; a.givenUp = 2
let avd = labels(ledgerRows(a, backend: .avd, haveStats: true))
check("avd: Emulator and On device are shown", emulatorRows.isSubset(of: avd))
check("avd: none of the Mac app's rows", macRows.isDisjoint(with: avd))

let before = labels(ledgerRows(Stats(), backend: .mac, haveStats: false))
check("before the first report: no device row claiming a state nobody observed",
      !before.contains("Google Photos") && !before.contains("Emulator"))
check("before the first report: the common ledger is still there",
      ["Staged", "Backlog", "Verified", "iCloud", "Last run"].allSatisfy(before.contains))

check("mac launcher names no emulator",
      uploaderLauncher(.mac, appPath: "/Applications/GooglePhotos.app")
          == ("Open Google Photos", "/Applications/GooglePhotos.app"))
check("avd launcher is the AVD Dock launcher",
      uploaderLauncher(.avd, appPath: "/x").path == "/Applications/Google Photos (AVD).app")

// ── Row text ────────────────────────────────────────────────────────────────
// The owner's menu read "Google Photorunning": the label was padded to 12 and
// String.padding truncates a longer one.
check("Google Photos keeps its s and a gap",
      ledgerLine("Google Photos", "running") == "Google Photos  running")
let lines = (ledgerRows(s, backend: .mac, haveStats: true) + ledgerRows(a, backend: .avd, haveStats: true))
    .map { (l, v) in (l, ledgerLine(l, v)) }
check("every label survives whole with at least two spaces before its value",
      lines.allSatisfy { l, line in line.hasPrefix(l + "  ") })
check("every value starts in the same column",
      Set(lines.map { l, line in line.dropFirst(l.count).prefix { $0 == " " }.count + l.count }).count == 1)
check("a label longer than the column is not truncated",
      ledgerLine("A very long label", "v") == "A very long label  v")

// ── Messages ────────────────────────────────────────────────────────────────
// Two sources shown apart from the photo sync: the pipeline's own scan of
// Messages attachments (the collector's "messages" object) and system-config's
// Messages backup (a JSON file it writes at every switch).
func value(_ rows: [(String, String)], _ label: String) -> String? { rows.first { $0.0 == label }?.1 }
let now = Date(timeIntervalSince1970: 1_790_000_000)
func iso(_ secondsAgo: Int) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    return f.string(from: now.addingTimeInterval(TimeInterval(-secondsAgo)))
}
func backup(_ json: String) -> MessagesBackup? { messagesBackup(Data(json.utf8)) }

let fda = messagesSource(["state": "skipped", "reason": "Operation not permitted", "count": 0, "age": 30])
check("the measured 2026-09-26 skip reads as needing Full Disk Access",
      fda?.state == .skipped && fda?.needsFullDiskAccess == true)
check("and its row says so, not macOS's words",
      value(messagesRows(source: fda, backup: nil, now: now), "Attachments") == "skipped: needs Full Disk Access · 30s ago")
check("the Grant Full Disk Access action is offered for it",
      offerFullDiskAccess(fda))
let denied = messagesSource(["state": "skipped", "reason": "Permission denied", "count": 4])
check("another skip keeps its own reason and offers no Full Disk Access",
      value(messagesRows(source: denied, backup: nil, now: now), "Attachments") == "skipped: Permission denied"
      && !offerFullDiskAccess(denied))
check("a skip with no reason still says it was skipped",
      value(messagesRows(source: messagesSource(["state": "skipped"]), backup: nil, now: now), "Attachments")
          == "skipped: see sync.log")
let okSource = messagesSource(["state": "ok", "reason": "", "count": 1161, "age": 60])
check("a scan that ran shows how many attachments are dealt with",
      value(messagesRows(source: okSource, backup: nil, now: now), "Attachments") == "1161 synced · 1m ago"
      && !offerFullDiskAccess(okSource))
check("the source off says off",
      value(messagesRows(source: messagesSource(["state": "off", "count": 0, "age": -1]), backup: nil, now: now),
            "Attachments") == "off")
check("an enabled source that has not scanned is not called ok",
      value(messagesRows(source: messagesSource(["state": "unknown"]), backup: nil, now: now), "Attachments")
          == "no scan reported yet")
check("a state this app does not know is unknown, not dropped",
      messagesSource(["state": "exploded"])?.state == .unknown)
check("a collector without a messages object shows no Attachments row",
      messagesSource(nil) == nil && messagesSource("x") == nil
      && value(messagesRows(source: nil, backup: nil, now: now), "Attachments") == nil)

check("no backup file: no Backup row, and no section at all",
      messagesBackup(nil) == nil && messagesRows(source: nil, backup: nil, now: now).isEmpty)
check("a backup file that is not JSON is unreadable",
      backup("{not json") == .unreadable && messagesBackup(Data()) == .unreadable)
check("JSON without a boolean ok is unreadable",
      backup(#"{"at":"2026-09-26T10:00:00Z"}"#) == .unreadable
      && backup(#"{"ok":"yes"}"#) == .unreadable && backup("[1,2]") == .unreadable)
check("and says so on its row",
      value(messagesRows(source: nil, backup: .unreadable, now: now), "Backup") == "unreadable")
let good = backup(#"{"ok":true,"at":"\#(iso(180))","reason":"","items":42,"dest":"/x"}"#)
check("a good backup reads ok with its age",
      value(messagesRows(source: nil, backup: good, now: now), "Backup") == "ok · 3m ago")
let bad = backup(#"{"ok":false,"at":"\#(iso(7200))","reason":"Drive not mounted","items":0}"#)
check("a failed backup names the reason and when",
      value(messagesRows(source: nil, backup: bad, now: now), "Backup") == "failed: Drive not mounted · 2.0h ago")
check("an offset, fractional seconds and a missing time all read",
      backup(#"{"ok":true,"at":"2026-09-26T15:30:00+05:30"}"#) == .ok(at: Date(timeIntervalSince1970: 1_790_416_800))
      && backup(#"{"ok":true,"at":"2026-09-26T10:00:00.250Z"}"#) != .unreadable
      && value(messagesRows(source: nil, backup: backup(#"{"ok":true}"#), now: now), "Backup") == "ok")
check("a failure with no reason is still a failure",
      value(messagesRows(source: nil, backup: backup(#"{"ok":false}"#), now: now), "Backup") == "failed")
check("the backup's own Full Disk Access trouble offers nothing: this app is not what runs it",
      !offerFullDiskAccess(nil))
check("the backup path is under the owner's ~/.local/state/system-config",
      messagesBackupPath(home: "/Users/u") == "/Users/u/.local/state/system-config/messages-backup.json")

let msgRows = messagesRows(source: fda, backup: bad, now: now)
check("the section is Attachments then Backup", labels(msgRows) == ["Attachments", "Backup"])
let allLines = (ledgerRows(s, backend: .mac, haveStats: true) + msgRows).map { (l, v) in (l, ledgerLine(l, v)) }
check("Messages values start in the ledger's column",
      Set(allLines.map { l, line in line.dropFirst(l.count).prefix { $0 == " " }.count + l.count }).count == 1)

print("\(pass) passed, \(fail) failed")
if fail > 0 { exit(1) }
