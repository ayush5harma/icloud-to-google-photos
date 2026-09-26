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

print("\(pass) passed, \(fail) failed")
if fail > 0 { exit(1) }
