# install-client.ps1
# Adds a hardened "Zellij" terminal profile to this machine's VS Code User
# Settings. Run ONCE per new Windows client. Safe to re-run.
#
#   irm https://raw.githubusercontent.com/talmo/zellij-vscode/main/install-client.ps1 | iex
#
# Auto-merge needs PowerShell 7 (pwsh). On Windows PowerShell 5.1 it backs up,
# prints the block to paste, and opens settings.json.
$ErrorActionPreference = 'Stop'
$RAW = 'https://raw.githubusercontent.com/talmo/zellij-vscode/main'

# Prefer the JSONC-aware merger via `uv run` (uv supplies the Python; no system
# Python is used): it preserves comments/trailing commas and validates before
# writing. Falls through to the PowerShell merge below when uv is absent.
if (Get-Command uv -ErrorAction SilentlyContinue) {
    $merge = Join-Path ([IO.Path]::GetTempPath()) 'merge_settings.py'
    try {
        Invoke-WebRequest -UseBasicParsing "$RAW/merge_settings.py" -OutFile $merge
        & uv run --no-project $merge @args
        Remove-Item $merge -ErrorAction SilentlyContinue
        exit $LASTEXITCODE
    } catch {
        Remove-Item $merge -ErrorAction SilentlyContinue
        Write-Host "uv merge unavailable ($_); using PowerShell fallback."
    }
}

# The self-contained profile command. Remote-SSH runs this on the *remote*
# Linux host, so it targets the .linux profile keys.
$cmd = 'if command -v zellij >/dev/null 2>&1 && [ -z "$ZELLIJ" ]; then zellij attach --create "$(basename "$PWD" | tr '' '' ''_'')"; fi; exec "${SHELL:-bash}" -l'
# (the doubled single-quotes above are PowerShell escaping for the literal  tr ' ' '_' )

$profile = [ordered]@{ path = 'bash'; args = @('-lc', $cmd) }

# Locate settings.json (Code, Insiders, VSCodium)
$settings = $null
foreach ($d in 'Code', 'Code - Insiders', 'VSCodium') {
    $p = Join-Path $env:APPDATA "$d\User\settings.json"
    if (Test-Path (Split-Path $p)) { $settings = $p; break }
}
if (-not $settings) { $settings = Join-Path $env:APPDATA 'Code\User\settings.json' }
New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
if (-not (Test-Path $settings)) { '{}' | Set-Content -Path $settings -Encoding utf8 }

$backup = "$settings.bak.$(Get-Date -Format yyyyMMddHHmmss)"
Copy-Item $settings $backup

$canMerge = $PSVersionTable.PSVersion.Major -ge 6
if ($canMerge) {
    try {
        $obj = Get-Content -Raw $settings | ConvertFrom-Json -AsHashtable
    } catch { $canMerge = $false }
}

if ($canMerge) {
    if (-not $obj) { $obj = @{} }
    if (-not $obj['terminal.integrated.profiles.linux']) { $obj['terminal.integrated.profiles.linux'] = @{} }
    $obj['terminal.integrated.profiles.linux']['Zellij'] = $profile
    $obj['terminal.integrated.defaultProfile.linux'] = 'Zellij'
    ($obj | ConvertTo-Json -Depth 100) | Set-Content -Path $settings -Encoding utf8
    Write-Host "OK  Updated $settings"
    Write-Host "    Backup: $backup"
} else {
    Write-Host "!!  Auto-merge needs PowerShell 7, or settings.json has comments (JSONC)."
    Write-Host "    Backup at $backup. Paste this into settings.json manually:`n"
    $block = ($profile | ConvertTo-Json -Depth 100 -Compress)
    Write-Host "`"terminal.integrated.profiles.linux`": { `"Zellij`": $block },"
    Write-Host "`"terminal.integrated.defaultProfile.linux`": `"Zellij`","
    try { code $settings } catch {}
}
