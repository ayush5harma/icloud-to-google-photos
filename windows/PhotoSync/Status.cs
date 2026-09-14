// The model and its conclusions -- a line-for-line port of Stats, RunStep and
// the render()/buildMenu() state machines in Sources/main.swift, so the tray
// and the menu bar can never disagree about what a status means. Pure C#, no
// UI: the tray icon and the flyout both draw from View.
//
// The rules that matter, restated because they are easy to "simplify" away:
//   - GREEN IS GATED ON THE CONFIRMATION STAMP (last-upload-confirmed), the only
//     signal that bytes reached Google, never on counts that merely add up.
//   - A STALE METER MUST LOOK STALE: a collector that stopped answering, or a
//     sync job that stopped completing runs, badges the ring.
//   - A run in flight is never "stalled" or "stale": it says what it is doing.
using System.Text.Json;

namespace PhotoSync;

internal sealed class Stats
{
    public bool Armed, Emulator, Confirmed, Running;
    public int Staged, Remaining, OnDevice, Uploaded, Queued, Failed, Reclaimed, ReclaimPending;
    public int UploadAge = -1, ConfirmedAge = -1, LastRunAge = -1;
    public string Phase = "";

    public bool BackupDone => Staged > 0 && Remaining == 0 && OnDevice == 0 && Confirmed;
    public bool BackupUnverified => Staged > 0 && Remaining == 0 && OnDevice == 0 && !Confirmed;
    public bool BackupStalled => OnDevice > 0 && Uploaded == 0 && !Running;
    public double UploadFraction => OnDevice > 0 ? (double)Uploaded / OnDevice : 0;

    // A batch parked on the device with the verifier silent for an hour, or a
    // 15-minute job that has not COMPLETED a run in three hours. Not keyed on
    // ConfirmedAge: a healthy no-op run leaves the stamp alone.
    public bool BackupStale
    {
        get
        {
            if (Running || !Armed) return false;
            if (OnDevice > 0 && UploadAge > 3600) return true;
            if (LastRunAge < 0) return Staged > 0;
            return LastRunAge > 3 * 3600;
        }
    }

    public static Stats? Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("backup", out var b) || b.ValueKind != JsonValueKind.Object) return null;
            bool B(string k) => b.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
            int I(string k, int d = 0) => b.TryGetProperty(k, out var v) && v.TryGetInt32(out var i) ? i : d;
            return new Stats
            {
                Armed = B("armed"), Emulator = B("emulator"), Confirmed = B("confirmed"), Running = B("running"),
                Staged = I("staged"), Remaining = I("remaining"), OnDevice = I("on_device"), Uploaded = I("uploaded"),
                Queued = I("queued"), Failed = I("failed"), Reclaimed = I("reclaimed"), ReclaimPending = I("reclaim_pending"),
                UploadAge = I("upload_age", -1), ConfirmedAge = I("confirmed_age", -1), LastRunAge = I("last_run_age", -1),
                Phase = b.TryGetProperty("phase", out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? "" : "",
            };
        }
        catch (JsonException) { return null; }
    }
}

/// <summary>Which side of the pipeline a running sync's phase line is on (main.swift's RunStep).</summary>
internal enum StepKind { Device, Cloud, Offload, Download, Busy }

internal readonly record struct RunStep(StepKind Kind, int A, int B)
{
    public static RunStep From(string phase)
    {
        var nums = System.Text.RegularExpressions.Regex.Matches(phase, @"\d+").Select(m => int.Parse(m.Value)).ToList();
        int a = nums.Count > 0 ? nums[0] : 0, b = nums.Count > 1 ? nums[1] : 0;
        if (phase.StartsWith("pushing ") || phase.StartsWith("indexing in MediaStore") || phase.StartsWith("re-announcing")
            || phase.StartsWith("reclaiming emulator space") || phase.StartsWith("removing empty device files"))
            return new(StepKind.Device, a, b);
        if (phase.StartsWith("waiting for MediaStore")) return new(StepKind.Device, 0, 0);
        if (phase.StartsWith("verifying uploads")) return new(StepKind.Cloud, a, b);
        if (phase.StartsWith("reclaiming iCloud space")) return new(StepKind.Offload, a, 0);
        if (phase.StartsWith("downloading")) return new(StepKind.Download, a, 0);
        return new(StepKind.Busy, 0, 0);
    }
}

