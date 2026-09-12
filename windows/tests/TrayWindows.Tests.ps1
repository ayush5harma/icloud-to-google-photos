#Requires -Version 7.2
# The tray pieces that exist only on Windows: the ring frames System.Drawing
# draws, the .ico they become and the Icon it loads as, the menu WinForms
# builds from a model, the icon cache, and the "Check iCloud now" fallback
# (its delayed refresh is a Forms timer). Tagged WindowsOnly; CI runs them on
# windows-latest. Nothing here starts a message loop or shows an icon: the
# host is dot-sourced, which defines its functions and stops.

Describe 'the tray on Windows' -Tag 'WindowsOnly' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
        . (Join-Path $PSScriptRoot '..' 'bin' 'avd-photos-tray.ps1')
        $script:Palette = Get-AvdTrayPalette
        # The most opaque pixel within one pixel of the arc's midpoint. Only
        # the opaque tint reaches alpha 230 (the track is 40%), and taking the
        # best of the neighbourhood keeps the probe independent of how the
        # antialiasing falls on the pixel grid at each size.
        function Get-ArcPixel {
            param($Bitmap, [int]$Size, $State, [double]$SpinAngle = 90)
            $g = Get-AvdRingGeometry -Size $Size -State $State -SpinAngle $SpinAngle
            $mid = ($g.Arc.Start + $g.Arc.Sweep / 2) * [math]::PI / 180
            $x0 = [int][math]::Floor($g.Center + $g.Radius * [math]::Cos($mid))
            $y0 = [int][math]::Floor($g.Center + $g.Radius * [math]::Sin($mid))
            $best = $null
            foreach ($dx in -1, 0, 1) {
                foreach ($dy in -1, 0, 1) {
                    $x = $x0 + $dx; $y = $y0 + $dy
                    if ($x -lt 0 -or $y -lt 0 -or $x -ge $Size -or $y -ge $Size) { continue }
                    $px = $Bitmap.GetPixel($x, $y)
                    if ($null -eq $best -or $px.A -gt $best.A) { $best = $px }
                }
            }
            $best
        }
        function Assert-Tint {
            param($Pixel, [string]$Tint)
            $want = [System.Drawing.Color]::FromArgb([int]$Palette[$Tint])
            $Pixel.A | Should -BeGreaterOrEqual 230
            [math]::Abs($Pixel.R - $want.R) | Should -BeLessOrEqual 20
            [math]::Abs($Pixel.G - $want.G) | Should -BeLessOrEqual 20
            [math]::Abs($Pixel.B - $want.B) | Should -BeLessOrEqual 20
        }
        function New-TestIcoByte {
            param($State, [double]$SpinAngle = 90)
            $frames = foreach ($size in 16, 20, 24, 32) {
                $bmp = New-AvdTrayRingBitmap -Size $size -State $State -SpinAngle $SpinAngle
                try { [pscustomobject]@{ Width = $size; Height = $size; Data = (ConvertTo-AvdTrayPngByte -Bitmap $bmp) } }
                finally { $bmp.Dispose() }
            }
            , (ConvertTo-AvdIcoByte -Image @($frames))
        }
    }

    It 'draws the fraction arc in its tint, over a transparent centre, at <size> px' -ForEach @(@{ size = 16 }, @{ size = 20 }, @{ size = 24 }, @{ size = 32 }) {
        $state = New-AvdTrayRingState -Tint blue -Fraction 0.5
        $bmp = New-AvdTrayRingBitmap -Size $size -State $state
        try {
            $bmp.Width | Should -Be $size
            $bmp.Height | Should -Be $size
            Assert-Tint (Get-ArcPixel $bmp $size $state) 'blue'
            $c = [int][math]::Floor($size / 2)
            $bmp.GetPixel($c, $c).A | Should -Be 0
        } finally { $bmp.Dispose() }
    }

    It 'draws the spinner arc at the spin angle, at <size> px' -ForEach @(@{ size = 16 }, @{ size = 32 }) {
        $state = New-AvdTrayRingState -Tint purple -Spin $true
        $bmp = New-AvdTrayRingBitmap -Size $size -State $state -SpinAngle -110
        try { Assert-Tint (Get-ArcPixel $bmp $size $state -110) 'purple' }
        finally { $bmp.Dispose() }
    }

    It 'draws the track alone, translucent, when there is no arc' {
        $state = New-AvdTrayRingState -Tint dim
        $bmp = New-AvdTrayRingBitmap -Size 32 -State $state
        try {
            $g = Get-AvdRingGeometry -Size 32 -State $state
            # 9 o'clock, on the track.
            $px = $bmp.GetPixel([int][math]::Floor($g.Center - $g.Radius), [int][math]::Floor($g.Center))
            $px.A | Should -BeGreaterThan 40
            $px.A | Should -BeLessThan 160
        } finally { $bmp.Dispose() }
    }

    It 'draws the check and the exclamation in the tint' {
        foreach ($case in @(@{ Mark = 'check'; Tint = 'green' }, @{ Mark = 'exclaim'; Tint = 'orange' })) {
            $state = New-AvdTrayRingState -Tint $case.Tint -Fraction 1 -Mark $case.Mark
            $bmp = New-AvdTrayRingBitmap -Size 32 -State $state
            try {
                $g = Get-AvdRingGeometry -Size 32 -State $state
                $pts = @($g.Lines)[0]
                # Midway along the mark's first stroke.
                $x = [int][math]::Floor(($pts[0][0] + $pts[1][0]) / 2)
                $y = [int][math]::Floor(($pts[0][1] + $pts[1][1]) / 2)
                $bmp.GetPixel($x, $y).A | Should -BeGreaterThan 200 -Because $case.Mark
            } finally { $bmp.Dispose() }
        }
    }

    It 'wraps the frames as an .ico that loads as a System.Drawing.Icon at each size' {
        $bytes = New-TestIcoByte (New-AvdTrayRingState -Tint green -Fraction 1 -Mark check)
        foreach ($size in 16, 20, 24, 32) {
            $ms = [System.IO.MemoryStream]::new($bytes)
            try {
                $icon = [System.Drawing.Icon]::new($ms, $size, $size)
                try {
                    $icon.Width | Should -Be $size
                    $icon.Handle | Should -Not -Be ([System.IntPtr]::Zero)
                } finally { $icon.Dispose() }
            } finally { $ms.Dispose() }
        }
    }

    It 'round-trips the drawn pixels through the .ico' {
        $state = New-AvdTrayRingState -Tint blue -Fraction 0.5
        $bytes = New-TestIcoByte $state
        $ms = [System.IO.MemoryStream]::new($bytes)
        try {
            $icon = [System.Drawing.Icon]::new($ms, 32, 32)
            try {
                $bmp = $icon.ToBitmap()
                try { Assert-Tint (Get-ArcPixel $bmp 32 $state) 'blue' } finally { $bmp.Dispose() }
            } finally { $icon.Dispose() }
        } finally { $ms.Dispose() }
    }

    It 'returns the cached Icon for a repeated key, a new one for a new key, and disposes them all' {
        $cache = @{}
        $a = Get-AvdTrayIcon -Cache $cache -State (New-AvdTrayRingState -Tint blue -Fraction 0.5)
        $b = Get-AvdTrayIcon -Cache $cache -State (New-AvdTrayRingState -Tint blue -Fraction 0.501)
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
        $cache.Count | Should -Be 1
        $c = Get-AvdTrayIcon -Cache $cache -State (New-AvdTrayRingState -Tint green -Fraction 1 -Mark check)
        [object]::ReferenceEquals($a, $c) | Should -BeFalse
        $cache.Count | Should -Be 2
        # Loaded at the small-icon size, from one of the four frames.
        $a.Width | Should -BeIn 16, 20, 24, 32
        Clear-AvdTrayIconCache -Cache $cache
        $cache.Count | Should -Be 0
        { $null = $a.Handle } | Should -Throw
    }

    It 'builds the context menu from the model: labels for text rows, items for actions' {
        $menu = [System.Windows.Forms.ContextMenuStrip]::new()
        $font = @{
            Header = [System.Drawing.Font]::new($menu.Font, [System.Drawing.FontStyle]::Bold)
            Mono   = [System.Drawing.Font]::new('Consolas', [single]9)
        }
        try {
            $stats = New-AvdTrayStatus -Property @{ Armed = $true; Staged = 10; Confirmed = $true; ConfirmedAge = 60; LastRunAge = 60 }
            $model = Get-AvdTrayMenu -Stats $stats -LastError '' -CollectorSick $false -Offloading $false -SyncAvailable $true -OpenAvdAvailable $true
            Update-AvdTrayMenu -Menu $menu -Model $model -Font $font -OnClick { }
            $menu.Items.Count | Should -Be $model.Count
            for ($i = 0; $i -lt $model.Count; $i++) {
                $m = $model[$i]; $item = $menu.Items[$i]
                switch ($m.Kind) {
                    'separator' { $item | Should -BeOfType ([System.Windows.Forms.ToolStripSeparator]) }
                    'action' {
                        $item | Should -BeOfType ([System.Windows.Forms.ToolStripMenuItem])
                        $item.Enabled | Should -BeTrue
                        $item.Tag | Should -Be $m.Action
                        $item.Text | Should -Be (ConvertTo-AvdMenuText -Text $m.Text -Key $m.Key)
                    }
                    default {
                        $item | Should -BeOfType ([System.Windows.Forms.ToolStripLabel])
                        $item.GetType() | Should -Be ([System.Windows.Forms.ToolStripLabel])
                        $item.CanSelect | Should -BeFalse
                        $item.Text | Should -Be $m.Text
                    }
                }
            }
            $menu.Items[0].Font.Bold | Should -BeTrue
            @($menu.Items | Where-Object { $_.Text -like 'Staged*' })[0].Font.Name | Should -Be 'Consolas'
            if (-not [System.Windows.Forms.SystemInformation]::HighContrast) {
                $menu.Items[1].ForeColor.ToArgb() | Should -Be ([int](Get-AvdTrayTextColor)['green'])
            }
            $first = $menu.Items[0]
            Update-AvdTrayMenu -Menu $menu -Model $model -Font $font -OnClick { }
            $first.IsDisposed | Should -BeTrue
            $menu.Items.Count | Should -Be $model.Count
        } finally {
            $menu.Dispose()
            $font.Header.Dispose()
            $font.Mono.Dispose()
        }
    }

    Context 'Check iCloud now' {
        BeforeEach {
            $script:AvdTray = @{
                Pwsh = 'C:\pwsh.exe'; SyncScript = 'C:\t\avd-photos-sync.ps1'; LogFile = (Join-Path $TestDrive 'tray.log')
                Schtasks = 'C:\Windows\System32\schtasks.exe'; SyncTaskName = '\' + (Get-AvdLabelPrefix) + '.sync'
            }
        }
        BeforeAll {
            # The same shape of fake the Mac suite uses (Tray.Tests.ps1), with an exit code.
            function New-FakeExit {
                param([int]$Code)
                $p = [pscustomobject]@{ ExitCode = $Code; Waited = $null }
                $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $this.Waited = $ms; $true }
                $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
                $p | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
                $p
            }
        }
        It 'runs the sync task and nothing else when schtasks succeeds' {
            Mock Start-AvdDetachedProcess { New-FakeExit 0 }
            Invoke-AvdTrayCheck
            Should -Invoke Start-AvdDetachedProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'C:\Windows\System32\schtasks.exe' -and ($ArgumentList -join ' ') -eq '/Run /TN \com.ayushsharma.icloud-to-google-photos.sync'
            }
            Should -Invoke Start-AvdDetachedProcess -Times 1 -Exactly
        }
        It 'falls back to spawning the sync script when schtasks fails' {
            Mock Start-AvdDetachedProcess { New-FakeExit 1 }
            Invoke-AvdTrayCheck
            Should -Invoke Start-AvdDetachedProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'C:\pwsh.exe' -and $ArgumentList[-1] -eq 'C:\t\avd-photos-sync.ps1'
            }
            Should -Invoke Start-AvdDetachedProcess -Times 2 -Exactly
        }
    }
}
