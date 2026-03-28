<#
.SYNOPSIS
    Creates a desktop shortcut for VentBackupManager with a custom icon.
.DESCRIPTION
    Run this once to place a shortcut on the Desktop. If Windows Terminal is
    installed, a profile is injected so the icon shows in the tab bar.
    Requires: Windows PowerShell 5.1+
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Install-DesktopShortcut.ps1
#>
[CmdletBinding()]
param(
    [string]$ShortcutName = "Ventilator Backup Manager"
)

$ErrorActionPreference = 'Stop'
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir    = Split-Path -Parent $scriptDir
$assetsDir  = Join-Path $scriptDir 'assets'
$icoPath    = Join-Path $assetsDir 'VentBackupManager.ico'
$cmdPath    = Join-Path $rootDir   'Launch-VentBackupManager.cmd'

# 1. Ensure assets directory exists
if (-not (Test-Path $assetsDir)) {
    New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
}

# 2. Generate the .ico file if it does not exist
if (-not (Test-Path $icoPath)) {
    Write-Host "Generating icon..." -ForegroundColor Cyan
    & (Join-Path $scriptDir 'Build-Icon.ps1')
}

# 3. Inject a Windows Terminal profile using Python for safe JSON handling
$vtGuid = '{a8c3e636-8b5a-4c78-b0e1-9e3a2d5c7f12}'
$useWT  = $false
$pyHelper = Join-Path $scriptDir '_inject_wt_profile.py'

$wtCandidates = @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
)
$wtSettings = $wtCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($wtSettings -and (Test-Path $pyHelper)) {
    Write-Host "Configuring Windows Terminal profile..." -ForegroundColor Cyan
    try {
        $pyArgs = @($pyHelper, $wtSettings, $vtGuid, $ShortcutName, $icoPath, $cmdPath, $rootDir)
        $result = & python $pyArgs 2>&1
        Write-Host "  $result" -ForegroundColor Green
        $useWT = $true
    } catch {
        Write-Warning "  Could not update Windows Terminal settings: $_"
    }
} elseif ($wtSettings) {
    Write-Warning "  Python not found — skipping Windows Terminal profile injection."
}

# 4. Create the desktop shortcut
$desktopPath = [Environment]::GetFolderPath('Desktop')
$lnkPath     = Join-Path $desktopPath "$ShortcutName.lnk"

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)

if ($useWT) {
    $wtExe = (Get-Command wt.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    if (-not $wtExe) { $wtExe = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe" }
    $shortcut.TargetPath = $wtExe
    $shortcut.Arguments  = "--profile `"$ShortcutName`""
    Write-Host "  Shortcut targets Windows Terminal profile." -ForegroundColor Cyan
} else {
    $shortcut.TargetPath = $cmdPath
}

$shortcut.WorkingDirectory = $rootDir
$shortcut.IconLocation     = "$icoPath, 0"
$shortcut.Description      = "Launch the Trilogy 200 ventilator backup wizard"
$shortcut.WindowStyle      = 1
$shortcut.Save()

Write-Host ""
Write-Host "  Desktop shortcut created:" -ForegroundColor Green
Write-Host "  $lnkPath" -ForegroundColor White
Write-Host ""