internal enum Tone { Secondary, Red, Orange, Green, Blue }

/// <summary>Everything the tray and the flyout show, decided once.</summary>
internal sealed record View(RingSpec Ring, string Count, bool Spinning, string Headline, Tone HeadlineTone);

internal static class Fmt
{
    // 1234 -> "1.2k", 999 -> "999".
    public static string Compact(int n)
    {
        if (n < 1000) return n.ToString();
        double k = n / 1000.0;
        return k < 10 ? $"{k:0.0}k" : $"{(int)k}k";
    }

    // "8s ago" / "3m ago" / "2.4h ago".
    public static string RelAge(int s)
    {
        if (s < 0) return "never";
        if (s < 5) return "just now";
        if (s < 60) return $"{s}s ago";
        if (s < 3600) return $"{s / 60}m ago";
        if (s < 86400) return $"{s / 3600.0:0.0}h ago";
        return $"{s / 86400}d ago";
    }
}

internal static class Presenter
{
    /// <summary>
    /// The ring and the one-line conclusion, worst condition first: a collector
    /// that cannot report, failed uploads, a run in flight, a pipeline that has
    /// stopped tracking reality, a batch on the device, a backlog, and only when
    /// the confirmation stamp vouches for it, the green check.
    /// </summary>
    public static View Decide(Stats s, bool haveStats, bool collectorSick, string? lastError, double spinAngle)
    {
        RingSpec ring;
        string count = "";
        bool spinning = false;

        if (collectorSick || !haveStats)
            ring = new(0, Tint.Red, haveStats ? Mark.Exclaim : Mark.None);
        else if (!s.Armed)
            ring = new(0, Tint.Dim);
        else if (s.Failed > 0)
        {
            ring = new(Math.Max(s.UploadFraction, 0.06), Tint.Red, Mark.Exclaim);
            count = Fmt.Compact(s.Failed);
        }
        else if (s.Running)
        {
            RingSpec Progress(int n, int m, Tint t)
            {
                if (m > 0 && n > 0) return new((double)n / m, t);
                spinning = true;
                return new(0, t, Mark.None, spinAngle);
            }
            var step = RunStep.From(s.Phase);
            switch (step.Kind)
            {
                case StepKind.Device: ring = Progress(step.A, step.B, Tint.Yellow); count = step.B > 0 ? $"{step.A}/{step.B}" : ""; break;
                case StepKind.Cloud: ring = Progress(step.A, step.B, Tint.Blue); count = step.B > 0 ? $"{step.A}/{step.B}" : ""; break;
                case StepKind.Offload: ring = Progress(0, 0, Tint.Purple); count = step.A > 0 ? Fmt.Compact(step.A) : ""; break;
                case StepKind.Download:
                    ring = Progress(0, 0, Tint.Dim);
                    count = step.A > 0 ? Fmt.Compact(step.A) : (s.Remaining > 0 ? Fmt.Compact(s.Remaining) : "");
                    break;
                default:
                    ring = Progress(0, 0, Tint.Dim);
                    count = s.Remaining > 0 ? Fmt.Compact(s.Remaining) : "";
                    break;
            }
        }
        else if (s.BackupStale)
        {
            ring = new(s.OnDevice > 0 ? Math.Max(s.UploadFraction, 0.06) : 1, Tint.Orange, Mark.Exclaim);
            if (s.OnDevice > 0) count = $"{s.Uploaded}/{s.OnDevice}";
        }
        else if (s.OnDevice > 0)
        {
            ring = new(Math.Max(s.UploadFraction, s.BackupStalled ? 0.06 : 0), s.BackupStalled ? Tint.Yellow : Tint.Blue);
            count = $"{s.Uploaded}/{s.OnDevice}";
        }
        else if (s.Remaining > 0)
        {
            ring = new(0, Tint.Dim);
            count = Fmt.Compact(s.Remaining);
        }
        else if (s.BackupDone) ring = new(1, Tint.Green, Mark.Check);
        else if (s.BackupUnverified) ring = new(1, Tint.Yellow, Mark.Exclaim);
        else ring = new(0, Tint.Dim);

        // The headline (buildMenu's coloured status line).
        string text; Tone tone;
        if (!haveStats) { text = lastError ?? "Collecting…"; tone = lastError == null ? Tone.Secondary : Tone.Red; }
        else if (collectorSick) { text = $"Meter not refreshing — {lastError ?? "collector silent"}"; tone = Tone.Red; }
        else if (s.Running) { text = $"Running — {(s.Phase.Length == 0 ? "sync in progress" : s.Phase)}"; tone = Tone.Blue; }
        else if (s.Phase.StartsWith("failed:")) { text = $"Last run failed — {s.Phase[7..].Trim()}"; tone = Tone.Orange; }
        else if (s.Failed > 0) { text = $"{s.Failed} upload{(s.Failed == 1 ? "" : "s")} permanently failed"; tone = Tone.Red; }
        else if (s.BackupStale)
        {
            string why = s.OnDevice > 0 && s.UploadAge > 3600
                ? $"sync died mid-upload — verifier silent {Fmt.RelAge(s.UploadAge)}"
                : (s.LastRunAge < 0 ? "the sync job has never run" : $"sync job silent {Fmt.RelAge(s.LastRunAge)}");
            text = $"Stale — {why}"; tone = Tone.Orange;
        }
        else if (s.OnDevice > 0)
        {
            text = s.BackupStalled ? "Stalled — nothing reaching the server" : $"Uploading {s.Uploaded} of {s.OnDevice}";
            tone = s.BackupStalled ? Tone.Orange : Tone.Secondary;
        }
        else if (s.Remaining > 0) { text = $"{s.Remaining} waiting for the next sync run"; tone = Tone.Secondary; }
        else if (s.BackupDone) { text = $"All backed up · verified {Fmt.RelAge(s.ConfirmedAge)}"; tone = Tone.Green; }
        else if (s.BackupUnverified) { text = "Unverified — the last sync could not confirm uploads"; tone = Tone.Orange; }
        else { text = "Nothing staged yet"; tone = Tone.Secondary; }

        return new View(ring, count, spinning, text, tone);
    }

