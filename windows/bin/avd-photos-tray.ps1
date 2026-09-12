#Requires -Version 7.2
<#
.SYNOPSIS
The notification-area face of the iCloud -> Google Photos pipeline: Photo
Sync.app's ring and menu, on Windows.

.DESCRIPTION
One tray icon: a progress ring that says which side of the pipeline the current
batch is on, and a menu with the ledger, the live phase line and the actions
that are safe to take by hand. It collects nothing itself -- avd-photos-status
emits the JSON and avd-photos-sync writes every number in it -- and it decides
nothing itself either: every state, row and gate comes from the model in
windows\lib\Tray.ps1, which mirrors Sources/main.swift and is tested on any OS.
This file only draws what the model returns and wires the clicks, the timers
and the child processes. WinForms NotifyIcon from PowerShell 7, so there is
nothing to compile (windows\DESIGN.md, decision 1).

Windows only. The installer's tray task starts it at logon; a second copy
replaces the first.

.EXAMPLE
pwsh -NoProfile -File windows\bin\avd-photos-tray.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -ErrorAction Stop
if ($IsWindows) { Add-Type -AssemblyName System.Windows.Forms, System.Drawing }

# The running tray's state, set by Start-AvdTrayHost. Every event handler runs
# on the UI thread and reaches it here.
$script:AvdTray = $null

# -- Drawing (ring()) ------------------------------------------------------------

# One ring frame, -Size pixels square. Get-AvdRingGeometry decides every
# coordinate; this only strokes them: the track in the translucent grey, the
# tinted arc with round caps, then the mark.
function New-AvdTrayRingBitmap {
    param([Parameter(Mandatory)][int]$Size, [Parameter(Mandatory)]$State, [double]$SpinAngle = 90)
    $geo = Get-AvdRingGeometry -Size $Size -State $State -SpinAngle $SpinAngle
    $palette = Get-AvdTrayPalette
    $tint = [System.Drawing.Color]::FromArgb([int]$palette[$State.Tint])
    $round = [System.Drawing.Drawing2D.LineCap]::Round
    $bmp = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $trackPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb([int]$palette['track']), [single]$geo.LineWidth)
    $arcPen = [System.Drawing.Pen]::new($tint, [single]$geo.LineWidth)
    $markPen = [System.Drawing.Pen]::new($tint, [single]$geo.MarkWidth)
    $brush = [System.Drawing.SolidBrush]::new($tint)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        # Pixel i covers [i, i+1], so the geometry's continuous coordinates
        # land where they say.
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        foreach ($p in @($arcPen, $markPen)) {
            $p.StartCap = $round
            $p.EndCap = $round
            $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        }
        $d = [single](2 * $geo.Radius)
        $corner = [single]($geo.Center - $geo.Radius)
        $rect = [System.Drawing.RectangleF]::new($corner, $corner, $d, $d)
        $g.DrawEllipse($trackPen, $rect)
        if ($null -ne $geo.Arc) { $g.DrawArc($arcPen, $rect, [single]$geo.Arc.Start, [single]$geo.Arc.Sweep) }
        foreach ($line in $geo.Lines) {
            $pts = [System.Drawing.PointF[]]@(foreach ($pt in $line) { [System.Drawing.PointF]::new([single]$pt[0], [single]$pt[1]) })
            $g.DrawLines($markPen, $pts)
        }
        if ($null -ne $geo.Dot) {
            $dd = [single]$geo.Dot.Diameter
            $g.FillEllipse($brush, [single]($geo.Dot.X - $dd / 2), [single]($geo.Dot.Y - $dd / 2), $dd, $dd)
        }
    } catch {
        $bmp.Dispose()
        throw
    } finally {
        $g.Dispose()
        $trackPen.Dispose()
        $arcPen.Dispose()
        $markPen.Dispose()
        $brush.Dispose()
    }
    $bmp
}

function ConvertTo-AvdTrayPngByte {
    param([Parameter(Mandatory)]$Bitmap)
    $ms = [System.IO.MemoryStream]::new()
    try {
        $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        , $ms.ToArray()
    } finally { $ms.Dispose() }
}

