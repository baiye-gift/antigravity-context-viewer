param(
    [string]$ApiUrl = '',
    [int]$ParentPid = 0,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

function U {
    param([string]$Text)
    return [regex]::Unescape($Text)
}

function E {
    param([int]$CodePoint)
    return [char]::ConvertFromUtf32($CodePoint)
}

function Format-Tokens {
    param([long]$Value)
    if ($Value -ge 1000000) {
        return ('{0:F2}M' -f ($Value / 1000000.0))
    }
    if ($Value -ge 10000) {
        return ('{0:F1}K' -f ($Value / 1000.0))
    }
    if ($Value -ge 1000) {
        return ('{0:F2}K' -f ($Value / 1000.0))
    }
    return "$Value"
}

function Format-LimitLabel {
    param([int]$Lim)
    if ($Lim -eq 1000000) { return ('100' + (U '\u4e07')) }
    if ($Lim -eq 2000000) { return ('200' + (U '\u4e07')) }
    if ($Lim -ge 1000000) {
        $m = $Lim / 1000000.0
        return ('{0:F0}00' -f $m) + (U '\u4e07')
    }
    return ('{0:F0}K' -f ($Lim / 1000.0))
}

function Short-ModelBadge {
    param([string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model) -or ($Model -eq 'unknown')) {
        return 'Antigravity'
    }
    $m = $Model.ToLowerInvariant()
    if ($m -match 'hydrogen') { return 'Hydrogen' }
    if ($m -match 'carbon') { return 'Carbon' }
    if ($m -match 'flash[-_]?lite') { return 'Flash Lite' }
    if ($m -match 'flash') { return 'Flash' }
    if ($m -match 'pro') { return 'Pro' }
    if ($m -match 'opus') { return 'Opus' }
    if ($m -match 'sonnet') { return 'Sonnet' }
    $clean = ($Model -replace '^(gemini|claude)-', '')
    if ($clean.Length -gt 12) { return $clean.Substring(0, 12) }
    return $clean
}

function Get-BrainDirs {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object 'System.Collections.Generic.List[string]'

    $addIfBrain = {
        param([string]$Candidate)
        if ([string]::IsNullOrWhiteSpace($Candidate)) { return }
        $brain = Join-Path $Candidate 'brain'
        if (Test-Path -LiteralPath $brain -PathType Container) {
            $full = [System.IO.Path]::GetFullPath($brain)
            if ($seen.Add($full)) {
                $result.Add($full)
            }
        }
    }

    if ($env:ANTIGRAVITY_EXECUTABLE_DATA_DIR) {
        $cur = $env:ANTIGRAVITY_EXECUTABLE_DATA_DIR
        while ($cur -and ($cur -ne [System.IO.Path]::GetPathRoot($cur))) {
            if ([System.IO.Path]::GetFileName($cur) -eq 'sidecar_data') {
                & $addIfBrain ([System.IO.Path]::GetDirectoryName($cur))
                break
            }
            $cur = [System.IO.Path]::GetDirectoryName($cur)
        }
    }

    if ($env:ANTIGRAVITY_APP_DATA_DIR) {
        & $addIfBrain $env:ANTIGRAVITY_APP_DATA_DIR
    }

    if ($result.Count -gt 0) {
        return $result
    }

    $geminiRoot = Join-Path $HOME '.gemini'
    if (Test-Path -LiteralPath $geminiRoot -PathType Container) {
        Get-ChildItem -LiteralPath $geminiRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            & $addIfBrain $_.FullName
        }
    }
    return $result
}

function Extract-SessionTitle {
    param([string]$Content)
    if ([string]::IsNullOrEmpty($Content)) {
        return (U '\u672a\u547d\u540d\u4f1a\u8bdd')
    }
    $m = [regex]::Match($Content, '<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
        $raw = $m.Groups[1].Value
    } else {
        $raw = [regex]::Replace($Content, '<([A-Z_]+)>[\s\S]*?</\1>', ' ')
        $raw = [regex]::Replace($raw, '<[^>]+>', ' ')
    }
    $cleaned = ([regex]::Replace($raw, '\s+', ' ')).Trim()
    if ([string]::IsNullOrEmpty($cleaned)) {
        return (U '\u672a\u547d\u540d\u4f1a\u8bdd')
    }
    if ($cleaned.Length -gt 48) {
        return $cleaned.Substring(0, 48)
    }
    return $cleaned
}

$script:CachedPath = ''
$script:CachedTicks = [long]0
$script:CachedLen = [long]-1
$script:CachedLocal = $null

function Get-LocalTranscriptSnapshot {
    $brains = Get-BrainDirs
    $latestFile = $null
    $latestTicks = [long]0

    foreach ($brainDir in $brains) {
        $convDirs = Get-ChildItem -LiteralPath $brainDir -Directory -ErrorAction SilentlyContinue
        foreach ($d in $convDirs) {
            if ($d.Name -notmatch '^[0-9a-fA-F-]{8,}$') { continue }
            $tp = Join-Path $d.FullName '.system_generated\logs\transcript.jsonl'
            if (Test-Path -LiteralPath $tp -PathType Leaf) {
                try {
                    $fi = New-Object System.IO.FileInfo($tp)
                    if ($fi.LastWriteTimeUtc.Ticks -gt $latestTicks) {
                        $latestTicks = $fi.LastWriteTimeUtc.Ticks
                        $latestFile = $fi
                    }
                } catch {
                    continue
                }
            }
        }
    }

    if ($null -eq $latestFile) {
        return [PSCustomObject]@{
            current = $null
            quota = [PSCustomObject]@{ available = $false; active = $null; models = @() }
            lastWriteUtc = [DateTime]::MinValue
            recentStepTokens = @()
        }
    }

    if (($latestFile.FullName -eq $script:CachedPath) -and ($latestFile.LastWriteTimeUtc.Ticks -eq $script:CachedTicks) -and ($latestFile.Length -eq $script:CachedLen) -and ($null -ne $script:CachedLocal)) {
        return $script:CachedLocal
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $fs = [System.IO.FileStream]::new($latestFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        try {
            while (-not $sr.EndOfStream) {
                $lines.Add($sr.ReadLine())
            }
        } finally {
            $sr.Dispose()
        }
    } finally {
        $fs.Dispose()
    }

    $convId = $latestFile.Directory.Parent.Parent.Name
    $title = ''
    $model = 'unknown'
    $activeContext = [long]0
    $latestInput = [long]0
    $latestCacheRead = [long]0
    $deltaContext = [long]0
    $totalOutput = [long]0
    $llmCallCount = 0
    $userTurns = 0
    $hasPrev = $false
    $prevCtx = [long]0
    $stepTokensList = New-Object 'System.Collections.Generic.List[long]'

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $step = $null
        try {
            $step = $line | ConvertFrom-Json
        } catch {
            continue
        }
        if ($null -eq $step) { continue }

        if ($step.type -eq 'USER_INPUT') {
            $userTurns += 1
            if ([string]::IsNullOrEmpty($title)) {
                $title = Extract-SessionTitle ([string]$step.content)
            }
            continue
        }

        if ($step.type -eq 'PLANNER_RESPONSE') {
            if ($step.model) {
                $model = [string]$step.model
            }
            $hasTokens = ($null -ne $step.input_tokens) -or ($null -ne $step.cache_read_tokens) -or ($null -ne $step.output_tokens)
            if ($hasTokens) {
                $llmCallCount += 1
                $inTok = if ($null -ne $step.input_tokens) { [long]$step.input_tokens } else { [long]0 }
                $cacheTok = if ($null -ne $step.cache_read_tokens) { [long]$step.cache_read_tokens } else { [long]0 }
                $outTok = if ($null -ne $step.output_tokens) { [long]$step.output_tokens } else { [long]0 }
                $ctx = $inTok + $cacheTok
                $totalOutput += $outTok
                $stepTokensList.Add($ctx)
                if (($ctx -gt 0) -or (-not $hasPrev)) {
                    $deltaContext = if ($hasPrev) { $ctx - $prevCtx } else { $ctx }
                    $activeContext = $ctx
                    $latestInput = $inTok
                    $latestCacheRead = $cacheTok
                    $prevCtx = $ctx
                    $hasPrev = $true
                }
            }
        }
    }

    if ([string]::IsNullOrEmpty($title)) {
        $title = $convId.Substring(0, [Math]::Min(8, $convId.Length))
    }
    $hitRate = if ($activeContext -gt 0) { [Math]::Round(($latestCacheRead / $activeContext) * 100.0, 1) } else { 0.0 }

    $recentArr = @()
    if ($stepTokensList.Count -gt 0) {
        $startIdx = [Math]::Max(0, $stepTokensList.Count - 14)
        $cnt = $stepTokensList.Count - $startIdx
        $recentArr = $stepTokensList.GetRange($startIdx, $cnt).ToArray()
    }

    $snap = [PSCustomObject]@{
        current = [PSCustomObject]@{
            conversationId = $convId
            title = $title
            activeModel = $model
            activeContextTokens = $activeContext
            latestInputTokens = $latestInput
            latestCacheReadTokens = $latestCacheRead
            cacheHitRate = $hitRate
            deltaContextTokens = $deltaContext
            totalOutputTokens = $totalOutput
            llmCallCount = $llmCallCount
            userTurns = $userTurns
            recentStepTokens = $recentArr
        }
        quota = [PSCustomObject]@{ available = $false; active = $null; models = @() }
        lastWriteUtc = $latestFile.LastWriteTimeUtc
        recentStepTokens = $recentArr
    }

    $script:CachedPath = $latestFile.FullName
    $script:CachedTicks = $latestFile.LastWriteTimeUtc.Ticks
    $script:CachedLen = $latestFile.Length
    $script:CachedLocal = $snap
    return $snap
}

