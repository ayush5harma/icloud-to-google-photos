// Photo Sync -- the menu-bar face of the iCloud -> Google Photos pipeline.
//
// ONE STATUS ITEM: a progress ring that says which side of the pipeline the
// current batch is on, and a dropdown with the ledger, the live phase line and
// the two actions that are safe to take by hand. It collects nothing itself --
// avd-photos-status emits the JSON, avd-photos-sync writes every number in it.
//
// GLANCEABLE, NOT A WALL. A menu bar item is read in a saccade, not studied, so
// the bar carries one ring and at most one short count; the detail lives in the
// dropdown, rebuilt fresh every time it opens so the ages are computed when eyes
// are on them.
//
// A STALE METER MUST LOOK STALE. The collector can fail (a wedged adb, a missing
// script) and the Mac can sleep for days, so the app tracks when data was last
// collected and badges the ring when the pipeline has stopped tracking reality.
// The green state is gated on the sync's last-upload-confirmed stamp -- the ONLY
// signal that bytes reached Google's servers -- never on derived arithmetic,
// which can read complete while the stamp is absent.
//
// CONTRAST. Menu-bar text uses the ADAPTIVE label colours, which macOS keeps
// legible on a light, dark or desktop-tinted bar. Saturated colour is confined
// to the ring, which carries its own contrast, and is never the only thing
// making a number readable.

import AppKit

// MARK: CLI mode -- run the sync under this app's identity
//
// `PhotoSync --sync [args…]` runs avd-photos-sync as a CHILD of this binary and
// waits for it. The point is macOS's per-app file-provider permission: a launchd
// job's responsible process is its own executable, so a bare /bin/bash gets
// "Operation not permitted" on every directory of a cloud-provider mount
// (measured 2026-09-06: six refusals in a row from launchd, while an interactive
// run of the same script listed all 2,831 files in 12 ms) whereas a child of
// this app lists it fine. Spawn-and-wait, NEVER exec: exec would swap this image
// for bash and the identity with it.
//
// FIRST THING IN THE FILE, before any global that touches AppKit:
// `NSStatusBar.system` registers the process with LaunchServices as a running
// copy of this app, and the UI's single-instance sweep would then terminate a
// `--sync` parent mid-run. A CLI run must never look like a second meter.
//
// THERE IS NO GENERAL `--run`, AND THE SEARCH PATH IGNORES THE ENVIRONMENT.
// A child of this app inherits the app's privacy grants, so anything that can
// decide WHAT to run decides what gets those grants. An earlier version took the
// directory from AVD_PHOTOS_BIN_DIR, which any caller can set
// (`AVD_PHOTOS_BIN_DIR=/tmp/evil PhotoSync --run sh`), and a `--run` hatch that
// accepted "one of the pipeline's own commands" was only as good as that
// directory. Both are gone: the scripts are looked up in FIXED places only --
// the directory this bundle's own Info.plist names (AVDPhotosBinDir, written by
// build.sh before the bundle is signed, so the seal covers it and it cannot be
// changed without breaking that seal) and the standard user locations.
func resolveScript(_ name: String) -> String {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var dirs: [String] = []
    if let d = Bundle.main.object(forInfoDictionaryKey: "AVDPhotosBinDir") as? String, !d.isEmpty {
        dirs.append(d)
    }
    dirs += ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin"]
    for d in dirs {
        let p = "\(d)/\(name)"
        if fm.isExecutableFile(atPath: p) { return p }
    }
    return ""
}