# The Icon for a state, built once per cache key (Get-AvdTrayIconKey, which
# bounds the cache) and reused. Four frames -- 16, 20 and 24 px are the small
# icon at 100, 125 and 150% scaling, 32 px at 200% -- wrapped as an in-memory
# .ico and loaded at the size the notification area asks for; loading without
# a size would pick the 32 px frame and let the shell shrink it. Never
# Bitmap.GetHicon(): each call leaks an HICON, and at eight spinner frames a
# second that would spend the process's 10,000 GDI handles in about twenty
# minutes (DESIGN.md decision 1). An Icon loaded from a stream owns its handle
# and frees it on Dispose.
function Get-AvdTrayIcon {
    param([Parameter(Mandatory)][hashtable]$Cache, [Parameter(Mandatory)]$State, [double]$SpinAngle = 90)
    $key = Get-AvdTrayIconKey -State $State -SpinAngle $SpinAngle
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    $frames = foreach ($size in 16, 20, 24, 32) {
        $bmp = New-AvdTrayRingBitmap -Size $size -State $State -SpinAngle $SpinAngle
        try { [pscustomobject]@{ Width = $size; Height = $size; Data = (ConvertTo-AvdTrayPngByte -Bitmap $bmp) } }
        finally { $bmp.Dispose() }
    }
    $bytes = ConvertTo-AvdIcoByte -Image @($frames)
    $ms = [System.IO.MemoryStream]::new($bytes)
    try { $icon = [System.Drawing.Icon]::new($ms, [System.Windows.Forms.SystemInformation]::SmallIconSize) }
    finally { $ms.Dispose() }
    $Cache[$key] = $icon
    $icon
}

function Clear-AvdTrayIconCache {
    param([Parameter(Mandatory)][hashtable]$Cache)
    foreach ($icon in @($Cache.Values)) { $icon.Dispose() }
    $Cache.Clear()
}

# -- The menu (buildMenu()) ------------------------------------------------------

# One ToolStripItem for one model row. The Mac's header, notes and ledger rows
# are disabled NSMenuItems whose attributed titles keep their own colours; a
# disabled WinForms menu item is always painted grey, which would erase the
# one coloured status line, so those rows are ToolStripLabels instead: not
# selectable, not clickable, and drawn in the colour given. Actions are menu
# items carrying their action id in Tag.
function New-AvdTrayMenuItem {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][hashtable]$Font, [scriptblock]$OnClick)
    switch ($Item.Kind) {
        'separator' { return [System.Windows.Forms.ToolStripSeparator]::new() }
        'action' {
            $mi = [System.Windows.Forms.ToolStripMenuItem]::new((ConvertTo-AvdMenuText -Text $Item.Text -Key $Item.Key))
            $mi.Tag = $Item.Action
            if ($OnClick) { $mi.add_Click($OnClick) }
            return $mi
        }
        default {
            $label = [System.Windows.Forms.ToolStripLabel]::new((ConvertTo-AvdMenuText -Text $Item.Text))
            $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            if ($Item.Kind -eq 'header') {
                $label.Font = $Font.Header
            } elseif ($Item.Kind -eq 'mono') {
                # The ledger's label is padded to 12 columns by the model; a
                # monospaced face is what makes the values line up.
                $label.Font = $Font.Mono
            } elseif ($Item.Color -eq 'secondary' -or [System.Windows.Forms.SystemInformation]::HighContrast) {
                # A high-contrast theme picks its own colours; fixed ones would
                # fight it.
                $label.ForeColor = [System.Drawing.SystemColors]::GrayText
            } else {
                $label.ForeColor = [System.Drawing.Color]::FromArgb([int](Get-AvdTrayTextColor)[$Item.Color])
            }
            return $label
        }
    }
}

# Replace the menu's rows with the model's. The old rows are disposed, not
# just dropped: the menu is rebuilt on every open.
function Update-AvdTrayMenu {
    param([Parameter(Mandatory)]$Menu, [Parameter(Mandatory)][object[]]$Model, [Parameter(Mandatory)][hashtable]$Font, [scriptblock]$OnClick)
    $old = @($Menu.Items)
    $Menu.SuspendLayout()
    try {
        $Menu.Items.Clear()
        foreach ($o in $old) { $o.Dispose() }
        foreach ($i in $Model) { [void]$Menu.Items.Add((New-AvdTrayMenuItem -Item $i -Font $Font -OnClick $OnClick)) }
    } finally { $Menu.ResumeLayout() }
}