function Get-HudData {
    param([switch]$ForceRefresh)
    $localSnap = Get-LocalTranscriptSnapshot
    if (-not [string]::IsNullOrWhiteSpace($ApiUrl)) {
        try {
            $url = $ApiUrl
            $sep = if ($url.Contains('?')) { '&' } else { '?' }
            $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if ($ForceRefresh) {
                $url = "${url}${sep}refresh=1&_ts=${ts}"
            } else {
                $url = "${url}${sep}_ts=${ts}"
            }
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $wc.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
            try {
                $raw = $wc.DownloadString($url)
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = $raw | ConvertFrom-Json
                    if ($null -ne $parsed) {
                        $wave = $localSnap.recentStepTokens
                        if ($null -ne $parsed.current -and $null -ne $parsed.current.recentStepTokens -and $parsed.current.recentStepTokens.Count -gt 0) {
                            $wave = $parsed.current.recentStepTokens
                        }
                        $parsed | Add-Member -NotePropertyName 'lastWriteUtc' -NotePropertyValue $localSnap.lastWriteUtc -Force
                        $parsed | Add-Member -NotePropertyName 'waveTokens' -NotePropertyValue $wave -Force
                        return $parsed
                    }
                }
            } finally {
                $wc.Dispose()
            }
        } catch {
            # Fallback to local transcript reader if sidecar API is temporarily unreachable
        }
    }
    $localSnap | Add-Member -NotePropertyName 'waveTokens' -NotePropertyValue $localSnap.recentStepTokens -Force
    return $localSnap
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not ('Win32.HudNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Win32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public struct TargetWindowInfo {
        public IntPtr Hwnd;
        public bool IsIconic;
        public RECT Rect;
    }

    public static class HudNative {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

        public static TargetWindowInfo FindAntigravityWindow() {
            var procCache = new Dictionary<uint, string>();
            IntPtr bestHwnd = IntPtr.Zero;
            long bestArea = 0;
            RECT bestRect = new RECT();
            bool bestIconic = false;

            EnumWindows((hWnd, lParam) => {
                if (!IsWindowVisible(hWnd)) return true;
                if (GetWindow(hWnd, 4) != IntPtr.Zero) return true;
                if (GetWindowTextLength(hWnd) <= 0) return true;

                uint pid = 0;
                GetWindowThreadProcessId(hWnd, out pid);
                if (pid == 0) return true;

                string procName;
                if (!procCache.TryGetValue(pid, out procName)) {
                    try {
                        procName = Process.GetProcessById((int)pid).ProcessName ?? "";
                    } catch {
                        procName = "";
                    }
                    procCache[pid] = procName;
                }

                if (!procName.Equals("Antigravity", StringComparison.OrdinalIgnoreCase)) {
                    return true;
                }

                bool iconic = IsIconic(hWnd);
                RECT r;
                if (!GetWindowRect(hWnd, out r)) return true;
                long w = (long)(r.Right - r.Left);
                long h = (long)(r.Bottom - r.Top);
                if (iconic) {
                    if (bestHwnd == IntPtr.Zero) {
                        bestHwnd = hWnd;
                        bestIconic = true;
                        bestRect = r;
                    }
                    return true;
                }
                if (w < 400 || h < 300) return true;
                long area = w * h;
                if (area > bestArea) {
                    bestArea = area;
                    bestHwnd = hWnd;
                    bestRect = r;
                    bestIconic = false;
                }
                return true;
            }, IntPtr.Zero);

            return new TargetWindowInfo {
                Hwnd = bestHwnd,
                IsIconic = bestIconic,
                Rect = bestRect
            };
        }
    }
}
'@
}

function New-ArcGeometry {
    param(
        [double]$Cx,
        [double]$Cy,
        [double]$R,
        [double]$Pct
    )
    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Pct))
    $geom = New-Object System.Windows.Media.PathGeometry
    if ($clamped -le 0.3) {
        return $geom
    }
    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = [System.Windows.Point]::new($Cx, $Cy - $R)
    $fig.IsClosed = $false

    if ($clamped -ge 99.7) {
        $seg1 = New-Object System.Windows.Media.ArcSegment
        $seg1.Point = [System.Windows.Point]::new($Cx, $Cy + $R)
        $seg1.Size = [System.Windows.Size]::new($R, $R)
        $seg1.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
        $seg1.IsLargeArc = $false
        $fig.Segments.Add($seg1)

        $seg2 = New-Object System.Windows.Media.ArcSegment
        $seg2.Point = [System.Windows.Point]::new($Cx, $Cy - $R)
        $seg2.Size = [System.Windows.Size]::new($R, $R)
        $seg2.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
        $seg2.IsLargeArc = $false
        $fig.Segments.Add($seg2)
    } else {
        $angleDeg = ($clamped / 100.0) * 360.0 - 90.0
        $rad = $angleDeg * [Math]::PI / 180.0
        $ex = $Cx + $R * [Math]::Cos($rad)
        $ey = $Cy + $R * [Math]::Sin($rad)

        $seg = New-Object System.Windows.Media.ArcSegment
        $seg.Point = [System.Windows.Point]::new($ex, $ey)
        $seg.Size = [System.Windows.Size]::new($R, $R)
        $seg.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
        $seg.IsLargeArc = ($clamped -gt 50.0)
        $fig.Segments.Add($seg)
    }

    $geom.Figures.Add($fig)
    return $geom
}

