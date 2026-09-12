# The tray's MODEL: what Photo Sync.app (Sources/main.swift) decides, as pure
# functions. The WinForms host, windows\bin\avd-photos-tray.ps1, is a thin
# shell that draws and wires what these return; every decision -- which ring,
# which note, which rows, which actions -- is made here, where the tests run
# on any OS. Nothing in this file touches WinForms or System.Drawing, so the
# module still loads on macOS and Linux.
#
# The Swift file is the spec. Where a function mirrors one of its pieces the
# comment names it (Stats, compact, relAge, RunStep, render(), buildMenu(),
# muted(), ring()); where Windows forces a difference the comment says why.
# Menu text is ASCII: an em dash is '--', a middle dot is '-', an arrow is
# '->' and an ellipsis is '...'.

# -- The status the collector reports (struct Stats) --------------------------

# A Stats value with the Swift defaults, and its derived flags as live
# properties (the Swift computed vars), so a caller that changes a field reads
# flags that agree with it. -Property sets fields by name; a misspelt one
# throws under StrictMode rather than being silently ignored.
function New-AvdTrayStatus {
    param([System.Collections.IDictionary]$Property = @{})
    $s = [pscustomobject][ordered]@{
        Armed          = $false
        Emulator       = $false
        Staged         = 0L
        Remaining      = 0L
        OnDevice       = 0L
        Uploaded       = 0L
        Queued         = 0L
        Failed         = 0L
        UploadAge      = -1L
        # The last-upload-confirmed stamp is present.
        Confirmed      = $false
        ConfirmedAge   = -1L
        # Seconds since the sync job last COMPLETED a run.
        LastRunAge     = -1L
        # A sync run holds its lock right now.
        Running        = $false
        # Deleted from iCloud after Google Photos confirmed them.
        Reclaimed      = 0L
        # Confirmed, not yet deleted from iCloud.
        ReclaimPending = 0L
        # That run's current step, or "failed: <why>" from the last one.
        Phase          = ''
    }
    foreach ($k in $Property.Keys) {
        if ($null -eq $s.PSObject.Properties[[string]$k]) { throw "New-AvdTrayStatus: no field '$k'" }
        $s.$k = $Property[$k]
    }
    # "Caught up" requires the sync job's confirmation stamp, not arithmetic:
    # the ledger can be full and upload-status left over from an older run
    # while the stamp is deliberately deleted because a verify pass failed.
    $s | Add-Member -MemberType ScriptProperty -Name BackupDone -Value {
        $this.Staged -gt 0 -and $this.Remaining -eq 0 -and $this.OnDevice -eq 0 -and $this.Confirmed
    }
    $s | Add-Member -MemberType ScriptProperty -Name BackupUnverified -Value {
        $this.Staged -gt 0 -and $this.Remaining -eq 0 -and $this.OnDevice -eq 0 -and -not $this.Confirmed
    }
    # A live run is never "stalled" or "stale": it is pushing, indexing or
    # verifying right now and says so in its phase line (the Swift comment has
    # the "1000/377" incident this rule came from).
    $s | Add-Member -MemberType ScriptProperty -Name BackupStalled -Value {
        $this.OnDevice -gt 0 -and $this.Uploaded -eq 0 -and -not $this.Running
    }
    $s | Add-Member -MemberType ScriptProperty -Name UploadFraction -Value {
        if ($this.OnDevice -gt 0) { [double]$this.Uploaded / [double]$this.OnDevice } else { 0.0 }
    }
    # The PIPELINE has stopped tracking reality: a batch parked on the device
    # with the verifier silent for an hour (a run died mid-flight), or the
    # 15-minute job has not COMPLETED a run in three hours. Deliberately not
    # keyed on ConfirmedAge: a healthy no-op run leaves the stamp untouched.
    $s | Add-Member -MemberType ScriptProperty -Name BackupStale -Value {
        if ($this.Running) { return $false }
        if (-not $this.Armed) { return $false }
        if ($this.OnDevice -gt 0 -and $this.UploadAge -gt 3600) { return $true }
        # Armed, work staged, never ran.
        if ($this.LastRunAge -lt 0) { return $this.Staged -gt 0 }
        $this.LastRunAge -gt 3 * 3600
    }
    $s
}