# The menu model for the tray's current state.
function Get-AvdTrayMenuModel {
    $t = $script:AvdTray
    $a = @{
        Stats            = $t.Stats
        LastError        = $t.LastError
        CollectorSick    = Test-AvdTraySick
        Offloading       = $t.Offloading
        SyncAvailable    = [bool]$t.SyncScript
        OpenAvdAvailable = Test-Path -LiteralPath $t.AvdShortcut -PathType Leaf
    }
    Get-AvdTrayMenu @a
}

# Open the menu on a left click too, as the Mac item opens on any click. Only
# NotifyIcon's own (private) ShowContextMenu does what a right click does --
# it makes the menu's owner the foreground window first, without which a
# click elsewhere does not close the menu -- so it is reached by reflection;
# if a WinForms release renames it, a left click simply does nothing.
function Show-AvdTrayMenu {
    param([Parameter(Mandatory)]$NotifyIcon)
    $m = $NotifyIcon.GetType().GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance, NonPublic')
    if ($null -ne $m) { [void]$m.Invoke($NotifyIcon, $null) }
}

# -- Collect (refresh()) -----------------------------------------------------------

function Test-AvdTraySick {
    $t = $script:AvdTray
    $since = if ($null -eq $t.LastGoodTick) { $null } else { ([System.Environment]::TickCount64 - $t.LastGoodTick) / 1000.0 }
    Test-AvdCollectorSick -FailStreak $t.FailStreak -SecondsSinceGood $since
}

# Start one collection: avd-photos-status.ps1 in a windowless pwsh, writing
# its JSON to a temp file. A file, not stdout: reading a redirected stream
# without blocking the UI needs its data events, which arrive on thread-pool
# threads where a PowerShell script block cannot run. HasExited is polled
# from a Forms timer instead (Update-AvdTrayCollection).
function Start-AvdTrayCollection {
    $t = $script:AvdTray
    if (-not $t.StatusScript) {
        $t.LastError = 'avd-photos-status not found'
        $t.FailStreak = $t.FailStreak + 1
        Update-AvdTrayView
        return
    }
    # One collection at a time: a wedged run must not pile new processes on
    # top of itself every tick. Liveness is kept by the watchdog below plus
    # collectorSick surfacing the gap.
    if ($null -ne $t.Collector) { return }
    $out = Join-Path ([System.IO.Path]::GetTempPath()) ('avd-photos-tray-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $p = Start-AvdDetachedProcess -FilePath $t.Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $t.StatusScript, '-OutFile', $out)
    } catch {
        Write-AvdTrayError $_
        $t.LastError = 'collector failed to start'
        $t.FailStreak = $t.FailStreak + 1
        Update-AvdTrayView
        return
    }
    $t.Collector = @{ Process = $p; OutFile = $out; StartedTick = [System.Environment]::TickCount64 }
    $t.Timers.Poll.Start()
}

# The 250 ms poll of a collection in flight, and its end: read, parse, and
# keep failStreak, lastGood and lastError exactly as the Swift does.
function Update-AvdTrayCollection {
    $t = $script:AvdTray
    $c = $t.Collector
    if ($null -eq $c) { $t.Timers.Poll.Stop(); return }
    if (-not $c.Process.HasExited) {
        # Watchdog. The status script bounds its own slow path (one adb call,
        # 6 s), so 25 s only trips when something is genuinely wedged; killing
        # it turns a silent freeze into a visible error state.
        if (([System.Environment]::TickCount64 - $c.StartedTick) -lt 25000) { return }
        try {
            $c.Process.Kill($true)
            [void]$c.Process.WaitForExit(2000)
        } catch { Write-AvdTrayError $_ }
    }
    $t.Timers.Poll.Stop()
    $t.Collector = $null
    $text = ''
    try {
        if (Test-Path -LiteralPath $c.OutFile -PathType Leaf) { $text = [System.IO.File]::ReadAllText($c.OutFile) }
    } catch { Write-AvdTrayError $_ }
    Remove-Item -LiteralPath $c.OutFile -Force -ErrorAction SilentlyContinue
    $c.Process.Dispose()
    $parsed = ConvertFrom-AvdTrayStatus -Text $text
    if ($null -ne $parsed) {
        $t.Stats = $parsed
        $t.LastError = $null
        $t.LastGoodTick = [System.Environment]::TickCount64
        $t.FailStreak = 0
    } else {
        $t.LastError = if ([string]::IsNullOrEmpty($text)) { 'collector timed out' } else { 'collector output unparseable' }
        $t.FailStreak = $t.FailStreak + 1
    }
    Update-AvdTrayView
}

