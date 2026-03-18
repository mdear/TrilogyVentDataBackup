@echo off
:: VentBackupManager Wizard Launcher
:: Double-click this file to start the ventilator backup manager.
:: ---------------------------------------------------------------

title Ventilator Backup Manager

:: Resolve this script's directory (handles spaces, Dropbox paths, UNC)
pushd "%~dp0"

:: Verify PowerShell is available
where powershell >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo.
    echo  ERROR: PowerShell is not available on this system.
    echo  Please install Windows PowerShell 5.1 or later.
    echo.
    pause
    exit /b 1
)

:: Verify the main script exists
if not exist "scripts\VentBackupManager.ps1" (
    echo.
    echo  ERROR: scripts\VentBackupManager.ps1 not found.
    echo  Make sure this launcher is in the backup root folder
    echo  alongside the scripts\ directory.
    echo.
    pause
    exit /b 1
)

:: Launch the wizard
:: -ExecutionPolicy Bypass: avoids "not digitally signed" blocks
:: -NoProfile: skips user profile for clean, predictable startup
:: -File: executes the script (no variable-interpolation pitfalls)
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "scripts\VentBackupManager.ps1"

:: If PowerShell exited with an error, pause so the user can read it
if %ERRORLEVEL% neq 0 (
    echo.
    echo  The wizard exited with an error. Press any key to close.
    pause >nul
)

popd
