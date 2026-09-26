// The menu's model: what the collector reported, which backend it describes,
// and the ledger rows drawn from both. Foundation only, no AppKit, so
// test/menu.sh compiles this file beside a test driver and checks the rows the
// dropdown would show without a menu bar, a collector or a running pipeline.

import Foundation

struct Stats {
    var armed = false, emulator = false
    // What the collector said PHOTOS_BACKEND resolved to, or nil when it said
    // nothing usable. Never read directly for a decision: effectiveBackend
    // turns it into the backend the menu is gated on.
    var backend: String?
    var app = false, appOnline = false, signedIn = false   // the Mac backend's app, from the bridge heartbeat
    // Where GPHOTOS_APP says Google Photos is. Published by the collector,
    // which is the only reader of the config file this app can ask: a launchd
    // agent's environment carries PATH and nothing else, so reading it here
    // always yielded the default.
    var appPath = "/Applications/GooglePhotos.app"
    var staged = 0, remaining = 0, onDevice = 0, uploaded = 0, queued = 0, failed = 0
    var givenUp = 0          // failed their three tries; nothing retries them on its own
    var uploadAge = -1
    var confirmed = false    // last-upload-confirmed stamp present
    var confirmedAge = -1
    var lastRunAge = -1      // seconds since the sync job last COMPLETED a run
    var running = false      // a sync run holds its lock right now
    var reclaimed = 0        // deleted from iCloud after Google Photos confirmed them
    var reclaimPending = 0   // confirmed, not yet deleted from iCloud
    var phase = ""           // that run's current step, or "failed: <why>" from the last one
    var messages: MessagesSource?   // the Messages attachments source, nil from an older collector

    // "Caught up" requires the sync job's confirmation stamp, not arithmetic:
    // the ledger can be full and upload-status left over from an older run while
    // the stamp is deliberately deleted because a verify pass failed.
    var backupDone: Bool { staged > 0 && remaining == 0 && onDevice == 0 && confirmed }
    var backupUnverified: Bool { staged > 0 && remaining == 0 && onDevice == 0 && !confirmed }
    // A live run is never "stalled" or "stale": it is pushing, indexing or
    // verifying right now and says so in its phase line. Both flags once fired
    // mid-push (the bar read "1000/377" with an exclamation) because the status
    // file still described the previous batch; the collector now discards a
    // status older than the last push, and these two ignore a run in flight.
    var backupStalled: Bool { onDevice > 0 && uploaded == 0 && !running }
    var uploadFraction: Double { onDevice > 0 ? Double(uploaded) / Double(onDevice) : 0 }
    // The PIPELINE has stopped tracking reality: a batch is parked on the device
    // with the verifier silent for an hour (a sync run died mid-flight), or the
    // 15-minute job has not COMPLETED a run in three hours. Deliberately NOT
    // keyed on confirmedAge -- a healthy no-op run leaves the stamp untouched,
    // so its age grows on a perfectly good pipeline.
    var backupStale: Bool {
        if running { return false }
        guard armed else { return false }
        if onDevice > 0 && uploadAge > 3600 { return true }
        if lastRunAge < 0 { return staged > 0 }   // armed, work staged, never ran
        return lastRunAge > 3 * 3600
    }
}

// Relative age for the dropdown: "8s ago" / "3m ago" / "2.4h ago".
func relAge(_ s: Int) -> String {
    if s < 0 { return "never" }
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return String(format: "%.1fh ago", Double(s) / 3600) }
    return "\(s / 86400)d ago"
}

// MARK: - Which backend the menu describes

enum Backend: String { case mac, avd }

// The same resolution lib/config.sh makes, in its order: the collector's
// report is the pipeline's own answer (environment > config file > default),
// so it wins whenever there is one. Without it -- before the first collection,
// or while the collector is failing -- the config file's PHOTOS_BACKEND, then
// the host default ap_defaults uses: Apple silicon is the Mac backend, anything
// else the emulator.
//
// WHY THIS IS NOT A PLAIN DEFAULT OF "avd". The menu used to fall back to "avd"
// whenever it had no report, so an Apple silicon Mac on the Mac backend showed
// an Emulator row and the AVD launcher every time the collector timed out, and
// before its first answer at every launch.
func effectiveBackend(reported: String?, configText: String?, machine: String) -> Backend {
    if let r = reported, let b = Backend(rawValue: r) { return b }
    if let t = configText, let b = configBackend(t) { return b }
    return hostBackend(machine: machine)
}