# -- Render (render()) -------------------------------------------------------------

# Paint the icon and the tooltip from the model, and run the spinner only
# while a spinning state is on screen.
function Update-AvdTrayView {
    $t = $script:AvdTray
    $sick = Test-AvdTraySick
    $state = Get-AvdTrayState -Stats $t.Stats -CollectorSick $sick
    $icon = Get-AvdTrayIcon -Cache $t.Icons -State $state -SpinAngle $t.SpinAngle
    if (-not [object]::ReferenceEquals($t.Notify.Icon, $icon)) { $t.Notify.Icon = $icon }
    $note = Get-AvdTrayStatusNote -Stats $t.Stats -LastError $t.LastError -CollectorSick $sick
    $tip = Format-AvdTrayTooltip -Note $note.Text -Count $state.Text
    if ($t.Notify.Text -ne $tip) { $t.Notify.Text = $tip }
    if ($state.Spin) {
        if (-not $t.Timers.Spin.Enabled) { $t.Timers.Spin.Start() }
    } else {
        $t.Timers.Spin.Stop()
    }
}

# 8 fps is plenty for a 16 px arc; the timer runs only while a spinning step
# is shown.
function Invoke-AvdTraySpinner {
    $t = $script:AvdTray
    $t.SpinAngle = Step-AvdSpinAngle -Angle $t.SpinAngle
    Update-AvdTrayView
}

# Once a second: a newer copy asking this one to quit; an offload run that
# ended; and a wake from sleep. Windows tells a window about a resume through
# WM_POWERBROADCAST, and SystemEvents would raise it on a thread a script
# block cannot run on, so a wake is inferred instead: a one-second tick that
# arrives more than ten seconds late means the machine slept (or the UI thread
# was blocked, and a refresh is harmless then too). TickCount64 keeps counting
# through sleep, so the gap is the sleep. The Swift refreshes on
# didWakeNotification for the same reason: not to paint pre-sleep numbers for
# up to a full tick.
function Invoke-AvdTrayHeartbeat {
    $t = $script:AvdTray
    if ($t.QuitEvent.WaitOne(0)) {
        Write-AvdLog -Path $t.LogFile -Message 'tray: a newer copy asked this one to quit'
        Stop-AvdTrayHost
        return
    }
    $now = [System.Environment]::TickCount64
    $gap = $now - $t.LastBeatTick
    $t.LastBeatTick = $now
    if ($null -ne $t.OffloadProcess -and $t.OffloadProcess.HasExited) {
        $t.OffloadProcess.Dispose()
        $t.OffloadProcess = $null
        $t.Offloading = $false
        Start-AvdTrayCollection
    }
    if ($gap -gt 10000) { Start-AvdTrayCollection }
}

# -- Actions -----------------------------------------------------------------------

function Invoke-AvdTrayAction {
    param([Parameter(Mandatory)][string]$Action)
    switch ($Action) {
        'refresh' { Start-AvdTrayCollection }
        'check' { Invoke-AvdTrayCheck }
        'offload' { Invoke-AvdTrayOffload }
        'openAvd' { Invoke-AvdTrayOpenAvd }
        'quit' { Stop-AvdTrayHost }
        default { throw "unknown tray action '$Action'" }
    }
}