if ($CheckOnly) {
    $winInfo = [Win32.HudNative]::FindAntigravityWindow()
    $data = Get-HudData
    $ctx = if ($null -ne $data.current) { [long]$data.current.activeContextTokens } else { [long]0 }
    $arcTest = New-ArcGeometry -Cx 24 -Cy 24 -R 19 -Pct 65
    $out = [PSCustomObject]@{
        ok = $true
        foundAntigravityHwnd = ($winInfo.Hwnd -ne [IntPtr]::Zero)
        isIconic = $winInfo.IsIconic
        activeContext = $ctx
        waveCount = @($data.waveTokens).Count
        arcFigures = $arcTest.Figures.Count
        quotaAvailable = [bool]($data.quota -and $data.quota.available)
    }
    Write-Output ($out | ConvertTo-Json -Compress)
    exit 0
}

$instanceFile = Join-Path $env:TEMP 'ag-cv-hud-instance.json'
try {
    [PSCustomObject]@{ pid = $PID; apiUrl = $ApiUrl } | ConvertTo-Json -Compress | Set-Content -LiteralPath $instanceFile -Encoding Ascii
} catch {}

$mutex = New-Object System.Threading.Mutex($false, 'Local\AntigravityContextViewerHudV2')
$acquired = $false
try {
    $acquired = $mutex.WaitOne(2500)
} catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
}
if (-not $acquired) {
    $mutex.Dispose()
    exit 0
}

$script:ExitCode = 0
$script:PrefsDir = Join-Path $HOME '.gemini\antigravity\sidecar_data\context-viewer'
$script:PrefsPath = Join-Path $script:PrefsDir 'hud-prefs.json'
$script:Prefs = [PSCustomObject]@{ dock = 'bottom-left'; limit = 1000000; skin = 'obsidian' }
$script:LimitPresets = @(128000, 200000, 256000, 1000000, 2000000)
$script:SkinNames = @('obsidian', 'cyber', 'amber', 'aurora')

if (Test-Path -LiteralPath $script:PrefsPath -PathType Leaf) {
    try {
        $loadedPrefs = Get-Content -LiteralPath $script:PrefsPath -Raw | ConvertFrom-Json
        if ($loadedPrefs.dock -in @('bottom-left', 'top-center', 'free')) {
            $script:Prefs.dock = [string]$loadedPrefs.dock
        }
        if ([int]$loadedPrefs.limit -gt 0) {
            $script:Prefs.limit = [int]$loadedPrefs.limit
        }
        if ($loadedPrefs.skin -in $script:SkinNames) {
            $script:Prefs.skin = [string]$loadedPrefs.skin
        }
    } catch {}
}