# One JSON value as a whole number, or $null. `as? Int` in the Swift parse:
# an integral number is taken (3.0 included, as NSNumber bridging allows);
# anything else is $null and the caller keeps the default. Swift would also
# bridge true/false to 1/0; the status script never writes a bool there.
function ConvertFrom-AvdJsonInt {
    param([System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { return $null }
    $n = 0L
    if ($Element.TryGetInt64([ref]$n)) { return $n }
    $d = 0.0
    if ($Element.TryGetDouble([ref]$d) -and $d -eq [math]::Floor($d) -and [math]::Abs($d) -lt 9.2e18) { return [long]$d }
    $null
}

# The collector's JSON text -> a Stats value, or $null when the text does not
# parse or has no "backup" object (AppDelegate.parse). A missing or mistyped
# field keeps its Swift default. System.Text.Json rather than ConvertFrom-Json,
# which turns an ISO-8601-looking string into a DateTime and accepts comments;
# the Swift parse does neither.
function ConvertFrom-AvdTrayStatus {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { $doc = [System.Text.Json.JsonDocument]::Parse($Text) }
    catch { return $null }
    try {
        $root = $doc.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
        $backup = $null
        foreach ($p in $root.EnumerateObject()) { if ($p.Name -ceq 'backup') { $backup = $p.Value } }
        if ($null -eq $backup -or $backup.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
        # Keys compare ordinally, as a Swift dictionary's do: "Armed" is not "armed".
        $fields = [System.Collections.Generic.Dictionary[string, System.Text.Json.JsonElement]]::new([System.StringComparer]::Ordinal)
        foreach ($p in $backup.EnumerateObject()) { $fields[$p.Name] = $p.Value }
        $s = New-AvdTrayStatus
        $bools = [ordered]@{ armed = 'Armed'; emulator = 'Emulator'; confirmed = 'Confirmed'; running = 'Running' }
        foreach ($k in $bools.Keys) {
            if (-not $fields.ContainsKey($k)) { continue }
            $kind = $fields[$k].ValueKind
            if ($kind -eq [System.Text.Json.JsonValueKind]::True) { $s.($bools[$k]) = $true }
            elseif ($kind -eq [System.Text.Json.JsonValueKind]::False) { $s.($bools[$k]) = $false }
        }
        $ints = [ordered]@{
            staged = 'Staged'; remaining = 'Remaining'; on_device = 'OnDevice'; uploaded = 'Uploaded'
            queued = 'Queued'; failed = 'Failed'; upload_age = 'UploadAge'; confirmed_age = 'ConfirmedAge'
            last_run_age = 'LastRunAge'; reclaimed = 'Reclaimed'; reclaim_pending = 'ReclaimPending'
        }
        foreach ($k in $ints.Keys) {
            if (-not $fields.ContainsKey($k)) { continue }
            $n = ConvertFrom-AvdJsonInt -Element $fields[$k]
            if ($null -ne $n) { $s.($ints[$k]) = $n }
        }
        if ($fields.ContainsKey('phase') -and $fields['phase'].ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
            $s.Phase = $fields['phase'].GetString()
        }
        $s
    } finally { $doc.Dispose() }
}

# -- Formatting (compact, relAge) ----------------------------------------------

# The one decimal of compact() and relAge(), which use String(format: "%.1f").
# .NET's F1 gives the same digits: measured 2026-09-13 against a correctly
# rounded %.1f (ties to even on the exact binary value, as Apple's printf) for
# every n/1000 with n in 1000..9999 and every s/3600 with s in 3600..86399 --
# every value either function formats -- with no difference. Invariant
# culture, so a German desktop does not print "1,2k".
function Format-AvdOneDecimal {
    param([double]$Value)
    $Value.ToString('F1', [cultureinfo]::InvariantCulture)
}

# Compact count: 1234 -> "1.2k", 999 -> "999" (compact). Keeps the count a
# fixed narrow width no matter how large the library grows. 9960 reads
# "10.0k", as it does in the Swift: the k < 10 test is on the unrounded value.
function Format-AvdCompactCount {
    param([long]$Count)
    if ($Count -lt 1000) { return [string]$Count }
    $k = [double]$Count / 1000
    if ($k -lt 10) { return (Format-AvdOneDecimal $k) + 'k' }
    [string][long][math]::Truncate($k) + 'k'
}

# Relative age: "8s ago" / "3m ago" / "2.4h ago" (relAge). Integer division
# where the Swift divides Ints, so 119 s is "1m ago", never "2m ago".
function Format-AvdRelativeAge {
    param([long]$Seconds)
    if ($Seconds -lt 0) { return 'never' }
    if ($Seconds -lt 5) { return 'just now' }
    if ($Seconds -lt 60) { return "${Seconds}s ago" }
    if ($Seconds -lt 3600) { return "$([long][math]::Floor($Seconds / 60))m ago" }
    if ($Seconds -lt 86400) { return (Format-AvdOneDecimal ([double]$Seconds / 3600)) + 'h ago' }
    "$([long][math]::Floor($Seconds / 86400))d ago"
}

# -- The running step (enum RunStep) ----------------------------------------------

# The step a running sync is in, read off its phase line: the SIDE of the
# pipeline the batch is on. Kind is device (pushing, indexing, re-announcing,
# pruning), cloud (Google Photos confirming), offload (the iCloud reclaim),
# download (icloudpd's running tally) or busy (a step with no count). N and M
# are the first two whole numbers in the line, 0 when absent. The Swift splits
# on every non-number character, so "1,234" is 1 and 234 as it is here; a run
# too long for an Int is dropped by its compactMap and by TryParse here.
function Get-AvdRunStep {
    param([AllowEmptyString()][AllowNull()][string]$Phase)
    if ($null -eq $Phase) { $Phase = '' }
    $nums = [System.Collections.Generic.List[long]]::new()
    foreach ($m in [regex]::Matches($Phase, '[0-9]+')) {
        $v = 0L
        if ([long]::TryParse($m.Value, [System.Globalization.NumberStyles]::None, [cultureinfo]::InvariantCulture, [ref]$v)) { $nums.Add($v) }
    }
    $a = if ($nums.Count -gt 0) { $nums[0] } else { 0L }
    $b = if ($nums.Count -gt 1) { $nums[1] } else { 0L }
    $starts = { param([string]$Prefix) $Phase.StartsWith($Prefix, [System.StringComparison]::Ordinal) }
    if ((& $starts 'pushing ') -or (& $starts 'indexing in MediaStore') -or (& $starts 're-announcing') -or
        (& $starts 'reclaiming emulator space') -or (& $starts 'removing empty device files')) {
        return [pscustomobject]@{ Kind = 'device'; N = $a; M = $b }
    }
    if (& $starts 'waiting for MediaStore') { return [pscustomobject]@{ Kind = 'device'; N = 0L; M = 0L } }
    if (& $starts 'verifying uploads') { return [pscustomobject]@{ Kind = 'cloud'; N = $a; M = $b } }
    if (& $starts 'reclaiming iCloud space') { return [pscustomobject]@{ Kind = 'offload'; N = $a; M = 0L } }
    if (& $starts 'downloading') { return [pscustomobject]@{ Kind = 'download'; N = $a; M = 0L } }
    [pscustomobject]@{ Kind = 'busy'; N = 0L; M = 0L }
}

# -- The meter's own health (collectorSick) -------------------------------------

# Three missed 30 s ticks means the collector itself is failing or wedged, and
# so does no good collection for 150 s. -SecondsSinceGood is $null before the
# first good one. The host measures it on a monotonic clock that keeps counting
# through sleep (Environment.TickCount64); the Swift uses Date(), and after a
# sleep the two agree.
function Test-AvdCollectorSick {
    param([int]$FailStreak, [Nullable[double]]$SecondsSinceGood)
    if ($FailStreak -ge 3) { return $true }
    if ($null -eq $SecondsSinceGood) { return $false }
    $SecondsSinceGood -gt 150
}

# -- The ring (render()) --------------------------------------------------------

function New-AvdTrayRingState {
    param(
        [ValidateSet('red', 'orange', 'yellow', 'blue', 'purple', 'green', 'dim')][string]$Tint = 'dim',
        [double]$Fraction = 0,
        [ValidateSet('none', 'check', 'exclaim')][string]$Mark = 'none',
        [bool]$Spin = $false,
        [AllowEmptyString()][string]$Text = ''
    )
    # ring() clamps the fraction at draw time; clamped here so every consumer
    # (the key, the geometry, a test) sees the value that is drawn.
    [pscustomobject]@{ Tint = $Tint; Fraction = [math]::Min(1.0, [math]::Max(0.0, $Fraction)); Mark = $Mark; Spin = $Spin; Text = $Text }
}

# What the icon shows, worst condition first (render()): a collector that
# cannot report, dormant, failed uploads, a run in flight (its own step:
# progress where the step has a count, a spin where it does not), a pipeline
# that stopped tracking reality, a batch on the device, a waiting backlog, and
# only when the confirmation stamp vouches for it, the green check. -Stats is
# $null until the first good collection (haveStats). Text is the count the Mac
# draws beside the ring; a tray icon has no room for one, so the host puts it
# in the tooltip (Format-AvdTrayTooltip).
function Get-AvdTrayState {
    param($Stats, [bool]$CollectorSick)
    $haveStats = $null -ne $Stats
    if ($CollectorSick -or -not $haveStats) {
        $mark = if ($haveStats) { 'exclaim' } else { 'none' }
        return New-AvdTrayRingState -Tint red -Mark $mark
    }
    $s = $Stats
    # Dormant: installed and scheduled, doing nothing by design. A dim ring, no
    # count, and the menu says how to arm it.
    if (-not $s.Armed) { return New-AvdTrayRingState -Tint dim }
    if ($s.Failed -gt 0) {
        return New-AvdTrayRingState -Tint red -Fraction ([math]::Max($s.UploadFraction, 0.06)) -Mark exclaim -Text (Format-AvdCompactCount $s.Failed)
    }
    if ($s.Running) {
        $step = Get-AvdRunStep -Phase $s.Phase
        $n = $step.N; $m = $step.M
        $remainingText = if ($s.Remaining -gt 0) { Format-AvdCompactCount $s.Remaining } else { '' }
        switch ($step.Kind) {
            { $_ -in 'device', 'cloud' } {
                $tint = if ($step.Kind -eq 'device') { 'yellow' } else { 'blue' }
                $text = if ($m -gt 0) { "$n/$m" } else { '' }
                if ($m -gt 0 -and $n -gt 0) { return New-AvdTrayRingState -Tint $tint -Fraction ([double]$n / [double]$m) -Text $text }
                return New-AvdTrayRingState -Tint $tint -Spin $true -Text $text
            }
            'offload' {
                $text = if ($n -gt 0) { Format-AvdCompactCount $n } else { '' }
                return New-AvdTrayRingState -Tint purple -Spin $true -Text $text
            }
            'download' {
                $text = if ($n -gt 0) { Format-AvdCompactCount $n } else { $remainingText }
                return New-AvdTrayRingState -Tint dim -Spin $true -Text $text
            }
            default { return New-AvdTrayRingState -Tint dim -Spin $true -Text $remainingText }
        }
    }
    if ($s.BackupStale) {
        $fraction = if ($s.OnDevice -gt 0) { [math]::Max($s.UploadFraction, 0.06) } else { 1.0 }
        $text = if ($s.OnDevice -gt 0) { "$($s.Uploaded)/$($s.OnDevice)" } else { '' }
        return New-AvdTrayRingState -Tint orange -Fraction $fraction -Mark exclaim -Text $text
    }
    if ($s.OnDevice -gt 0) {
        # A batch is in flight: uploaded/onDevice is bounded (DCIM is pruned
        # after each confirm), so this never balloons with the library size.
        $stalled = $s.BackupStalled
        $tint = if ($stalled) { 'yellow' } else { 'blue' }
        $floor = if ($stalled) { 0.06 } else { 0.0 }
        return New-AvdTrayRingState -Tint $tint -Fraction ([math]::Max($s.UploadFraction, $floor)) -Text "$($s.Uploaded)/$($s.OnDevice)"
    }
    # Backlog waiting for the next run: the backlog, not the ever-growing
    # staged total.
    if ($s.Remaining -gt 0) { return New-AvdTrayRingState -Tint dim -Text (Format-AvdCompactCount $s.Remaining) }
    # Everything staged is pushed AND the verify pass confirmed it server-side.
    if ($s.BackupDone) { return New-AvdTrayRingState -Tint green -Fraction 1 -Mark check }
    # Counts look complete but the confirmation stamp is absent: the last
    # verify failed or was cleared. This must NOT render green.
    if ($s.BackupUnverified) { return New-AvdTrayRingState -Tint yellow -Fraction 1 -Mark exclaim }
    New-AvdTrayRingState -Tint dim
}

# The indeterminate arc's next start angle (the spinner timer's step): 20
# degrees clockwise every tick, wrapped so it cycles through 18 values from 90
# down to -250. Degrees are AppKit's (counter-clockwise from 3 o'clock).
function Step-AvdSpinAngle {
    param([double]$Angle)
    $a = $Angle - 20
    if ($a -le -270) { $a += 360 }
    $a
}

# The fraction in 36ths, the resolution the icon cache keys on (10 degrees of
# arc, under a pixel at 16 px). A non-zero fraction keeps at least one step and
# an unfinished one stops a step short of the full ring, so a batch at 0.5%
# still shows an arc and one at 99.5% never reads as complete.
function Get-AvdTrayFractionBucket {
    param([double]$Fraction)
    $f = [math]::Min(1.0, [math]::Max(0.0, $Fraction))
    $b = [int][math]::Round($f * 36, [System.MidpointRounding]::AwayFromZero)
    if ($f -gt 0 -and $b -lt 1) { $b = 1 }
    if ($f -lt 1 -and $b -gt 35) { $b = 35 }
    $b
}

# The icon cache key: tint, fraction bucket, mark, and the spin angle only while
# spinning. Bounded by construction -- 7 tints x 37 buckets x 3 marks, plus 7
# tints x 18 angles -- so the cache cannot grow without limit however long the
# tray runs.
function Get-AvdTrayIconKey {
    param([Parameter(Mandatory)]$State, [double]$SpinAngle = 90)
    $angle = if ($State.Spin) { [string][int][math]::Round($SpinAngle) } else { '-' }
    $bucket = if ($State.Spin) { 0 } else { Get-AvdTrayFractionBucket $State.Fraction }
    '{0}|{1}|{2}|{3}' -f $State.Tint, $bucket, $State.Mark, $angle
}

# The ring's geometry for a square icon of -Size pixels, in GDI+ terms (pixel
# coordinates, y down; angles clockwise from 3 o'clock), mirroring ring(). The
# Mac ring on a 22 pt bar is 19 pt wide with radius 7.5, stroke 2.2 and mark
# stroke 1.8; those proportions are kept and scaled to the icon.
#   Arc       the tinted arc: the fraction from 12 o'clock clockwise, or a
#             100-degree spinner at the spin angle; $null when nothing is drawn.
#   Lines     the mark's strokes (point lists); Dot the exclamation's dot.
# One difference: the Swift strokes a zero-length arc when a mark is shown at
# fraction 0 (the red "meter not refreshing" ring); whether AppKit leaves a
# round-capped dot for it was never looked at, and here nothing is drawn.
function Get-AvdRingGeometry {
    param([Parameter(Mandatory)][int]$Size, [Parameter(Mandatory)]$State, [double]$SpinAngle = 90)
    $scale = $Size / 19.0
    $c = $Size / 2.0
    $r = 7.5 * $scale
    $arc = $null
    if ($State.Spin) {
        # AppKit's s -> s-100 clockwise, with y flipped.
        $arc = [pscustomobject]@{ Start = -$SpinAngle; Sweep = 100.0 }
    } else {
        $sweep = 360.0 * (Get-AvdTrayFractionBucket $State.Fraction) / 36
        if ($sweep -gt 0) { $arc = [pscustomobject]@{ Start = -90.0; Sweep = $sweep } }
    }
    $pt = { param([double]$dx, [double]$dy) , @(($c + $dx * $r), ($c + $dy * $r)) }
    $lines = @()
    $dot = $null
    if ($State.Mark -eq 'check') {
        $lines = @(, @((& $pt -0.42 -0.02), (& $pt -0.10 0.32), (& $pt 0.48 -0.36)))
    } elseif ($State.Mark -eq 'exclaim') {
        $lines = @(, @((& $pt 0 -0.5), (& $pt 0 0.1)))
        $dot = [pscustomobject]@{ X = $c; Y = $c + 0.55 * $r; Diameter = 0.28 * $r }
    }
    [pscustomobject]@{
        Size      = $Size
        Center    = $c
        Radius    = $r
        LineWidth = 2.2 * $scale
        MarkWidth = 1.8 * $scale
        Arc       = $arc
        Lines     = $lines
        Dot       = $dot
    }
}

# -- Colour (muted()) -----------------------------------------------------------

# An ARGB value as the signed 32-bit int Color.FromArgb takes.
function ConvertTo-AvdArgb {
    param([int]$Red, [int]$Green, [int]$Blue, [int]$Alpha = 255)
    ($Alpha -shl 24) -bor ($Red -shl 16) -bor ($Green -shl 8) -bor $Blue
}

# The ring's tints as ARGB ints. Everything drawn in the Mac bar is a MUTED
# system colour -- 38% blended toward a 0.58 grey -- because full-saturation
# colour shouts next to monochrome icons and a meter is furniture, not an
# alert box; the mark carries the alarm, colour only names it. The same blend
# is applied here to the macOS light-appearance system colours. `dim` stands
# in for tertiaryLabelColor, which is a translucent label colour that adapts
# to the bar; a tray icon cannot adapt, so it is a mid grey that reads on a
# light and a dark taskbar alike, and `track` is that grey at 40% alpha. The
# Mac's dim spinner is visible only because two translucent strokes overlap;
# an opaque dim arc over a translucent track keeps that look.
function Get-AvdTrayPalette {
    $grey = 0.58 * 255
    $mute = { param([int]$r, [int]$g, [int]$b)
        $f = { param([int]$v) [int][math]::Round($v * (1 - 0.38) + $grey * 0.38, [System.MidpointRounding]::AwayFromZero) }
        ConvertTo-AvdArgb (& $f $r) (& $f $g) (& $f $b)
    }
    [ordered]@{
        red    = & $mute 255 59 48
        orange = & $mute 255 149 0
        yellow = & $mute 255 204 0
        blue   = & $mute 0 122 255
        purple = & $mute 175 82 222
        green  = & $mute 52 199 89
        dim    = ConvertTo-AvdArgb 128 128 128
        track  = ConvertTo-AvdArgb 128 128 128 102
    }
}

# Menu note colours. The Mac menu keeps the stock system colours for text; a
# WinForms context menu is always drawn light, so these are the Windows 11
# light-theme status colours (critical, caution, accent, success), which keep
# a readable contrast on it. `secondary` is SystemColors.GrayText in the host,
# so it follows a high-contrast theme.
function Get-AvdTrayTextColor {
    [ordered]@{
        red    = ConvertTo-AvdArgb 196 43 28
        orange = ConvertTo-AvdArgb 157 93 0
        blue   = ConvertTo-AvdArgb 0 95 184
        green  = ConvertTo-AvdArgb 15 123 15
    }
}

# -- The menu (buildMenu()) -----------------------------------------------------

# The ONE coloured status line stating THE conclusion. A run in flight reports
# its own step, and a run that could not do its job leaves the reason behind;
# both beat the derived states, which cannot tell "downloading for two hours"
# from "stopped". Returns { Text; Color } with Color secondary|red|orange|blue|green.
function Get-AvdTrayStatusNote {
    param($Stats, [AllowEmptyString()][AllowNull()][string]$LastError, [bool]$CollectorSick)
    $note = { param([string]$t, [string]$c = 'secondary') [pscustomobject]@{ Text = $t; Color = $c } }
    if ($null -eq $Stats) {
        if ($LastError) { return & $note $LastError 'red' }
        return & $note 'Collecting...'
    }
    $s = $Stats
    if ($CollectorSick) {
        $why = if ($LastError) { $LastError } else { 'collector silent' }
        return & $note "Meter not refreshing -- $why" 'red'
    }
    if ($s.Running) {
        $what = if ($s.Phase) { $s.Phase } else { 'sync in progress' }
        return & $note "Running -- $what" 'blue'
    }
    if ($s.Phase.StartsWith('failed:', [System.StringComparison]::Ordinal)) {
        return & $note ('Last run failed -- ' + $s.Phase.Substring(7).Trim([char]' ', [char]"`t")) 'orange'
    }
    if ($s.Failed -gt 0) {
        $plural = if ($s.Failed -eq 1) { '' } else { 's' }
        return & $note "$($s.Failed) upload$plural permanently failed" 'red'
    }
    if ($s.BackupStale) {
        if ($s.OnDevice -gt 0 -and $s.UploadAge -gt 3600) { $why = "sync died mid-upload -- verifier silent $(Format-AvdRelativeAge $s.UploadAge)" }
        elseif ($s.LastRunAge -lt 0) { $why = 'the sync job has never run' }
        else { $why = "sync job silent $(Format-AvdRelativeAge $s.LastRunAge)" }
        return & $note "Stale -- $why" 'orange'
    }
    if ($s.OnDevice -gt 0) {
        if ($s.BackupStalled) { return & $note 'Stalled -- nothing reaching the server' 'orange' }
        return & $note "Uploading $($s.Uploaded) of $($s.OnDevice)"
    }
    if ($s.Remaining -gt 0) { return & $note "$($s.Remaining) waiting for the next sync run" }
    if ($s.BackupDone) { return & $note "All backed up - verified $(Format-AvdRelativeAge $s.ConfirmedAge)" 'green' }
    if ($s.BackupUnverified) { return & $note 'Unverified -- the last sync could not confirm uploads' 'orange' }
    & $note 'Nothing staged yet'
}

# The menu, rebuilt at every open so ages are computed when eyes are on them
# (buildMenu()): the same rows, texts, conditions and order. Each item is
# { Kind (header|note|mono|action|separator); Text; Color (notes); Label and
# Value (mono); Action (openAvd|offload|check|refresh|quit); Key (the Mac key
# equivalent, which the host turns into a mnemonic) }.
#   -SyncAvailable     the sync script exists (the Swift's !syncScript.isEmpty)
#   -OpenAvdAvailable  the Start Menu shortcut "Google Photos (AVD).lnk" exists
#                      (the Swift checks for the .app in /Applications)
#   -Offloading        an offload run started from this menu is in flight
function Get-AvdTrayMenu {
    param(
        $Stats,
        [AllowEmptyString()][AllowNull()][string]$LastError,
        [bool]$CollectorSick,
        [bool]$Offloading,
        [bool]$SyncAvailable,
        [bool]$OpenAvdAvailable
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $add = { param([hashtable]$h)
        $o = [ordered]@{ Kind = $h.Kind; Text = ''; Color = ''; Label = ''; Value = ''; Action = ''; Key = '' }
        foreach ($k in $h.Keys) { $o[$k] = $h[$k] }
        $items.Add([pscustomobject]$o)
    }
    $haveStats = $null -ne $Stats
    # Before the first good collection the ledger shows a default Stats, as
    # the Swift's does.
    $s = if ($haveStats) { $Stats } else { New-AvdTrayStatus }

    & $add @{ Kind = 'header'; Text = 'iCloud -> Google Photos' }
    $status = Get-AvdTrayStatusNote -Stats $Stats -LastError $LastError -CollectorSick $CollectorSick
    & $add @{ Kind = 'note'; Text = $status.Text; Color = $status.Color }
    if ($haveStats -and -not $s.Armed) {
        & $add @{ Kind = 'note'; Text = 'Dormant -- run avd-photos-arm -Yes to enable the sync'; Color = 'orange' }
    }

    & $add @{ Kind = 'separator' }
    # Aligned "label  value" rows. The pad width must exceed the longest label
    # or label and value fuse into one word.
    $mono = { param([string]$label, [string]$value)
        & $add @{ Kind = 'mono'; Label = $label; Value = $value; Text = $label.PadRight(12) + $value }
    }
    & $mono 'Staged' "$($s.Staged)"
    & $mono 'Backlog' $(if ($s.Remaining -eq 0) { 'caught up' } else { "$($s.Remaining)" })
    if ($s.Emulator -or $s.OnDevice -gt 0) {
        $queued = if ($s.Queued -gt 0) { " ($($s.Queued) queued)" } else { '' }
        & $mono 'On device' "$($s.OnDevice)$queued"
    }
    # The count belongs to the batch the status was written for: once a newer
    # push exists the collector drops it (UploadAge -1), so only the stamp's
    # age is left to show; a verify pass in flight shows its own.
    if (-not $s.Confirmed) { $verified = 'NOT confirmed' }
    elseif ($s.Running -and $s.OnDevice -gt 0) { $verified = "$($s.Uploaded) of $($s.OnDevice) so far" }
    elseif ($s.UploadAge -lt 0) { $verified = "last batch $(Format-AvdRelativeAge $s.ConfirmedAge)" }
    else { $verified = "$($s.Uploaded) - $(Format-AvdRelativeAge $s.ConfirmedAge)" }
    & $mono 'Verified' $verified
    $pending = if ($s.ReclaimPending -gt 0) { " - $($s.ReclaimPending) confirmed, pending" } else { '' }
    & $mono 'iCloud' "$($s.Reclaimed) freed$pending"
    & $mono 'Last run' $(if ($s.Running) { 'running now' } else { Format-AvdRelativeAge $s.LastRunAge })
    & $mono 'Emulator' $(if ($s.Emulator) { 'running' } else { 'stopped' })

    & $add @{ Kind = 'separator' }
    if ($OpenAvdAvailable) { & $add @{ Kind = 'action'; Text = 'Open Google Photos (AVD)'; Action = 'openAvd' } }
    # Manual iCloud reclaim, offered ONLY once Google Photos' own database has
    # confirmed the batch (Confirmed is the last-upload-confirmed stamp): it
    # deletes from the real photo library, so the button must not exist in a
    # state where the pipeline has not proven itself. The sync re-checks the
    # same stamp, so the gate is enforced twice.
    if ($SyncAvailable -and $s.Armed) {
        if ($Offloading) { & $add @{ Kind = 'note'; Text = 'Offloading from iCloud...'; Color = 'secondary' } }
        elseif ($s.Running) { & $add @{ Kind = 'note'; Text = 'Offload unavailable while a sync is running'; Color = 'secondary' } }
        elseif ($s.Confirmed) { & $add @{ Kind = 'action'; Text = 'Offload from iCloud'; Action = 'offload' } }
        else { & $add @{ Kind = 'note'; Text = 'Offload unavailable -- no confirmed upload yet'; Color = 'secondary' } }
    }
    # The manual trigger: the same check the 15-minute tick runs. While a run
    # is alive the top line already says what it is doing.
    if ($s.Armed -and -not $s.Running) { & $add @{ Kind = 'action'; Text = 'Check iCloud now'; Action = 'check' } }
    elseif ($s.Armed) { & $add @{ Kind = 'note'; Text = 'Checking -- a sync run is in progress'; Color = 'secondary' } }
    & $add @{ Kind = 'action'; Text = 'Refresh Now'; Action = 'refresh'; Key = 'r' }
    & $add @{ Kind = 'separator' }
    & $add @{ Kind = 'action'; Text = 'Quit Photo Sync'; Action = 'quit'; Key = 'q' }
    , $items.ToArray()
}

# A menu row's text for a ToolStripItem, which reads '&' as a mnemonic prefix:
# a literal '&' (a phase line can carry one) is doubled, and -Key marks its
# first occurrence as the mnemonic -- the Windows form of the Mac key
# equivalent, pressed while the menu is open.
function ConvertTo-AvdMenuText {
    param([AllowEmptyString()][string]$Text, [AllowEmptyString()][string]$Key = '')
    $t = $Text.Replace('&', '&&')
    if ($Key) {
        $i = $t.IndexOf($Key, [System.StringComparison]::OrdinalIgnoreCase)
        if ($i -ge 0) { $t = $t.Insert($i, '&') }
    }
    $t
}

# The tooltip: 'Photo Sync - <the status note>', with the ring's count after
# the name when there is one. The Mac bar draws that count beside the ring; a
# notification-area icon has no room for text, so the tooltip is the only
# place it can go, and it comes BEFORE the note so a long phase line is what
# the truncation cuts. NotifyIcon.Text throws past 63 characters on .NET
# Framework; whether the WinForms that pwsh 7 loads allows more was not
# checked, so 63 is the limit kept, the last three spent on '...'.
function Format-AvdTrayTooltip {
    param([AllowEmptyString()][string]$Note, [AllowEmptyString()][string]$Count = '')
    $t = if ($Count) { "Photo Sync $Count - $Note" } else { "Photo Sync - $Note" }
    if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + '...' }
    $t
}

# -- The icon container ----------------------------------------------------------

# An .ico file's bytes from PNG images: ICONDIR (reserved 0, type 1, count),
# one 16-byte ICONDIRENTRY per image (width and height as a byte, 0 meaning
# 256; no palette; one plane; 32 bits per pixel; the PNG's length and its
# offset), then the PNGs in the same order. Built in memory so the host can
# load a System.Drawing.Icon from a stream: an icon made with Bitmap.GetHicon()
# owns an HICON nobody frees, and a spinner drawing eight frames a second would
# spend the process's 10,000 GDI handles in about twenty minutes (DESIGN.md
# decision 1). PNG entries are the Vista-and-later ICO form.
# -Image: objects with Width, Height and Data (the PNG bytes).
function ConvertTo-AvdIcoByte {
    param([Parameter(Mandatory)][object[]]$Image)
    if ($Image.Count -lt 1 -or $Image.Count -gt 65535) { throw "ConvertTo-AvdIcoByte: $($Image.Count) images" }
    $ms = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($ms)
    try {
        $w.Write([uint16]0)
        $w.Write([uint16]1)
        $w.Write([uint16]$Image.Count)
        $offset = 6 + 16 * $Image.Count
        foreach ($img in $Image) {
            foreach ($d in @($img.Width, $img.Height)) {
                if ($d -lt 1 -or $d -gt 256) { throw "ConvertTo-AvdIcoByte: dimension $d is outside 1..256" }
            }
            $len = ([byte[]]$img.Data).Length
            $w.Write([byte]($img.Width % 256))
            $w.Write([byte]($img.Height % 256))
            $w.Write([byte]0)
            $w.Write([byte]0)
            $w.Write([uint16]1)
            $w.Write([uint16]32)
            $w.Write([uint32]$len)
            $w.Write([uint32]$offset)
            $offset += $len
        }
        foreach ($img in $Image) { $w.Write([byte[]]$img.Data) }
        $w.Flush()
        , $ms.ToArray()
    } finally {
        $w.Dispose()
        $ms.Dispose()
    }
}