# Run the sync task now: the run is then Task Scheduler's, not this tray's,
# so quitting or replacing the tray cannot kill it mid-push (the Swift
# kickstarts the launchd agent for the same reason). Spawning the sync script
# from here is the fallback where the task is not registered; the script's
# lock turns a race with a scheduled tick into one skipped line. Refreshes
# three seconds later, when the run holds its lock.
function Invoke-AvdTrayCheck {
    $t = $script:AvdTray
    $kicked = $false
    try {
        $p = Start-AvdDetachedProcess -FilePath $t.Schtasks -ArgumentList @('/Run', '/TN', $t.SyncTaskName)
        try {
            # schtasks answers in well under a second; bounded, as a blocked UI
            # thread is a frozen menu.
            if ($p.WaitForExit(10000)) { $kicked = $p.ExitCode -eq 0 }
            else { $p.Kill() }
        } finally { $p.Dispose() }
    } catch { Write-AvdTrayError $_ }
    if (-not $kicked -and $t.SyncScript) {
        try { (Start-AvdDetachedProcess -FilePath $t.Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $t.SyncScript)).Dispose() }
        catch { Write-AvdTrayError $_ }
    }
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 3000
    $timer.add_Tick({
            param($s)
            $s.Stop()
            $s.Dispose()
            Invoke-AvdTrayGuarded { Start-AvdTrayCollection }
        })
    $timer.Start()
}

# Run the sync with reclaim forced on. Detached and non-blocking: an offload
# run downloads, pushes and waits on Google Photos, so it is minutes long. The
# in-flight flag keeps a second click from starting an overlapping run, and
# the heartbeat's refresh when it exits repaints the ledger from whatever the
# run achieved. The run's output goes to its own log, as on macOS.
function Invoke-AvdTrayOffload {
    $t = $script:AvdTray
    if ($t.Offloading -or -not $t.SyncScript) { return }
    $t.Offloading = $true
    try {
        $t.OffloadProcess = Start-AvdDetachedProcess -FilePath $t.Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $t.SyncScript, '-Offload')
    } catch {
        Write-AvdTrayError $_
        $t.Offloading = $false
        Start-AvdTrayCollection
    }
}

function Invoke-AvdTrayOpenAvd {
    $t = $script:AvdTray
    if (-not $t.AppScript) { return }
    (Start-AvdDetachedProcess -FilePath $t.Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $t.AppScript, '-Open')).Dispose()
}

# Ends Application.Run; Start-AvdTrayHost then disposes everything and exits.
function Stop-AvdTrayHost {
    [System.Windows.Forms.Application]::ExitThread()
}

# -- Errors ------------------------------------------------------------------------

# The tray has no console, so an error in a handler would otherwise vanish
# (or, unhandled, raise WinForms' exception dialog over the desktop). Each is
# one line in tray.log and the tray carries on.
function Write-AvdTrayError {
    param([Parameter(Mandatory)]$ErrorRecord)
    $t = $script:AvdTray
    if ($null -eq $t -or -not $t.LogFile) { return }
    $msg = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        "$($ErrorRecord.Exception.Message) (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    } else { [string]$ErrorRecord }
    Write-AvdLog -Path $t.LogFile -Message "tray: $msg"
}

function Invoke-AvdTrayGuarded {
    param([Parameter(Mandatory)][scriptblock]$Body, [object[]]$ArgumentList = @())
    try { $null = & $Body @ArgumentList } catch { Write-AvdTrayError $_ }
}

# -- The host --------------------------------------------------------------------

