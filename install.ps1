$ErrorActionPreference = 'Stop'

$src = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$pluginRoot = Join-Path $HOME '.gemini\config\plugins'
$dest = [System.IO.Path]::GetFullPath((Join-Path $pluginRoot 'context-viewer')).TrimEnd('\')

if ($src -ne $dest) {
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $src -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
        $targetPath = Join-Path $dest $_.Name
        if ($_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $targetPath -Force
        }
    }
    Write-Output "Installed Context Viewer plugin to: $dest"
} else {
    Write-Output "Context Viewer is already in the Antigravity plugins directory: $dest"
}

$instPath = Join-Path $env:TEMP 'ag-cv-hud-instance.json'
if (Test-Path -LiteralPath $instPath -PathType Leaf) {
    try {
        '{"pid":0,"apiUrl":"reload"}' | Set-Content -LiteralPath $instPath -Encoding Ascii
        Write-Output "Triggered hot-reload for active Telemetry Pod HUD."
    } catch {}
}

Write-Output "Next: Open Antigravity -> Customizations -> ensure 'context-viewer' is Enabled (toggle Disable -> Enable if upgrading)."