function Save-Prefs {
    try {
        if (-not (Test-Path -LiteralPath $script:PrefsDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:PrefsDir -Force | Out-Null
        }
        $script:Prefs | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:PrefsPath -Encoding Ascii
    } catch {}
}

try {
    $script:IsExpanded = $false
    $script:LastData = $null
    $script:LastDataFetch = [DateTime]::MinValue
    $script:OwnerAttached = [IntPtr]::Zero
    $script:OrbitAngle = -1.57
    $script:IsThinking = $false

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AntigravityContextHud"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="False"
        ShowActivated="False"
        SizeToContent="WidthAndHeight"
        ResizeMode="NoResize">
  <Border x:Name="RootBorder"
          CornerRadius="12"
          BorderThickness="1"
          SnapsToDevicePixels="True">
    <Border.Effect>
      <DropShadowEffect BlurRadius="16" ShadowDepth="3" Opacity="0.48" Color="#000000"/>
    </Border.Effect>
    <Grid>
      <!-- Ambient glow orb -->
      <Ellipse x:Name="GlowOrb" Width="96" Height="96" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-32,-38,0,0" IsHitTestVisible="False">
        <Ellipse.Effect>
          <BlurEffect Radius="28"/>
        </Ellipse.Effect>
      </Ellipse>

      <!-- Specular top inner border -->
      <Border x:Name="InnerRim" CornerRadius="11" BorderThickness="1" BorderBrush="#1AFFFFFF" IsHitTestVisible="False"/>

      <StackPanel>
        <!-- Layout A: Bottom-Left Telemetry Pod -->
        <StackPanel x:Name="BottomLeftPanel" Width="204" Margin="10,7,10,8">
          <!-- Header: Living mood status + action controls -->
          <Grid Height="18" Margin="0,0,0,5">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="MoodText" Grid.Column="0" Foreground="#CBD5E1" FontFamily="Segoe UI Emoji, Segoe UI" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <Button x:Name="BlSkinBtn" Grid.Column="1" Width="16" Height="16" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontFamily="Segoe UI Emoji, Segoe UI" FontSize="10" Cursor="Hand" Padding="0"/>
            <Button x:Name="BlDockBtn" Grid.Column="2" Width="16" Height="16" Margin="1,0,0,0" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="10.5" Cursor="Hand" Padding="0"/>
            <Button x:Name="BlExpandBtn" Grid.Column="3" Width="16" Height="16" Margin="1,0,0,0" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="10.5" Cursor="Hand" Padding="0"/>
            <Button x:Name="BlCloseBtn" Grid.Column="4" Width="16" Height="16" Margin="1,0,0,0" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="11" Cursor="Hand" Padding="0"/>
          </Grid>

          <!-- Hero Row: Concentric Dual-Arc Orbital Ring + Badges & Waveform -->
          <Grid Margin="0,0,0,7">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="48"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Canvas Grid.Column="0" Width="48" Height="48" ClipToBounds="False">
              <Ellipse Width="38" Height="38" Canvas.Left="5" Canvas.Top="5" Stroke="#20FFFFFF" StrokeThickness="3.6"/>
              <Path x:Name="CtxArcPath" StrokeThickness="3.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
              <Ellipse Width="26" Height="26" Canvas.Left="11" Canvas.Top="11" Stroke="#18FFFFFF" StrokeThickness="2.8"/>
              <Path x:Name="QuotaArcPath" StrokeThickness="2.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
              <Ellipse x:Name="OrbitDot" Width="5" Height="5" Canvas.Left="21.5" Canvas.Top="-0.5" Visibility="Collapsed"/>
              <Grid Width="48" Height="48">
                <TextBlock x:Name="RingPctText" Text="0%" Foreground="#F8FAFC" FontFamily="Consolas, Segoe UI" FontSize="10.5" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
            </Canvas>

            <StackPanel Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
                <Border x:Name="ModelBadge" CornerRadius="4" Padding="5,1" Margin="0,0,4,0">
                  <TextBlock x:Name="ModelBadgeText" FontSize="9.5" FontWeight="SemiBold"/>
                </Border>
                <Border Background="#1FFFFFFF" CornerRadius="4" Padding="4,1">
                  <TextBlock x:Name="CacheBadgeText" Foreground="#CBD5E1" FontFamily="Consolas, Segoe UI" FontSize="9.5" FontWeight="SemiBold"/>
                </Border>
              </StackPanel>

              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,0,3">
                <TextBlock x:Name="CtxTokensText" Text="--" Foreground="#F8FAFC" FontFamily="Consolas, Segoe UI" FontSize="13.5" FontWeight="Bold" VerticalAlignment="Bottom"/>
                <Button x:Name="LimitCycleBtn" Background="Transparent" BorderThickness="0" Padding="3,0,2,0" Margin="2,0,0,1" Cursor="Hand" Foreground="#94A3B8" FontFamily="Consolas, Segoe UI" FontSize="10" VerticalAlignment="Bottom"/>
              </StackPanel>

              <UniformGrid x:Name="WaveGrid" Columns="14" Height="11"/>
            </StackPanel>
          </Grid>

          <!-- Segmented 10-Cell Energy Matrix: 5h & Weekly -->
          <Grid Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="22"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="5h" Foreground="#94A3B8" FontFamily="Consolas, Segoe UI" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <UniformGrid x:Name="FiveCellsGrid" Grid.Column="1" Columns="10" Height="5" VerticalAlignment="Center" Margin="2,0,6,0"/>
            <TextBlock x:Name="FiveText" Grid.Column="2" Foreground="#E2E8F0" FontFamily="Consolas, Segoe UI" FontSize="10" VerticalAlignment="Center"/>
          </Grid>

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="22"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="WeekLabelText" Grid.Column="0" Foreground="#94A3B8" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <UniformGrid x:Name="WeekCellsGrid" Grid.Column="1" Columns="10" Height="5" VerticalAlignment="Center" Margin="2,0,6,0"/>
            <TextBlock x:Name="WeekText" Grid.Column="2" Foreground="#E2E8F0" FontFamily="Consolas, Segoe UI" FontSize="10" VerticalAlignment="Center"/>
          </Grid>
        </StackPanel>

        <!-- Layout B: Top-Center Dynamic Island Pill -->
        <Grid x:Name="TopCenterPanel" Height="27" Margin="10,0,7,0" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Ellipse x:Name="TcDot" Grid.Column="0" Width="7" Height="7" Fill="#38BDF8" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <TextBlock x:Name="TcSummaryText" Grid.Column="1" Foreground="#F8FAFC" FontFamily="Consolas, Segoe UI" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,7,0"/>
          <Button x:Name="TcSkinBtn" Grid.Column="2" Width="17" Height="17" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontFamily="Segoe UI Emoji, Segoe UI" FontSize="10" Cursor="Hand" Padding="0"/>
          <Button x:Name="TcDockBtn" Grid.Column="3" Width="17" Height="17" Margin="1,0,0,0" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="10.5" Cursor="Hand" Padding="0"/>
          <Button x:Name="TcExpandBtn" Grid.Column="4" Width="17" Height="17" Margin="1,0,0,0" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="10.5" Cursor="Hand" Padding="0"/>
          <Button x:Name="TcCloseBtn" Grid.Column="5" Width="17" Height="17" Margin="1,0,0,0" Background="Transparent" BorderThickness="0" Foreground="#94A3B8" FontSize="11" Cursor="Hand" Padding="0"/>
        </Grid>

        <!-- Upward/Downward Curated Drawer -->
        <StackPanel x:Name="DrawerPanel" Visibility="Collapsed" Margin="10,0,10,8" MaxWidth="276">
          <Border Height="1" Background="#22FFFFFF" Margin="0,2,0,6"/>
          <TextBlock x:Name="DrawerTitle" Foreground="#F1F5F9" FontSize="11" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="DrawerMeta" Foreground="#94A3B8" FontFamily="Consolas, Segoe UI" FontSize="10" Margin="0,2,0,5"/>
          <TextBlock x:Name="DrawerHint" Foreground="#FBBF24" FontSize="10.5" Margin="0,0,0,5" Visibility="Collapsed"/>
          <StackPanel x:Name="DrawerModels"/>
          <TextBlock x:Name="DrawerMore" Foreground="#64748B" FontSize="9.5" Margin="0,3,0,0" Visibility="Collapsed"/>
        </StackPanel>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $rootBorder = $window.FindName('RootBorder')
    $glowOrb = $window.FindName('GlowOrb')
    $innerRim = $window.FindName('InnerRim')
    $blPanel = $window.FindName('BottomLeftPanel')
    $tcPanel = $window.FindName('TopCenterPanel')
    $drawerPanel = $window.FindName('DrawerPanel')

    $moodText = $window.FindName('MoodText')
    $blSkinBtn = $window.FindName('BlSkinBtn')
    $blDockBtn = $window.FindName('BlDockBtn')
    $blExpandBtn = $window.FindName('BlExpandBtn')
    $blCloseBtn = $window.FindName('BlCloseBtn')

    $ctxArcPath = $window.FindName('CtxArcPath')
    $quotaArcPath = $window.FindName('QuotaArcPath')
    $orbitDot = $window.FindName('OrbitDot')
    $ringPctText = $window.FindName('RingPctText')

    $modelBadge = $window.FindName('ModelBadge')
    $modelBadgeText = $window.FindName('ModelBadgeText')
    $cacheBadgeText = $window.FindName('CacheBadgeText')
    $ctxTokensText = $window.FindName('CtxTokensText')
    $limitCycleBtn = $window.FindName('LimitCycleBtn')
    $waveGrid = $window.FindName('WaveGrid')

    $fiveCellsGrid = $window.FindName('FiveCellsGrid')
    $fiveText = $window.FindName('FiveText')
    $weekLabelText = $window.FindName('WeekLabelText')
    $weekCellsGrid = $window.FindName('WeekCellsGrid')
    $weekText = $window.FindName('WeekText')

    $tcDot = $window.FindName('TcDot')
    $tcSummary = $window.FindName('TcSummaryText')
    $tcSkinBtn = $window.FindName('TcSkinBtn')
    $tcDockBtn = $window.FindName('TcDockBtn')
    $tcExpandBtn = $window.FindName('TcExpandBtn')
    $tcCloseBtn = $window.FindName('TcCloseBtn')

    $drawerTitle = $window.FindName('DrawerTitle')
    $drawerMeta = $window.FindName('DrawerMeta')
    $drawerHint = $window.FindName('DrawerHint')
    $drawerModels = $window.FindName('DrawerModels')
    $drawerMore = $window.FindName('DrawerMore')

    # Populate 14 waveform bars & 10-cell energy grids once
    $script:WaveBars = New-Object 'System.Collections.Generic.List[System.Windows.Controls.Border]'
    for ($i = 0; $i -lt 14; $i++) {
        $b = New-Object System.Windows.Controls.Border
        $b.Height = 2
        $b.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
        $b.CornerRadius = [System.Windows.CornerRadius]::new(1.2)
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 1.5, 0)
        [void]$waveGrid.Children.Add($b)
        $script:WaveBars.Add($b)
    }

    $script:FiveCells = New-Object 'System.Collections.Generic.List[System.Windows.Controls.Border]'
    $script:WeekCells = New-Object 'System.Collections.Generic.List[System.Windows.Controls.Border]'
    for ($i = 0; $i -lt 10; $i++) {
        $c1 = New-Object System.Windows.Controls.Border
        $c1.CornerRadius = [System.Windows.CornerRadius]::new(1.3)
        $c1.Margin = [System.Windows.Thickness]::new(0, 0, 1.5, 0)
        [void]$fiveCellsGrid.Children.Add($c1)
        $script:FiveCells.Add($c1)

        $c2 = New-Object System.Windows.Controls.Border
        $c2.CornerRadius = [System.Windows.CornerRadius]::new(1.3)
        $c2.Margin = [System.Windows.Thickness]::new(0, 0, 1.5, 0)
        [void]$weekCellsGrid.Children.Add($c2)
        $script:WeekCells.Add($c2)
    }

    # Labels & tooltips (strictly via U/E helpers)
    $weekLabelText.Text = U '\u5468'
    $iconSkin = E 0x1F3A8
    $iconSwap = U '\u21c5'
    $iconDown = U '\u25be'
    $iconUp = U '\u25b4'
    $iconClose = U '\u00d7'

    $blSkinBtn.Content = $iconSkin
    $tcSkinBtn.Content = $iconSkin
    $blSkinBtn.ToolTip = U '\u5207\u6362\u4e3b\u9898\u76ae\u80a4'
    $tcSkinBtn.ToolTip = $blSkinBtn.ToolTip

    $blDockBtn.Content = $iconSwap
    $tcDockBtn.Content = $iconSwap
    $blDockBtn.ToolTip = U '\u5207\u6362\u4f4d\u7f6e\uff1a\u5de6\u4e0b\u89d2 \u21c4 \u9876\u90e8\u6b63\u4e2d'
    $tcDockBtn.ToolTip = $blDockBtn.ToolTip

    $blExpandBtn.Content = $iconDown
    $tcExpandBtn.Content = $iconDown
    $blExpandBtn.ToolTip = U '\u5c55\u5f00/\u6536\u8d77\u5404\u6a21\u578b\u989d\u5ea6\u660e\u7ec6'
    $tcExpandBtn.ToolTip = $blExpandBtn.ToolTip

    $blCloseBtn.Content = $iconClose
    $tcCloseBtn.Content = $iconClose
    $blCloseBtn.ToolTip = U '\u9690\u85cf\u6302\u4ef6'
    $tcCloseBtn.ToolTip = $blCloseBtn.ToolTip

    $limitCycleBtn.ToolTip = U '\u70b9\u51fb\u5207\u6362\u4e0a\u4e0b\u6587\u4e0a\u9650'

    $brushConv = New-Object System.Windows.Media.BrushConverter
    function To-Color([string]$hex) {
        return [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    }
    function To-Brush([string]$hex) {
        return $brushConv.ConvertFromString($hex)
    }

    $amberBrush = To-Brush '#FBBF24'
    $redBrush = To-Brush '#FB7185'
    $unlitBrush = To-Brush '#1EFFFFFF'
    $mutedBrush = To-Brush '#94A3B8'
    $fgBrush = To-Brush '#E2E8F0'

    $script:Skins = @{
        obsidian = @{
            label = U '\u661f\u9645\u6697\u73bb'
            bg1 = '#F0111622'; bg2 = '#EC192234'; border = '#4238BDF8'; rim = '#22FFFFFF'; glow = '#2438BDF8'
            accent = '#38BDF8'; secondary = '#34D399'; wave = '#38BDF8'; badgeBg = '#2238BDF8'; badgeFg = '#7DD3FC'
        }
        cyber = @{
            label = U '\u8d5b\u535a\u9713\u8679'
            bg1 = '#F20A101C'; bg2 = '#EE170D28'; border = '#5500F5D4'; rim = '#28F472B6'; glow = '#2600F5D4'
            accent = '#00F5D4'; secondary = '#A855F7'; wave = '#22D3EE'; badgeBg = '#2200F5D4'; badgeFg = '#67E8F9'
        }
        amber = @{
            label = U '\u7425\u73c0\u673a\u80fd'
            bg1 = '#F2161412'; bg2 = '#EE241D15'; border = '#52F59E0B'; rim = '#24FDE68A'; glow = '#24F59E0B'
            accent = '#F59E0B'; secondary = '#34D399'; wave = '#FBBF24'; badgeBg = '#24F59E0B'; badgeFg = '#FCD34D'
        }
        aurora = @{
            label = U '\u6781\u5149\u7d2b\u6676'
            bg1 = '#F0131122'; bg2 = '#EC1E1635'; border = '#52A78BFA'; rim = '#28C4B5FD'; glow = '#26A78BFA'
            accent = '#A78BFA'; secondary = '#2DD4BF'; wave = '#C084FC'; badgeBg = '#24A78BFA'; badgeFg = '#DDD6FE'
        }
    }

    $script:ActiveTheme = $null

    function Apply-Skin {
        $name = if ($script:Skins.ContainsKey($script:Prefs.skin)) { $script:Prefs.skin } else { 'obsidian' }
        $s = $script:Skins[$name]

        $grad = New-Object System.Windows.Media.LinearGradientBrush
        $grad.StartPoint = [System.Windows.Point]::new(0, 0)
        $grad.EndPoint = [System.Windows.Point]::new(1, 1)
        $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop((To-Color $s.bg1), 0.0)))
        $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop((To-Color $s.bg2), 1.0)))

        $rootBorder.Background = $grad
        $rootBorder.BorderBrush = To-Brush $s.border
        $innerRim.BorderBrush = To-Brush $s.rim
        $glowOrb.Fill = To-Brush $s.glow

        $accentBrush = To-Brush $s.accent
        $secondaryBrush = To-Brush $s.secondary
        $waveColor = To-Color $s.wave

        $orbitDot.Fill = $accentBrush
        $modelBadge.Background = To-Brush $s.badgeBg
        $modelBadgeText.Foreground = To-Brush $s.badgeFg

        $script:ActiveTheme = @{
            accent = $accentBrush
            secondary = $secondaryBrush
            waveColor = $waveColor
        }
    }

    function Get-QuotaBrush {
        param([double]$RemainPct)
        if ($RemainPct -lt 20) { return $redBrush }
        if ($RemainPct -lt 50) { return $amberBrush }
        return $script:ActiveTheme.secondary
    }

    function Apply-DockLayout {
        if ($script:Prefs.dock -eq 'top-center') {
            $blPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $tcPanel.Visibility = [System.Windows.Visibility]::Visible
            $rootBorder.CornerRadius = [System.Windows.CornerRadius]::new(14)
            $innerRim.CornerRadius = [System.Windows.CornerRadius]::new(13)
        } else {
            $blPanel.Visibility = [System.Windows.Visibility]::Visible
            $tcPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $rootBorder.CornerRadius = [System.Windows.CornerRadius]::new(12)
            $innerRim.CornerRadius = [System.Windows.CornerRadius]::new(11)
        }
    }

    function Update-DockPosition {
        try {
            $info = [Win32.HudNative]::FindAntigravityWindow()
            if ($info.Hwnd -ne [IntPtr]::Zero) {
                if ($script:OwnerAttached -ne $info.Hwnd) {
                    try {
                        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
                        if ($helper.Handle -ne [IntPtr]::Zero) {
                            $helper.Owner = $info.Hwnd
                            $window.Topmost = $false
                            $script:OwnerAttached = $info.Hwnd
                        }
                    } catch {}
                }

                if ($info.IsIconic) {
                    if ($window.Visibility -ne [System.Windows.Visibility]::Hidden) {
                        $window.Visibility = [System.Windows.Visibility]::Hidden
                    }
                    return
                }
                if ($window.Visibility -ne [System.Windows.Visibility]::Visible) {
                    $window.Visibility = [System.Windows.Visibility]::Visible
                    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
                    if ($hwnd -ne [IntPtr]::Zero) {
                        [void][Win32.HudNative]::ShowWindow($hwnd, 4)
                    }
                }

                if ($script:Prefs.dock -eq 'free') { return }

                $scaleX = 1.0
                $scaleY = 1.0
                try {
                    $src = [System.Windows.PresentationSource]::FromVisual($window)
                    if ($null -ne $src -and $null -ne $src.CompositionTarget) {
                        $m = $src.CompositionTarget.TransformFromDevice
                        $scaleX = $m.M11
                        $scaleY = $m.M22
                    }
                } catch {}

                $dipLeft = $info.Rect.Left * $scaleX
                $dipTop = $info.Rect.Top * $scaleY
                $dipRight = $info.Rect.Right * $scaleX
                $dipBottom = $info.Rect.Bottom * $scaleY
                $dipW = $dipRight - $dipLeft

                $wActual = if ($rootBorder.ActualWidth -gt 20) { $rootBorder.ActualWidth } else { 206.0 }
                $hActual = if ($rootBorder.ActualHeight -gt 20) { $rootBorder.ActualHeight } else { 134.0 }

                if ($script:Prefs.dock -eq 'top-center') {
                    $window.Left = $dipLeft + (($dipW - $wActual) / 2.0)
                    $window.Top = $dipTop + 4.0
                } else {
                    $window.Left = $dipLeft + 8.0
                    $window.Top = $dipBottom - $hActual - 42.0
                }
            } else {
                $window.Topmost = $true
            }
        } catch {}
    }

    function Curate-Models {
        param($Models, $ActiveLabel)
        $list = New-Object 'System.Collections.Generic.List[object]'
        if ($null -eq $Models -or $Models.Count -eq 0) {
            return [PSCustomObject]@{ items = $list; extraCount = 0 }
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        # Put matched active model first
        foreach ($m in $Models) {
            if ($m.label -eq $ActiveLabel) {
                $seen.Add([string]$m.label) | Out-Null
                $list.Add($m)
                break
            }
        }
        foreach ($m in $Models) {
            if ($list.Count -ge 7) { break }
            $lbl = [string]$m.label
            if ([string]::IsNullOrWhiteSpace($lbl)) { continue }
            if ($lbl -match '^(internal|executor|subagent|background|test)') { continue }
            if ($seen.Add($lbl)) {
                $list.Add($m)
            }
        }
        $extra = [Math]::Max(0, $Models.Count - $list.Count)
        return [PSCustomObject]@{ items = $list; extraCount = $extra }
    }

    function Render-Data {
        param([switch]$ForceRefresh)
        try {
            $data = Get-HudData -ForceRefresh:$ForceRefresh
            $script:LastData = $data

            $cur = $data.current
            $lim = [int]$script:Prefs.limit
            if ($lim -le 0) { $lim = 1000000 }

            $ctxTok = if ($null -ne $cur) { [long]$cur.activeContextTokens } else { [long]0 }
            $ctxPctRaw = ($ctxTok / $lim) * 100.0
            $ctxPctClamped = [Math]::Max(0.0, [Math]::Min(100.0, $ctxPctRaw))
            $ctxBrush = if ($ctxPctRaw -ge 75) { $redBrush } elseif ($ctxPctRaw -ge 50) { $amberBrush } else { $script:ActiveTheme.accent }

            # Outer Context Arc + Inner 5h Quota Arc
            $ctxArcPath.Stroke = $ctxBrush
            $ctxArcPath.Data = New-ArcGeometry -Cx 24 -Cy 24 -R 19 -Pct $ctxPctClamped
            $ringPctText.Text = "$($ctxPctRaw.ToString('F0'))%"
            $ringPctText.Foreground = $ctxBrush
            $tcDot.Fill = $ctxBrush

            $activeModel = if ($null -ne $cur -and $cur.activeModel) { [string]$cur.activeModel } else { 'unknown' }
            $star = U '\u2726'
            $bolt = U '\u26a1'
            $modelBadgeText.Text = "$star $(Short-ModelBadge $activeModel)"
            $hitVal = if ($null -ne $cur) { [double]$cur.cacheHitRate } else { 0.0 }
            $cacheBadgeText.Text = "$bolt$($hitVal.ToString('F0'))%"

            $ctxTokensText.Text = Format-Tokens $ctxTok
            $limitCycleBtn.Content = "/ $(Format-LimitLabel $lim)"

            # 14-Bar Micro Spectrum Waveform
            $wave = @($data.waveTokens)
            $padded = New-Object 'long[]' 14
            $offset = [Math]::Max(0, 14 - $wave.Count)
            for ($i = 0; $i -lt [Math]::Min(14, $wave.Count); $i++) {
                $srcIdx = [Math]::Max(0, $wave.Count - 14) + $i
                $padded[$offset + $i] = [long]$wave[$srcIdx]
            }
            $maxWave = [long]1
            foreach ($v in $padded) {
                if ($v -gt $maxWave) { $maxWave = $v }
            }
            $wcBase = $script:ActiveTheme.waveColor
            for ($i = 0; $i -lt 14; $i++) {
                $bar = $script:WaveBars[$i]
                $v = $padded[$i]
                if ($v -le 0) {
                    $bar.Height = 2
                    $bar.Background = $unlitBrush
                } else {
                    $h = 2.0 + (($v / [double]$maxWave) * 9.0)
                    $bar.Height = $h
                    $alpha = [byte](110 + [int](($i / 13.0) * 145))
                    $c = [System.Windows.Media.Color]::FromArgb($alpha, $wcBase.R, $wcBase.G, $wcBase.B)
                    $bar.Background = New-Object System.Windows.Media.SolidColorBrush($c)
                }
            }

            # Quota Values + 10-Cell Matrix
            $qAvail = [bool]($data.quota -and $data.quota.available -and $null -ne $data.quota.active)
            $fivePct = 0.0
            $fivePctText = '--'
            $fiveResetText = U '\u672a\u8fde\u63a5'
            $fiveBrush = $mutedBrush
            $fiveLit = 0

            $wkPctText = '--'
            $wkResetText = ''
            $wkBrush = $mutedBrush
            $wkLit = 0

            if ($qAvail) {
                $act = $data.quota.active
                $fh = $act.fiveHour
                $wk = $act.weekly

                if ($null -ne $fh) {
                    $fivePct = [double]$fh.pct
                    $fivePctText = "$($fivePct.ToString('F0'))%"
                    $fiveResetText = if ($fh.resetLabel) { [string]$fh.resetLabel } else { U '\u6ee1\u989d' }
                    $fiveBrush = Get-QuotaBrush $fivePct
                    $fiveLit = [int][Math]::Round(([Math]::Max(0.0, [Math]::Min(100.0, $fivePct)) / 100.0) * 10)
                    if ($fivePct -gt 0 -and $fiveLit -eq 0) { $fiveLit = 1 }
                }
                if ($null -ne $wk) {
                    if ($null -ne $wk.pct) {
                        $wp = [double]$wk.pct
                        $wkPctText = "$($wp.ToString('F0'))%"
                        $wkResetText = if ($wk.resetLabel) { [string]$wk.resetLabel } else { '' }
                        $wkBrush = Get-QuotaBrush $wp
                        $wkLit = [int][Math]::Round(([Math]::Max(0.0, [Math]::Min(100.0, $wp)) / 100.0) * 10)
                        if ($wp -gt 0 -and $wkLit -eq 0) { $wkLit = 1 }
                    } else {
                        $wkPctText = U '\u5145\u8db3'
                        $wkResetText = if ($wk.resetLabel) { [string]$wk.resetLabel } else { '' }
                        $wkBrush = $script:ActiveTheme.secondary
                        $wkLit = 10
                    }
                }
            }

            $quotaArcPath.Stroke = $fiveBrush
            $quotaArcPath.Data = New-ArcGeometry -Cx 24 -Cy 24 -R 13 -Pct $fivePct

            $sepDot = U '\u00b7'
            $fiveText.Text = if ($qAvail) { "$fivePctText $sepDot $fiveResetText" } else { $fiveResetText }
            $fiveText.Foreground = if ($qAvail) { $fgBrush } else { $mutedBrush }
            $weekText.Text = if ($wkResetText) { "$wkPctText $sepDot $wkResetText" } else { $wkPctText }
            $weekText.Foreground = if ($qAvail) { $fgBrush } else { $mutedBrush }

            for ($i = 0; $i -lt 10; $i++) {
                $script:FiveCells[$i].Background = if ($i -lt $fiveLit) { $fiveBrush } else { $unlitBrush }
                $script:WeekCells[$i].Background = if ($i -lt $wkLit) { $wkBrush } else { $unlitBrush }
            }

            # Living agent activity detection (< 8 seconds since last transcript update)
            $ageSec = 9999.0
            if ($null -ne $data.lastWriteUtc -and $data.lastWriteUtc -gt [DateTime]::MinValue) {
                $ageSec = ([DateTime]::UtcNow - $data.lastWriteUtc).TotalSeconds
            }
            $script:IsThinking = ($ageSec -le 8.0)

            if ($script:IsThinking) {
                $orbitDot.Visibility = [System.Windows.Visibility]::Visible
                $moodText.Text = $bolt + ' ' + (U '\u8dc3\u8fc1\u63a8\u6f14\u4e2d...')
                $moodText.Foreground = $script:ActiveTheme.accent
                if ($tickTimer.Interval.TotalMilliseconds -ne 60) {
                    $tickTimer.Interval = [TimeSpan]::FromMilliseconds(60)
                }
            } else {
                $orbitDot.Visibility = [System.Windows.Visibility]::Collapsed
                if ($tickTimer.Interval.TotalMilliseconds -ne 150) {
                    $tickTimer.Interval = [TimeSpan]::FromMilliseconds(150)
                }
                if ($ctxPctRaw -ge 70) {
                    $moodText.Text = (E 0x1F321) + ' ' + (U '\u6838\u5fc3\u5347\u6e29') + ' /compact'
                    $moodText.Foreground = $amberBrush
                } elseif ($qAvail -and $fivePct -lt 20) {
                    $moodText.Text = (E 0x1F50B) + ' ' + (U '\u914d\u989d\u504f\u4f4e')
                    $moodText.Foreground = $redBrush
                } elseif ($ctxPctRaw -ge 45) {
                    $moodText.Text = (E 0x1F680) + ' ' + (U '\u5f15\u64ce\u9ad8\u8d1f\u8f7d')
                    $moodText.Foreground = $fgBrush
                } elseif ($qAvail -and $fivePct -ge 85) {
                    $moodText.Text = (U '\u2728') + ' ' + (U '\u7b97\u529b\u5145\u6c9b')
                    $moodText.Foreground = $fgBrush
                } else {
                    $moodText.Text = (E 0x1F6F8) + ' ' + (U '\u53cd\u91cd\u529b\u5de1\u822a')
                    $moodText.Foreground = $fgBrush
                }
            }

            # Top-Center Dynamic Island Summary
            $wkWord = U '\u5468'
            $fhPart = if ($qAvail -and $fiveResetText -ne (U '\u6ee1\u989d')) { "5h $fivePctText ($fiveResetText)" } else { "5h $fivePctText" }
            $wkPart = if ($qAvail -and $null -ne $wk -and $null -ne $wk.pct -and $wkResetText) { "$wkWord $wkPctText ($wkResetText)" } else { "$wkWord $wkPctText" }
            $tcSummary.Text = "$(Format-Tokens $ctxTok) ($($ctxPctRaw.ToString('F0'))%)  |  $fhPart  |  $wkPart"

            # Curated Drawer
            if ($null -ne $cur) {
                $drawerTitle.Text = [string]$cur.title
                $cacheWord = U '\u7f13\u5b58'
                $outWord = U '\u8f93\u51fa'
                $stepWord = U '\u6b65'
                $sign = if ([long]$cur.deltaContextTokens -ge 0) { '+' } else { '' }
                $drawerMeta.Text = "${cacheWord} $($cur.cacheHitRate)% $sepDot ${sign}$(Format-Tokens ([long]$cur.deltaContextTokens)) $sepDot ${outWord} $(Format-Tokens ([long]$cur.totalOutputTokens)) $sepDot $($cur.llmCallCount)$stepWord"
            } else {
                $drawerTitle.Text = U '\u7b49\u5f85\u672c\u5730\u4f1a\u8bdd\u65e5\u5fd7'
                $drawerMeta.Text = ''
            }

            if ($ctxPctRaw -ge 70) {
                $drawerHint.Text = (U '\u5efa\u8bae\u8fd0\u884c') + ' /compact'
                $drawerHint.Visibility = [System.Windows.Visibility]::Visible
            } else {
                $drawerHint.Visibility = [System.Windows.Visibility]::Collapsed
            }

            $drawerModels.Children.Clear()
            if ($qAvail -and $data.quota.models) {
                $curated = Curate-Models -Models $data.quota.models -ActiveLabel $data.quota.active.label
                foreach ($m in $curated.items) {
                    $row = New-Object System.Windows.Controls.Grid
                    $row.Margin = [System.Windows.Thickness]::new(0, 1.5, 0, 1.5)
                    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
                    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(42)
                    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
                    [void]$row.ColumnDefinitions.Add($c0); [void]$row.ColumnDefinitions.Add($c1); [void]$row.ColumnDefinitions.Add($c2)

                    $tbLbl = New-Object System.Windows.Controls.TextBlock
                    $tbLbl.Text = [string]$m.label
                    $tbLbl.FontSize = 10
                    $tbLbl.Foreground = if ($m.label -eq $data.quota.active.label) { $script:ActiveTheme.accent } else { $fgBrush }
                    $tbLbl.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
                    [System.Windows.Controls.Grid]::SetColumn($tbLbl, 0)

                    $barWrap = New-Object System.Windows.Controls.Grid
                    $barWrap.Height = 4
                    $barWrap.Margin = [System.Windows.Thickness]::new(5, 0, 5, 0)
                    $barWrap.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                    $bgBar = New-Object System.Windows.Controls.Border
                    $bgBar.Background = $unlitBrush
                    $bgBar.CornerRadius = [System.Windows.CornerRadius]::new(2)
                    $mfVal = if ($null -ne $m.fiveHour) { [double]$m.fiveHour.pct } else { 0.0 }
                    $fgBar = New-Object System.Windows.Controls.Border
                    $fgBar.Background = Get-QuotaBrush $mfVal
                    $fgBar.CornerRadius = [System.Windows.CornerRadius]::new(2)
                    $fgBar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
                    $fgBar.Width = ([Math]::Max(0.0, [Math]::Min(100.0, $mfVal)) / 100.0) * 32.0
                    [void]$barWrap.Children.Add($bgBar)
                    [void]$barWrap.Children.Add($fgBar)
                    [System.Windows.Controls.Grid]::SetColumn($barWrap, 1)

                    $tbVal = New-Object System.Windows.Controls.TextBlock
                    $tbVal.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas, Segoe UI')
                    $tbVal.FontSize = 9.5
                    $tbVal.Foreground = $mutedBrush
                    $mr = if ($m.fiveHour -and $m.fiveHour.resetLabel) { " $($m.fiveHour.resetLabel)" } else { '' }
                    $mw = if ($m.weekly -and ($null -ne $m.weekly.pct)) {
                        if ($m.weekly.resetLabel) { "$($m.weekly.pct)% $($m.weekly.resetLabel)" } else { "$($m.weekly.pct)%" }
                    } else { U '\u5145\u8db3' }
                    $tbVal.Text = "$($mfVal.ToString('F0'))%$mr | $mw"
                    [System.Windows.Controls.Grid]::SetColumn($tbVal, 2)

                    [void]$row.Children.Add($tbLbl)
                    [void]$row.Children.Add($barWrap)
                    [void]$row.Children.Add($tbVal)
                    [void]$drawerModels.Children.Add($row)
                }
                if ($curated.extraCount -gt 0) {
                    $drawerMore.Text = "+$($curated.extraCount) " + (U '\u4e2a\u5176\u4ed6\u6a21\u578b\u914d\u7f6e')
                    $drawerMore.Visibility = [System.Windows.Visibility]::Visible
                } else {
                    $drawerMore.Visibility = [System.Windows.Visibility]::Collapsed
                }
            }
        } catch {}
    }

    $cycleSkin = {
        $idx = [array]::IndexOf($script:SkinNames, $script:Prefs.skin)
        $nextIdx = ($idx + 1) % $script:SkinNames.Count
        $script:Prefs.skin = $script:SkinNames[$nextIdx]
        Save-Prefs
        Apply-Skin
        Render-Data
    }

    $cycleLimit = {
        $idx = [array]::IndexOf($script:LimitPresets, [int]$script:Prefs.limit)
        $nextIdx = ($idx + 1) % $script:LimitPresets.Count
        $script:Prefs.limit = $script:LimitPresets[$nextIdx]
        Save-Prefs
        Render-Data
    }

    $toggleDock = {
        if ($script:Prefs.dock -eq 'bottom-left') {
            $script:Prefs.dock = 'top-center'
        } else {
            $script:Prefs.dock = 'bottom-left'
        }
        Save-Prefs
        Apply-DockLayout
        $window.UpdateLayout()
        Update-DockPosition
    }

    $toggleExpand = {
        $script:IsExpanded = -not $script:IsExpanded
        if ($script:IsExpanded) {
            $drawerPanel.Visibility = [System.Windows.Visibility]::Visible
            $blExpandBtn.Content = $iconUp
            $tcExpandBtn.Content = $iconUp
        } else {
            $drawerPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $blExpandBtn.Content = $iconDown
            $tcExpandBtn.Content = $iconDown
        }
        $window.UpdateLayout()
        Update-DockPosition
    }

    $hideHud = {
        $script:ExitCode = 42
        $window.Close()
    }

    $blSkinBtn.Add_Click($cycleSkin)
    $tcSkinBtn.Add_Click($cycleSkin)
    $limitCycleBtn.Add_Click($cycleLimit)
    $blDockBtn.Add_Click($toggleDock)
    $tcDockBtn.Add_Click($toggleDock)
    $blExpandBtn.Add_Click($toggleExpand)
    $tcExpandBtn.Add_Click($toggleExpand)
    $blCloseBtn.Add_Click($hideHud)
    $tcCloseBtn.Add_Click($hideHud)

    $rootBorder.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.ClickCount -eq 2) {
            & $toggleExpand
            return
        }
        if ($script:Prefs.dock -eq 'free') {
            try { $window.DragMove() } catch {}
        }
    })

    # Context menu
    $menu = New-Object System.Windows.Controls.ContextMenu

    $skinMenu = New-Object System.Windows.Controls.MenuItem
    $skinMenu.Header = U '\u4e3b\u9898\u76ae\u80a4'
    foreach ($sk in $script:SkinNames) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = $script:Skins[$sk].label
        $item.Tag = $sk
        $item.IsCheckable = $true
        $item.IsChecked = ($sk -eq $script:Prefs.skin)
        $item.Add_Click({
            param($sender, $ev)
            $script:Prefs.skin = [string]$sender.Tag
            Save-Prefs
            foreach ($sub in $skinMenu.Items) {
                $sub.IsChecked = ([string]$sub.Tag -eq $script:Prefs.skin)
            }
            Apply-Skin
            Render-Data
        })
        [void]$skinMenu.Items.Add($item)
    }
    [void]$menu.Items.Add($skinMenu)

    $dockBlItem = New-Object System.Windows.Controls.MenuItem
    $dockBlItem.Header = U '\u505c\u9760\uff1a\u5de6\u4e0b\u89d2\uff08\u8bbe\u7f6e\u6309\u94ae\u4e0a\u65b9\uff09'
    $dockBlItem.Add_Click({
        $script:Prefs.dock = 'bottom-left'
        Save-Prefs
        Apply-DockLayout
        $window.UpdateLayout()
        Update-DockPosition
    })
    [void]$menu.Items.Add($dockBlItem)

    $dockTcItem = New-Object System.Windows.Controls.MenuItem
    $dockTcItem.Header = U '\u505c\u9760\uff1a\u6700\u4e0a\u9762\u4e2d\u95f4\uff08\u6807\u9898\u680f\u5c45\u4e2d\uff09'
    $dockTcItem.Add_Click({
        $script:Prefs.dock = 'top-center'
        Save-Prefs
        Apply-DockLayout
        $window.UpdateLayout()
        Update-DockPosition
    })
    [void]$menu.Items.Add($dockTcItem)

    $dockFreeItem = New-Object System.Windows.Controls.MenuItem
    $dockFreeItem.Header = U '\u505c\u9760\uff1a\u81ea\u7531\u62d6\u52a8'
    $dockFreeItem.Add_Click({
        $script:Prefs.dock = 'free'
        Save-Prefs
        Apply-DockLayout
    })
    [void]$menu.Items.Add($dockFreeItem)

    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $limitMenu = New-Object System.Windows.Controls.MenuItem
    $limitMenu.Header = U '\u4e0a\u4e0b\u6587\u4e0a\u9650'
    foreach ($val in $script:LimitPresets) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = Format-LimitLabel $val
        $item.Tag = $val
        $item.IsCheckable = $true
        $item.IsChecked = ($val -eq $script:Prefs.limit)
        $item.Add_Click({
            param($sender, $ev)
            $script:Prefs.limit = [int]$sender.Tag
            Save-Prefs
            foreach ($sub in $limitMenu.Items) {
                $sub.IsChecked = ([int]$sub.Tag -eq $script:Prefs.limit)
            }
            Render-Data
        })
        [void]$limitMenu.Items.Add($item)
    }
    [void]$menu.Items.Add($limitMenu)

    $refreshItem = New-Object System.Windows.Controls.MenuItem
    $refreshItem.Header = U '\u5237\u65b0\u914d\u989d'
    $refreshItem.Add_Click({ Render-Data -ForceRefresh })
    [void]$menu.Items.Add($refreshItem)

    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $exitItem = New-Object System.Windows.Controls.MenuItem
    $exitItem.Header = U '\u9690\u85cf\u6302\u4ef6'
    $exitItem.Add_Click($hideHud)
    [void]$menu.Items.Add($exitItem)

    $rootBorder.ContextMenu = $menu

    $tickTimer = New-Object System.Windows.Threading.DispatcherTimer
    $tickTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $tickTimer.Add_Tick({
        try {
            if (Test-Path -LiteralPath $instanceFile -PathType Leaf) {
                $inst = Get-Content -LiteralPath $instanceFile -Raw | ConvertFrom-Json
                if ([int]$inst.pid -ne $PID) {
                    $script:ExitCode = 0
                    $window.Close()
                    return
                }
            }
            if ($ParentPid -gt 0) {
                if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
                    $script:ExitCode = 0
                    $window.Close()
                    return
                }
            }
        } catch {}

        if ($script:IsThinking) {
            $script:OrbitAngle += 0.24
            $ox = 24.0 + 22.0 * [Math]::Cos($script:OrbitAngle) - 2.5
            $oy = 24.0 + 22.0 * [Math]::Sin($script:OrbitAngle) - 2.5
            [System.Windows.Controls.Canvas]::SetLeft($orbitDot, $ox)
            [System.Windows.Controls.Canvas]::SetTop($orbitDot, $oy)
        }

        Update-DockPosition

        if (([DateTime]::UtcNow - $script:LastDataFetch).TotalMilliseconds -ge 2000) {
            $script:LastDataFetch = [DateTime]::UtcNow
            Render-Data
        }
    })

    $initialWin = [Win32.HudNative]::FindAntigravityWindow()
    if ($initialWin.Hwnd -ne [IntPtr]::Zero) {
        (New-Object System.Windows.Interop.WindowInteropHelper($window)).Owner = $initialWin.Hwnd
        $script:OwnerAttached = $initialWin.Hwnd
        $window.Topmost = $false
    } else {
        $window.Topmost = $true
    }

    Apply-Skin
    Apply-DockLayout

    $window.Add_Loaded({
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][Win32.HudNative]::ShowWindow($hwnd, 4)
        }
        $script:LastDataFetch = [DateTime]::UtcNow
        Render-Data -ForceRefresh
        $window.UpdateLayout()
        Update-DockPosition
        $tickTimer.Start()
    })

    $window.Add_Closed({
        $tickTimer.Stop()
        [System.Windows.Threading.Dispatcher]::ExitAllFrames()
    })

    $window.Show()
    [System.Windows.Threading.Dispatcher]::Run()
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}

exit $script:ExitCode