function Start-AvdTrayHost {
    if (-not $IsWindows) {
        [Console]::Error.WriteLine('avd-photos-tray: Windows only (macOS has Photo Sync.app)')
        exit 2
    }
    # WinForms menus need a single-threaded apartment. pwsh starts in one by
    # default; a caller that passed -MTA gets a copy of this script in STA,
    # waited on so a task that started this one still tracks the tray.
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        $p = Start-AvdDetachedProcess -FilePath ([System.Environment]::ProcessPath) -ArgumentList @('-STA', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath)
        $p.WaitForExit()
        exit $p.ExitCode
    }

    # SINGLE INSTANCE, NEWEST WINS. Any second copy -- a double-click, the
    # logon task after a manual start, a stale one -- puts a SECOND icon in the
    # notification area and everything appears twice. The Swift app terminates
    # older copies so a rebuilt one takes over; here the newcomer signals the
    # quit event, the incumbent's heartbeat sees it within a second and exits
    # cleanly (releasing the mutex last), and the newcomer waits up to 10 s
    # for the mutex. An abandoned mutex (a copy that crashed) is owned by
    # whoever next waits on it.
    $mutex = [System.Threading.Mutex]::new($false, 'Local\icloud-to-google-photos.tray')
    $quit = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, 'Local\icloud-to-google-photos.tray.quit')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        [void]$quit.Set()
        try { $owned = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    }
    if (-not $owned) {
        [Console]::Error.WriteLine('avd-photos-tray: the running copy did not quit within 10 s')
        $quit.Dispose()
        $mutex.Dispose()
        exit 1
    }
    # A signal this copy sent, if the incumbent quit before consuming it, must
    # not make this copy quit in turn.
    [void]$quit.Reset()

    $cfg = Get-AvdConfig -NoCreate
    $logFile = Join-Path $cfg.LOG_DIR 'tray.log'
    Initialize-AvdLog -Path $logFile

    # THE SCRIPTS ARE LOOKED UP IN ONE FIXED PLACE: this script's own
    # directory, never a path the environment names. On macOS whatever decides
    # WHAT the app runs decides what inherits the app's privacy grants, which
    # is why resolveScript ignores the environment (an AVD_PHOTOS_BIN_DIR once
    # let any caller pick the script). Windows has no per-app grant to protect,
    # but the answer is the same: the commands that belong to this tray are the
    # ones installed beside it, and a variable anyone can set is no way to say
    # which those are. Resolved once at launch, as the Swift does.
    $bin = $PSScriptRoot
    $resolve = { param([string]$name) $p = Join-Path $bin $name; if (Test-Path -LiteralPath $p -PathType Leaf) { $p } else { '' } }

    $script:AvdTray = @{
        Pwsh           = [System.Environment]::ProcessPath
        StatusScript   = & $resolve 'avd-photos-status.ps1'
        SyncScript     = & $resolve 'avd-photos-sync.ps1'
        AppScript      = & $resolve 'avd-photos-app.ps1'
        Schtasks       = Join-Path ([System.Environment]::SystemDirectory) 'schtasks.exe'
        SyncTaskName   = '\' + (Get-AvdLabelPrefix) + '.sync'
        AvdShortcut    = Join-Path ([System.Environment]::GetFolderPath('Programs')) 'Google Photos (AVD).lnk'
        LogFile        = $logFile
        QuitEvent      = $quit
        Stats          = $null
        LastError      = $null
        LastGoodTick   = $null
        FailStreak     = 0
        Collector      = $null
        Offloading     = $false
        OffloadProcess = $null
        # The indeterminate arc's start, advanced by the spinner.
        SpinAngle      = 90.0
        LastBeatTick   = [System.Environment]::TickCount64
        Icons          = @{}
        Timers         = @{}
        Font           = @{}
        Notify         = $null
        Menu           = $null
        OnClick        = $null
    }
    $t = $script:AvdTray

    try {
        # Before the first control: an exception a handler misses is logged,
        # not shown as WinForms' dialog.
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
        [System.Windows.Forms.Application]::add_ThreadException({
                param($s, $e)
                Invoke-AvdTrayGuarded { param($source, $err) Write-AvdTrayError "unhandled ($source): $($err.Exception.Message)" } -ArgumentList $s, $e
            })
        [void][System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware)
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $menu = [System.Windows.Forms.ContextMenuStrip]::new()
        # No image column: the Mac menu has none, and without it the label rows
        # and the action rows start at the same edge.
        $menu.ShowImageMargin = $false
        $t.Menu = $menu
        $t.Font.Header = [System.Drawing.Font]::new($menu.Font, [System.Drawing.FontStyle]::Bold)
        $t.Font.Mono = [System.Drawing.Font]::new('Consolas', $menu.Font.SizeInPoints)
        $t.OnClick = { param($s) Invoke-AvdTrayGuarded { param($item) Invoke-AvdTrayAction -Action ([string]$item.Tag) } -ArgumentList $s }
        # Rebuilt at every open so the ages are computed when eyes are on them
        # (menuNeedsUpdate), and a collection started, so the NEXT look is
        # fresh (menuWillOpen). An empty strip arrives here with Cancel set.
        $menu.add_Opening({
                param($s, $e)
                Invoke-AvdTrayGuarded { param($strip) Update-AvdTrayMenu -Menu $strip -Model (Get-AvdTrayMenuModel) -Font $script:AvdTray.Font -OnClick $script:AvdTray.OnClick } -ArgumentList $s
                $e.Cancel = $false
                Invoke-AvdTrayGuarded { Start-AvdTrayCollection }
            })

        $notify = [System.Windows.Forms.NotifyIcon]::new()
        $notify.ContextMenuStrip = $menu
        $notify.add_MouseUp({
                param($s, $e)
                if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-AvdTrayGuarded { param($icon) Show-AvdTrayMenu -NotifyIcon $icon } -ArgumentList $s }
            })
        $t.Notify = $notify

        # Every timer is a Forms timer, ticking on this UI thread: a PowerShell
        # script block cannot run on the thread-pool threads that
        # System.Timers.Timer, Process.Exited or Microsoft.Win32.SystemEvents
        # raise their events on. A Forms timer also keeps ticking while the
        # menu is open (the Swift adds its timers in .common mode for that).
        $newTimer = { param([int]$ms) $x = [System.Windows.Forms.Timer]::new(); $x.Interval = $ms; $x }
        $t.Timers.Refresh = & $newTimer 30000
        $t.Timers.Refresh.add_Tick({ Invoke-AvdTrayGuarded { Start-AvdTrayCollection } })
        $t.Timers.Spin = & $newTimer 125
        $t.Timers.Spin.add_Tick({ Invoke-AvdTrayGuarded { Invoke-AvdTraySpinner } })
        $t.Timers.Poll = & $newTimer 250
        $t.Timers.Poll.add_Tick({ Invoke-AvdTrayGuarded { Update-AvdTrayCollection } })
        $t.Timers.Heartbeat = & $newTimer 1000
        $t.Timers.Heartbeat.add_Tick({ Invoke-AvdTrayGuarded { Invoke-AvdTrayHeartbeat } })

        # The launch ring is the dim one, as the Swift's is, until the first
        # collection answers.
        $notify.Icon = Get-AvdTrayIcon -Cache $t.Icons -State (New-AvdTrayRingState -Tint dim)
        $notify.Text = Format-AvdTrayTooltip -Note 'Collecting...'
        Update-AvdTrayMenu -Menu $menu -Model (Get-AvdTrayMenuModel) -Font $t.Font -OnClick $t.OnClick
        $notify.Visible = $true

        Start-AvdTrayCollection
        $t.Timers.Refresh.Start()
        $t.Timers.Heartbeat.Start()
        [System.Windows.Forms.Application]::Run()
    } finally {
        foreach ($x in @($t.Timers.Values)) { $x.Stop(); $x.Dispose() }
        # A collection in flight is read-only and safe to stop; an offload run
        # is the sync itself and is left to finish, as a quit on macOS leaves it.
        if ($null -ne $t.Collector) {
            try { $t.Collector.Process.Kill($true) } catch { Write-AvdTrayError $_ }
            $t.Collector.Process.Dispose()
            Remove-Item -LiteralPath $t.Collector.OutFile -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $t.OffloadProcess) { $t.OffloadProcess.Dispose() }
        # Hide before disposing, or the icon lingers until the pointer passes over it.
        if ($null -ne $t.Notify) { $t.Notify.Visible = $false; $t.Notify.Dispose() }
        if ($null -ne $t.Menu) { $t.Menu.Dispose() }
        foreach ($f in @($t.Font.Values)) { $f.Dispose() }
        Clear-AvdTrayIconCache -Cache $t.Icons
        # Last, so a newcomer waiting on it never overlaps this copy's icon.
        $mutex.ReleaseMutex()
        $mutex.Dispose()
        $quit.Dispose()
    }
    exit 0
}

# Dot-sourced (the Windows tests do, to reach the drawing and the menu builder
# without a message loop): define the functions, run nothing.
if ($MyInvocation.InvocationName -eq '.') { return }
Start-AvdTrayHost