// ap_defaults: `case "$(uname -m)" in arm64) mac ;; *) avd ;; esac`.
func hostBackend(machine: String) -> Backend { machine == "arm64" ? .mac : .avd }

// PHOTOS_BACKEND as the config file sets it. The file is shell that
// ap_load_config sources, so the LAST assignment wins; this reads the plain
// assignment forms the file uses (bare, quoted, `export`, a trailing comment)
// and nothing that needs a shell to evaluate. A last assignment that is neither
// backend (empty included: sourced after ap_defaults, it really is empty) gives
// nil and so the host default; the sync itself refuses such a value.
func configBackend(_ text: String) -> Backend? {
    var found: Backend?
    for raw in text.split(whereSeparator: \.isNewline) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard line.hasPrefix("PHOTOS_BACKEND=") else { continue }
        var v = String(line.dropFirst("PHOTOS_BACKEND=".count))
        if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
        v = v.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
        found = Backend(rawValue: v)
    }
    return found
}

// MARK: - Ledger rows

// The label column of the ledger. It must be wider than the longest label:
// String.padding(toLength:) TRUNCATES a longer one, which is how the Mac
// backend's 13-character "Google Photos" row read "Google Photorunning".
let ledgerLabelWidth = 15

// "label  value" with at least two spaces between them, whatever the label.
func ledgerLine(_ label: String, _ value: String) -> String {
    label + String(repeating: " ", count: max(2, ledgerLabelWidth - label.count)) + value
}

// Every ledger row, in menu order, for one backend. Only the backend's own rows
// appear: the Mac backend has no emulator and no camera folder, and the
// emulator has no upload inbox to give up on. The device row (the app's or the
// emulator's state) needs a real report: a default Stats is not an observation,
// and "not running" before the first collection would be a guess.
func ledgerRows(_ s: Stats, backend: Backend, haveStats: Bool) -> [(String, String)] {
    var rows: [(String, String)] = [
        ("Staged", "\(s.staged)"),
        ("Backlog", s.remaining == 0 ? "caught up" : "\(s.remaining)"),
    ]
    switch backend {
    case .mac:
        if s.onDevice > 0 { rows.append(("Uploading", "\(s.onDevice) waiting on Google")) }
        // Shown only when there are any: these files are out of the pipeline
        // until a human asks for them back, and a count nobody can act on is
        // worse than no row.
        if s.givenUp > 0 { rows.append(("Given up", "\(s.givenUp) — avd-photos-sync --retry-given-up")) }
    case .avd:
        if s.emulator || s.onDevice > 0 {
            rows.append(("On device", "\(s.onDevice)\(s.queued > 0 ? " (\(s.queued) queued)" : "")"))
        }
    }
    // The count belongs to the batch the status was written for: once a newer
    // push exists the collector drops it (uploadAge -1), so only the stamp's age
    // is left to show; a verify pass in flight shows its own.
    let verified: String
    if !s.confirmed { verified = "NOT confirmed" }
    else if s.running && s.onDevice > 0 { verified = "\(s.uploaded) of \(s.onDevice) so far" }
    else if s.uploadAge < 0 { verified = "last batch \(relAge(s.confirmedAge))" }
    else { verified = "\(s.uploaded) · \(relAge(s.confirmedAge))" }
    rows.append(("Verified", verified))
    rows.append(("iCloud", "\(s.reclaimed) freed\(s.reclaimPending > 0 ? " · \(s.reclaimPending) confirmed, pending" : "")"))
    rows.append(("Last run", s.running ? "running now" : relAge(s.lastRunAge)))
    guard haveStats else { return rows }
    switch backend {
    case .mac:
        // The app uploads only while it has a visible window and a network (the
        // engine's own rule), so a hidden window is worth a line: the sync
        // launches it in the background and never brings it forward.
        let state: String
        if !s.app { state = "not running" }
        else if !s.signedIn { state = "running · not signed in" }
        else if s.appOnline { state = "running" }
        else { state = s.onDevice > 0 ? "running · window hidden, uploads paused" : "running · window hidden" }
        rows.append(("Google Photos", state))
    case .avd:
        rows.append(("Emulator", s.emulator ? "running" : "stopped"))
    }
    return rows
}

// The one "open the uploader" action: the Mac app where GPHOTOS_APP says it is,
// or the Dock launcher avd-photos-app builds for the emulator. The caller offers
// it only when the path exists.
let avdLauncherPath = "/Applications/Google Photos (AVD).app"
func uploaderLauncher(_ backend: Backend, appPath: String) -> (title: String, path: String) {
    switch backend {
    case .mac: return ("Open Google Photos", appPath)
    case .avd: return ("Open Google Photos (AVD)", avdLauncherPath)
    }
}