    /// <summary>The ledger rows (label, value), as the macOS dropdown lists them.</summary>
    public static List<(string Label, string Value)> Ledger(Stats s)
    {
        var rows = new List<(string, string)>
        {
            ("Staged", s.Staged.ToString("N0")),
            ("Backlog", s.Remaining == 0 ? "caught up" : s.Remaining.ToString("N0")),
        };
        if (s.Emulator || s.OnDevice > 0)
            rows.Add(("On device", $"{s.OnDevice}{(s.Queued > 0 ? $" ({s.Queued} queued)" : "")}"));
        // The count belongs to the batch the status was written for; once a
        // newer push exists the collector drops it (UploadAge -1).
        string verified;
        if (!s.Confirmed) verified = "NOT confirmed";
        else if (s.Running && s.OnDevice > 0) verified = $"{s.Uploaded} of {s.OnDevice} so far";
        else if (s.UploadAge < 0) verified = $"last batch {Fmt.RelAge(s.ConfirmedAge)}";
        else verified = $"{s.Uploaded} · {Fmt.RelAge(s.ConfirmedAge)}";
        rows.Add(("Verified", verified));
        rows.Add(("iCloud", $"{s.Reclaimed:N0} freed{(s.ReclaimPending > 0 ? $" · {s.ReclaimPending} confirmed, pending" : "")}"));
        rows.Add(("Last run", s.Running ? "running now" : Fmt.RelAge(s.LastRunAge)));
        rows.Add(("Emulator", s.Emulator ? "running" : "stopped"));
        return rows;
    }
}