var cliChild: Process?
func runUnderThisIdentity(_ argv: [String]) -> Never {
    guard let program = argv.first, !program.isEmpty else {
        FileHandle.standardError.write(Data("usage: PhotoSync --sync [args…]\n".utf8))
        exit(64)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: program)
    p.arguments = Array(argv.dropFirst())
    p.standardInput = FileHandle.standardInput
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    cliChild = p
    // launchd stops a job with SIGTERM; pass it on so the script's exit trap
    // (its lock and phase file) runs instead of leaving a stale lock behind.
    signal(SIGTERM) { _ in cliChild?.terminate() }
    signal(SIGINT) { _ in cliChild?.interrupt() }
    do { try p.run() } catch {
        FileHandle.standardError.write(Data("PhotoSync: cannot run \(program): \(error)\n".utf8))
        exit(126)
    }
    p.waitUntilExit()
    exit(p.terminationStatus)
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "--sync" {
    let script = resolveScript("avd-photos-sync")
    if script.isEmpty {
        FileHandle.standardError.write(Data(
            "PhotoSync --sync: avd-photos-sync not found in this bundle or ~/.local/bin — re-run install.sh\n".utf8))
        exit(127)
    }
    runUnderThisIdentity(["/bin/bash", script] + cliArgs.dropFirst())
}
if cliArgs.first == "--run" {
    FileHandle.standardError.write(Data(
        "PhotoSync: --run was removed; only --sync runs under this app's identity\n".utf8))
    exit(64)
}

// The launchd label prefix, and it must match lib/config.sh's AP_LABEL_PREFIX:
// "Check iCloud now" kickstarts <prefix>.sync so the run is launchd's child and
// a restart of this app cannot kill it mid-push.
let labelPrefix = "com.ayushsharma.icloud-to-google-photos"

// The two inputs effectiveBackend needs when the collector has not answered.
// `uname -m`, which is what ap_defaults asks; and the config file at the path
// lib/config.sh reads (AVD_PHOTOS_CONFIG_DIR is honoured for parity, though a
// launchd agent never carries it). Reading a display hint from the environment
// is harmless here, unlike resolveScript's choice of what to run.
let hostMachine: String = {
    var u = utsname()
    guard uname(&u) == 0 else { return "" }
    return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}()
func configText() -> String? {
    let dir = ProcessInfo.processInfo.environment["AVD_PHOTOS_CONFIG_DIR"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.config/avd-photos"
    return try? String(contentsOfFile: dir + "/config", encoding: .utf8)
}
// Stats, the backend resolution and the ledger rows are in model.swift.

// MARK: - Formatting

// Compact count for the menu bar: 1234 -> "1.2k", 999 -> "999". Keeps the label
// a fixed narrow width no matter how large the library grows.
func compact(_ n: Int) -> String {
    if n < 1000 { return "\(n)" }
    let k = Double(n) / 1000
    return k < 10 ? String(format: "%.1fk", k) : "\(Int(k))k"
}

// MARK: - Colour

// Everything DRAWN in the bar uses MUTED variants of the system colours:
// full-saturation system colours shout next to the bar's monochrome template
// icons, and a meter is furniture, not an alert box. Blending about a third of
// the chroma toward mid-grey keeps every hue nameable in a light or dark bar
// without the neon look; red and orange pass through the same blend because the
// MARK (the exclamation) carries the alarm -- colour only names it. Menu TEXT
// keeps the stock system colours: those rows are standard UI.
func muted(_ c: NSColor) -> NSColor {
    c.blended(withFraction: 0.38, of: NSColor(calibratedWhite: 0.58, alpha: 1)) ?? c
}

// MARK: - Ring drawing

// Match the real menu-bar height so drawn images fill it instead of being scaled
// down (a notched MacBook is ~24pt, a classic bar ~22). Floor at 18 for safety
// if the status bar reports something tiny.
let H: CGFloat = max(18, NSStatusBar.system.thickness)

enum RingMark { case none, check, exclaim }

// The step a running sync is in, read off its phase line (avd-photos-sync writes
// one per step, with "done of total" where it has a count). The ring colours the
// SIDE of the pipeline the batch is on: yellow for the device (pushing,
// indexing, re-announcing, pruning), blue for the cloud (Google Photos
// confirming the batch), purple for iCloud being offloaded (the reclaim),
// neutral for the steps with no count (boot, listing) and for the iCloud
// download, which shows its running tally. A step with no progress numbers spins
// instead of pretending to a fraction.
enum RunStep {
    case device(Int, Int), cloud(Int, Int), offload(Int), download(Int), busy
    init(_ phase: String) {
        let n = phase.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let a = n.count > 0 ? n[0] : 0, b = n.count > 1 ? n[1] : 0
        if phase.hasPrefix("pushing ") || phase.hasPrefix("indexing in MediaStore")
            || phase.hasPrefix("re-announcing") || phase.hasPrefix("reclaiming emulator space")
            || phase.hasPrefix("removing empty device files") {
            self = .device(a, b)
        } else if phase.hasPrefix("waiting for MediaStore") {
            self = .device(0, 0)
        } else if phase.hasPrefix("verifying uploads") {
            self = .cloud(a, b)
        } else if phase.hasPrefix("reclaiming iCloud space") {
            self = .offload(a)
        } else if phase.hasPrefix("downloading") {
            self = .download(a)
        } else {
            self = .busy
        }
    }
}

// macOS-style progress ring. `spin` (degrees) draws a short indeterminate arc
// starting there instead of the fraction -- the "buffering" look for a step that
// has no count -- and the app's spinner timer advances it.
func ring(fraction: Double, tint: NSColor, mark: RingMark = .none, spin: CGFloat? = nil) -> NSImage {
    let d: CGFloat = H - 5
    let img = NSImage(size: NSSize(width: d + 2, height: H))
    img.lockFocus()
    NSGraphicsContext.current?.shouldAntialias = true
    let c = NSPoint(x: (d + 2) / 2, y: H / 2)
    let r = d / 2 - 1, lw: CGFloat = 2.2
    let track = NSBezierPath(); track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    track.lineWidth = lw; NSColor.tertiaryLabelColor.setStroke(); track.stroke()
    if let s = spin {
        let a = NSBezierPath()
        a.appendArc(withCenter: c, radius: r, startAngle: s, endAngle: s - 100, clockwise: true)
        a.lineWidth = lw; a.lineCapStyle = .round; tint.setStroke(); a.stroke()
    } else if fraction > 0 || mark != .none {
        let a = NSBezierPath()
        a.appendArc(withCenter: c, radius: r, startAngle: 90,
                    endAngle: 90 - CGFloat(360 * min(1, max(0, fraction))), clockwise: true)
        a.lineWidth = lw; a.lineCapStyle = .round; tint.setStroke(); a.stroke()
    }
    switch mark {
    case .check:
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x - r * 0.42, y: c.y + r * 0.02))
        p.line(to: NSPoint(x: c.x - r * 0.10, y: c.y - r * 0.32))
        p.line(to: NSPoint(x: c.x + r * 0.48, y: c.y + r * 0.36))
        p.lineWidth = 1.8; p.lineCapStyle = .round; p.lineJoinStyle = .round
        tint.setStroke(); p.stroke()
    case .exclaim:
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y + r * 0.5))
        p.line(to: NSPoint(x: c.x, y: c.y - r * 0.1))
        p.lineWidth = 1.8; p.lineCapStyle = .round
        tint.setStroke(); p.stroke()
        tint.setFill()
        let dd = r * 0.28
        NSBezierPath(ovalIn: NSRect(x: c.x - dd / 2, y: c.y - r * 0.55 - dd / 2, width: dd, height: dd)).fill()
    case .none: break
    }
    img.unlockFocus(); img.isTemplate = false
    return img
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var stats = Stats()
    private var haveStats = false
    private var statusScript = ""
    private var syncScript = ""
    private var offloading = false
    private var spinAngle: CGFloat = 90   // the indeterminate arc's start, advanced by `spinner`
    private var spinner: Timer?
    private var lastError: String?
    private var lastGood: Date?           // when the collector last returned parseable JSON
    private var failStreak = 0
    private var collecting = false

    // The meter's own health, distinct from the pipeline's. Three missed 30 s
    // ticks means the collector itself is failing or wedged.
    private var collectorSick: Bool {
        if failStreak >= 3 { return true }
        guard let g = lastGood else { return false }
        return Date().timeIntervalSince(g) > 150
    }

    func applicationDidFinishLaunching(_: Notification) {
        // SINGLE INSTANCE. A launchd agent owns this app, so any second copy --
        // an `open`, a double-click, a stale one left behind -- puts a SECOND
        // item in the menu bar and everything appears twice. Each instance draws
        // its own item, so this is not a rendering bug and cannot be fixed by
        // drawing; the duplicate process has to go.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.ayushsharma.icloud-to-google-photos")
            .filter { $0.processIdentifier != me }
        for a in others { a.terminate() }

        statusScript = resolveScript("avd-photos-status")
        syncScript = resolveScript("avd-photos-sync")

        menu.delegate = self
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        if let b = item.button {
            b.imagePosition = .imageLeading
            b.image = ring(fraction: 0, tint: .tertiaryLabelColor)
        }
        refresh()

        // .common mode, or the timer freezes exactly when someone is LOOKING at
        // the meter: menu tracking runs the run loop in event-tracking mode,
        // where a default-mode timer never fires.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Refresh immediately at wake instead of painting pre-sleep numbers for
        // up to a full tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    // MARK: Collect

    private func refresh() {
        guard !statusScript.isEmpty else {
            lastError = "avd-photos-status not found"; failStreak += 1; render(); return
        }
        // One collection at a time: a wedged run must not pile new processes on
        // top of itself every tick. Liveness is preserved by the watchdog below
        // plus collectorSick surfacing the gap in the UI.
        guard !collecting else { return }
        collecting = true
        let script = statusScript
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [script]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            var parsed: Stats?; var err: String?
            do {
                try p.run()
                // Watchdog. The script bounds its own slow path (one adb call,
                // 6 s), so 25 s only trips when something is genuinely wedged;
                // killing it turns a silent freeze into a visible error state.
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: killer)
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                parsed = Self.parse(d)
                if parsed == nil { err = d.isEmpty ? "collector timed out" : "collector output unparseable" }
            } catch { err = "collector failed to start" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.collecting = false
                if let s = parsed {
                    self.stats = s; self.haveStats = true
                    self.lastError = nil; self.lastGood = Date(); self.failStreak = 0
                } else {
                    self.lastError = err; self.failStreak += 1
                }
                self.render()
            }
        }
    }

    private static func parse(_ data: Data) -> Stats? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let b = root["backup"] as? [String: Any] else { return nil }
        var s = Stats()
        s.armed = b["armed"] as? Bool ?? false
        s.emulator = b["emulator"] as? Bool ?? false
        s.backend = b["backend"] as? String
        s.app = b["app"] as? Bool ?? false
        s.appOnline = b["app_online"] as? Bool ?? false
        s.signedIn = b["signed_in"] as? Bool ?? false
        s.appPath = b["app_path"] as? String ?? s.appPath
        s.staged = b["staged"] as? Int ?? 0
        s.remaining = b["remaining"] as? Int ?? 0
        s.onDevice = b["on_device"] as? Int ?? 0
        s.givenUp = b["given_up"] as? Int ?? 0
        s.uploaded = b["uploaded"] as? Int ?? 0
        s.queued = b["queued"] as? Int ?? 0
        s.failed = b["failed"] as? Int ?? 0
        s.uploadAge = b["upload_age"] as? Int ?? -1
        s.confirmed = b["confirmed"] as? Bool ?? false
        s.confirmedAge = b["confirmed_age"] as? Int ?? -1
        s.lastRunAge = b["last_run_age"] as? Int ?? -1
        s.running = b["running"] as? Bool ?? false
        s.reclaimed = b["reclaimed"] as? Int ?? 0
        s.reclaimPending = b["reclaim_pending"] as? Int ?? 0
        s.phase = b["phase"] as? String ?? ""
        return s
    }

    // MARK: Bar rendering

    private func barText(_ s: String, _ c: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: c,
        ])
    }

    private func render() {
        guard let b = item.button else { return }
        // A small state machine, worst condition first: a collector that cannot
        // report, failed uploads, a pipeline that stopped tracking reality, work
        // in flight (partial ring = live progress), a waiting backlog, and only
        // when the confirmation stamp vouches for it, the solid green check.
        var image: NSImage
        var text = ""
        var spinning = false
        if collectorSick || !haveStats {
            image = ring(fraction: 0, tint: muted(.systemRed), mark: haveStats ? .exclaim : .none)
        } else if !stats.armed {
            // Dormant: installed and scheduled, doing nothing by design. A dim
            // ring, no count, and the dropdown says how to arm it.
            image = ring(fraction: 0, tint: .tertiaryLabelColor)
        } else if stats.failed > 0 {
            image = ring(fraction: max(stats.uploadFraction, 0.06), tint: muted(.systemRed), mark: .exclaim)
            text = compact(stats.failed)
        } else if stats.running {
            // A run in flight paints its own step (see RunStep): progress where
            // the step has a count, a spin where it does not.
            func progress(_ n: Int, _ m: Int, _ tint: NSColor) -> NSImage {
                if m > 0 && n > 0 { return ring(fraction: Double(n) / Double(m), tint: tint) }
                spinning = true
                return ring(fraction: 0, tint: tint, spin: spinAngle)
            }
            switch RunStep(stats.phase) {
            case .device(let n, let m): image = progress(n, m, muted(.systemYellow)); text = m > 0 ? "\(n)/\(m)" : ""
            case .cloud(let n, let m):  image = progress(n, m, muted(.systemBlue));   text = m > 0 ? "\(n)/\(m)" : ""
            case .offload(let n):       image = progress(0, 0, muted(.systemPurple)); text = n > 0 ? compact(n) : ""
            case .download(let n):      image = progress(0, 0, NSColor.tertiaryLabelColor)
                                        text = n > 0 ? compact(n) : (stats.remaining > 0 ? compact(stats.remaining) : "")
            case .busy:                 image = progress(0, 0, NSColor.tertiaryLabelColor)
                                        text = stats.remaining > 0 ? compact(stats.remaining) : ""
            }
        } else if stats.backupStale {
            image = ring(fraction: stats.onDevice > 0 ? max(stats.uploadFraction, 0.06) : 1,
                         tint: muted(.systemOrange), mark: .exclaim)
            if stats.onDevice > 0 { text = "\(stats.uploaded)/\(stats.onDevice)" }
        } else if stats.onDevice > 0 {
            // A batch is in flight: uploaded/onDevice is bounded (DCIM is pruned
            // after each confirm), so this never balloons with the library size.
            let tint: NSColor = stats.backupStalled ? muted(.systemYellow) : muted(.systemBlue)
            image = ring(fraction: max(stats.uploadFraction, stats.backupStalled ? 0.06 : 0), tint: tint)
            text = "\(stats.uploaded)/\(stats.onDevice)"
        } else if stats.remaining > 0 {
            // Backlog waiting for the next run. Show the backlog, not the
            // ever-growing staged total.
            image = ring(fraction: 0, tint: .tertiaryLabelColor)
            text = compact(stats.remaining)
        } else if stats.backupDone {
            // Everything staged is pushed AND the sync job's verify pass
            // confirmed it server-side. Ring alone -- the green check IS the
            // message.
            image = ring(fraction: 1, tint: muted(.systemGreen), mark: .check)
        } else if stats.backupUnverified {
            // Counts look complete but the confirmation stamp is absent: the last
            // verify failed or was cleared. This must NOT render green.
            image = ring(fraction: 1, tint: muted(.systemYellow), mark: .exclaim)
        } else {
            image = ring(fraction: 0, tint: .tertiaryLabelColor)
        }
        b.image = image
        b.attributedTitle = barText(text, .labelColor)
        if spinning { startSpinner() } else { stopSpinner() }
    }

    // 8 fps is plenty for an 18 pt arc and costs nothing measurable; the timer
    // exists only while a spinning step is on screen.
    private func startSpinner() {
        guard spinner == nil else { return }
        let t = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.spinAngle -= 20
            if self.spinAngle <= -270 { self.spinAngle += 360 }
            self.render()
        }
        RunLoop.main.add(t, forMode: .common); spinner = t
    }
    private func stopSpinner() { spinner?.invalidate(); spinner = nil }

    // MARK: Menu (rebuilt at open, so ages are computed when eyes are on them)

    func menuNeedsUpdate(_ m: NSMenu) { buildMenu(m) }

    func menuWillOpen(_ m: NSMenu) {
        // An open is a moment the numbers are actually being read -- collect in
        // the background so the NEXT look (and the bar, seconds later) is fresh.
        refresh()
    }

    private func header(_ m: NSMenu, _ s: String) {
        let x = NSMenuItem(title: s, action: nil, keyEquivalent: ""); x.isEnabled = false
        x.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        m.addItem(x)
    }

    private func note(_ m: NSMenu, _ s: String, color: NSColor = .secondaryLabelColor) {
        let x = NSMenuItem(title: s, action: nil, keyEquivalent: ""); x.isEnabled = false
        x.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: color,
        ])
        m.addItem(x)
    }

    // Aligned "label  value" row for the ledger (ledgerLine, model.swift).
    private func mono(_ m: NSMenu, _ label: String, _ value: String) {
        let s = ledgerLine(label, value)
        let x = NSMenuItem(title: s, action: nil, keyEquivalent: ""); x.isEnabled = false
        x.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        m.addItem(x)
    }

    // Text-only action rows, like the system's own status menus. (SF Symbol
    // images on these rows do not render in this status-menu context; the
    // custom-drawn ring carries the iconography instead.)
    private func action(_ m: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let x = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        x.target = self
        m.addItem(x)
    }

    private func buildMenu(_ m: NSMenu) {
        m.removeAllItems()
        header(m, "iCloud → Google Photos")

        // One coloured status line stating THE conclusion; the ledger below
        // carries the numbers it was drawn from. A run in flight reports its own
        // step, and a run that could not do its job leaves the reason behind;
        // both beat the derived states, which cannot tell "downloading for two
        // hours" from "stopped".
        if !haveStats {
            note(m, lastError ?? "Collecting…", color: lastError == nil ? .secondaryLabelColor : .systemRed)
        } else if collectorSick {
            note(m, "Meter not refreshing — \(lastError ?? "collector silent")", color: .systemRed)
        } else if stats.running {
            note(m, "Running — \(stats.phase.isEmpty ? "sync in progress" : stats.phase)", color: .systemBlue)
        } else if stats.phase.hasPrefix("failed:") {
            note(m, "Last run failed — \(stats.phase.dropFirst(7).trimmingCharacters(in: .whitespaces))",
                 color: .systemOrange)
        } else if stats.failed > 0 {
            note(m, "\(stats.failed) upload\(stats.failed == 1 ? "" : "s") permanently failed", color: .systemRed)
        } else if stats.backupStale {
            let why = stats.onDevice > 0 && stats.uploadAge > 3600
                ? "sync died mid-upload — verifier silent \(relAge(stats.uploadAge))"
                : (stats.lastRunAge < 0 ? "the sync job has never run"
                                        : "sync job silent \(relAge(stats.lastRunAge))")
            note(m, "Stale — \(why)", color: .systemOrange)
        } else if stats.onDevice > 0 {
            note(m, stats.backupStalled ? "Stalled — nothing reaching the server"
                                        : "Uploading \(stats.uploaded) of \(stats.onDevice)",
                 color: stats.backupStalled ? .systemOrange : .secondaryLabelColor)
        } else if stats.remaining > 0 {
            note(m, "\(stats.remaining) waiting for the next sync run")
        } else if stats.backupDone {
            note(m, "All backed up · verified \(relAge(stats.confirmedAge))", color: .systemGreen)
        } else if stats.backupUnverified {
            note(m, "Unverified — the last sync could not confirm uploads", color: .systemOrange)
        } else {
            note(m, "Nothing staged yet")
        }
        if haveStats && !stats.armed {
            note(m, "Dormant — run avd-photos-arm to enable the sync", color: .systemOrange)
        }

        let backend = effectiveBackend(reported: haveStats ? stats.backend : nil,
                                       configText: configText(), machine: hostMachine)
        m.addItem(.separator())
        for (label, value) in ledgerRows(stats, backend: backend, haveStats: haveStats) {
            mono(m, label, value)
        }

        m.addItem(.separator())
        let launcher = uploaderLauncher(backend, appPath: stats.appPath)
        if FileManager.default.fileExists(atPath: launcher.path) {
            let x = NSMenuItem(title: launcher.title, action: #selector(openUploader(_:)), keyEquivalent: "")
            x.target = self; x.representedObject = launcher.path
            m.addItem(x)
        }
        // Manual iCloud reclaim. Offered ONLY once Google Photos' own database
        // has confirmed the batch (stats.confirmed is the last-upload-confirmed
        // stamp) -- this deletes from the real photo library, so the button must
        // not exist in a state where the pipeline has not proven itself. The
        // script re-checks the same stamp, so the gate is enforced twice.
        if !syncScript.isEmpty && stats.armed {
            if offloading {
                note(m, "Offloading from iCloud…")
            } else if stats.running {
                note(m, "Offload unavailable while a sync is running")
            } else if stats.confirmed {
                action(m, "Offload from iCloud", #selector(doOffload))
            } else {
                note(m, "Offload unavailable — no confirmed upload yet")
            }
        }
        // The manual trigger: the same check the 15-minute tick runs. While a run
        // is alive the top line already says what it is doing.
        if stats.armed && !stats.running {
            action(m, "Check iCloud now", #selector(doCheck))
        } else if stats.armed {
            note(m, "Checking — a sync run is in progress")
        }
        action(m, "Refresh Now", #selector(doRefresh), key: "r")
        m.addItem(.separator())
        action(m, "Quit Photo Sync", #selector(quit), key: "q")
    }

    @objc private func doRefresh() { refresh() }

    // Runs the sync with reclaim forced on. Detached and non-blocking: an offload
    // run downloads, pushes and waits on Google Photos, so it is minutes long --
    // holding the main thread would freeze the menu bar. The in-flight flag keeps
    // a second click from starting an overlapping run (the script is not
    // reentrant against itself), and the refresh at the end repaints the ledger
    // from whatever the run actually achieved.
    @objc private func doOffload() {
        guard !offloading, !syncScript.isEmpty else { return }
        offloading = true
        let script = syncScript
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script, "--offload"]
            p.standardOutput = FileHandle.nullDevice   // the script owns its log
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                self?.offloading = false
                self?.refresh()
            }
        }
    }

    // Kick the sync agent: the run is then launchd's child, not this app's, so a
    // restart of this app cannot kill it mid-push (a run spawned from a terminal
    // session died that way, emulator included). `--sync` spawned from here is
    // the fallback where the agent is not loaded; the script's lock turns a race
    // with a scheduled tick into one skipped line.
    @objc private func doCheck() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(labelPrefix).sync"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        var kicked = false
        if (try? p.run()) != nil { p.waitUntilExit(); kicked = p.terminationStatus == 0 }
        if !kicked, let me = Bundle.main.executablePath {
            let q = Process()
            q.executableURL = URL(fileURLWithPath: me); q.arguments = ["--sync"]
            q.standardOutput = FileHandle.nullDevice; q.standardError = FileHandle.nullDevice
            try? q.run()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openUploader(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