// MARK: - Messages

// Messages has two backups of its own, and the menu shows them apart from the
// photo sync because neither says anything about it: a Messages scan that
// could not look is not a photo that failed to upload.
//
// 1. The pipeline's own source (lib/messages.sh): images and videos from
//    Messages attachments staged into the photo sync. The collector reports it
//    as its "messages" object, from the line every scan leaves.
// 2. system-config's Messages backup, a copy of Messages to Drive made at
//    every switch. It writes one JSON file; this app only reads it.
struct MessagesSource: Equatable {
    enum State: String { case ok, skipped, off, unknown }
    var state: State
    var reason = ""
    var count = 0     // attachments dealt with so far: staged, or already in Google Photos
    var age = -1      // seconds since that scan, -1 when there has been none

    // TCC refusing a process Full Disk Access reaches the shell as EPERM,
    // "Operation not permitted" -- the reason every run logged on 2026-09-26.
    // A plain "Permission denied" (EACCES) is file modes, which Full Disk
    // Access does not change, so it is not offered the grant.
    var needsFullDiskAccess: Bool {
        state == .skipped && reason.range(of: "Operation not permitted", options: .caseInsensitive) != nil
    }
}

// The collector's "messages" object. nil when there is none -- a collector
// older than this app -- so the row is hidden rather than guessed; a state this
// app does not know is .unknown, which the row says, rather than dropped.
func messagesSource(_ obj: Any?) -> MessagesSource? {
    guard let m = obj as? [String: Any] else { return nil }
    return MessagesSource(
        state: (m["state"] as? String).flatMap(MessagesSource.State.init(rawValue:)) ?? .unknown,
        reason: m["reason"] as? String ?? "",
        count: m["count"] as? Int ?? 0,
        age: m["age"] as? Int ?? -1)
}

// Offered only for the pipeline's own source: the sync runs as this app's
// child, so this app is what needs the grant. The system-config backup runs
// from a switch, whose grant is not this app's to give.
func offerFullDiskAccess(_ source: MessagesSource?) -> Bool { source?.needsFullDiskAccess == true }

// {"ok":bool,"at":"<ISO 8601>","reason":"...","items":N,"dest":"<path>"},
// replaced atomically by system-config. Only ok, at and reason are shown.
enum MessagesBackup: Equatable {
    case ok(at: Date?)
    case failed(reason: String, at: Date?)
    case unreadable
}

func messagesBackupPath(home: String) -> String { home + "/.local/state/system-config/messages-backup.json" }

// nil data is a file that does not exist: that host does not run the backup,
// so the row is hidden. A file that exists but is not an object with a boolean
// "ok" is .unreadable -- a backup of unknown outcome must not read as fine. An
// "at" that does not parse only loses the age.
func messagesBackup(_ data: Data?) -> MessagesBackup? {
    guard let data else { return nil }
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let ok = o["ok"] as? Bool else { return .unreadable }
    let at = (o["at"] as? String).flatMap(isoDate)
    return ok ? .ok(at: at) : .failed(reason: o["reason"] as? String ?? "", at: at)
}

func isoDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

// The Messages section, in menu order; empty when there is nothing to say.
// Drawn with ledgerLine like the ledger, so the values share its column.
func messagesRows(source: MessagesSource?, backup: MessagesBackup?, now: Date) -> [(String, String)] {
    var rows: [(String, String)] = []
    if let m = source {
        let v: String
        switch m.state {
        case .ok: v = "\(m.count) synced"
        case .skipped where m.needsFullDiskAccess: v = "skipped: needs Full Disk Access"
        case .skipped: v = "skipped: \(m.reason.isEmpty ? "see sync.log" : m.reason)"
        case .off: v = "off"
        case .unknown: v = "not scanned yet"
        }
        rows.append(("Attachments", v))
    }
    if let b = backup {
        func age(_ at: Date?) -> String { at.map { " · " + relAge(max(0, Int(now.timeIntervalSince($0)))) } ?? "" }
        let v: String
        switch b {
        case .ok(let at): v = "ok" + age(at)
        case .failed(let reason, let at): v = (reason.isEmpty ? "failed" : "failed: \(reason)") + age(at)
        case .unreadable: v = "unreadable"
        }
        rows.append(("Backup", v))
    }
    return rows
}
