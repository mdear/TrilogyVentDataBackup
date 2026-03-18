# Developer Setup & Contributing Guide

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Windows | 10 or 11 | COM/Shell interop required |
| PowerShell | 5.1 (**built-in** on Windows 10/11) | Do **not** use PowerShell 7 — the wizard targets 5.1 |
| Pester | ≥ 5.0 | PowerShell test framework — see [Installing Pester](#installing-pester) |
| Python | 3.10+ | Only needed for the one-off icon-analysis dev script |
| Git | any recent | For version control |

---

## Cloning the repo

```powershell
git clone <repo-url>
cd VentDataBackup_2023-2026
```

The repository root is the **workspace root** — `scripts/` is a subdirectory.
Never commit anything outside `scripts/`, `.github/`, `Launch-VentBackupManager.cmd`,
or `README.md`: all other folders are patient/device data and are gitignored.

---

## Installing Pester (PowerShell test framework)

Pester 5 must be installed once per machine.  Run this in any PowerShell window as
**Administrator** (needed to write to the system module path):

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```

Verify the install:

```powershell
Get-Module -ListAvailable Pester | Select-Object Name, Version
# Should show Version 5.x.x
```

> **Note:** Windows ships with Pester 3.4 in `C:\Windows\System32\WindowsPowerShell`.
> The `-Force` flag above installs 5.x into `$env:ProgramFiles\WindowsPowerShell\Modules`
> and takes precedence automatically.

---

## Running the unit tests

All tests live in `scripts/tests/`.  Run from a PowerShell 5.1 prompt:

```powershell
# All tests
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\Run-Tests.ps1

# Single module (e.g. just the Analyzer tests)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\Run-Tests.ps1 -Filter Analyzer
```

Available `-Filter` values match the module name suffix:

| Filter | File run |
|---|---|
| `Analyzer` | `VBM-Analyzer.Tests.ps1` |
| `Backup` | `VBM-Backup.Tests.ps1` |
| `Dedup` | `VBM-Dedup.Tests.ps1` |
| `EntryPoint` | `VBM-EntryPoint.Tests.ps1` |
| `Export` | `VBM-Export.Tests.ps1` |
| `GoldenArchive` | `VBM-GoldenArchive.Tests.ps1` |
| `GoldenContent` | `VBM-GoldenContent.Tests.ps1` |
| `Parsers` | `VBM-Parsers.Tests.ps1` |
| `UI` | `VBM-UI.Tests.ps1` |

Tests produce a `scripts/tests/last-run.log` file (gitignored) with the full
Pester output.

---

## Python environment (dev-only)

Python is only used by `scripts/analyze_shield_reference.py` — a one-off
script used during icon development to analyse pixel data from a reference image.
It is **not** used at runtime by the wizard.

### Setting up the venv

```bash
# From the workspace root
python -m venv ~/workspace/venv/vent_data_backup
source ~/workspace/venv/vent_data_backup/Scripts/activate   # bash/Git Bash
# or on plain PowerShell:
# & ~/workspace/venv/vent_data_backup/Scripts/Activate.ps1

pip install -r scripts/requirements.txt
```

### Updating dependencies

`scripts/requirements.in` is the human-maintained direct-dependency file.
`scripts/requirements.txt` is the pinned lockfile derived from it.

To regenerate the lockfile after changing `requirements.in`:

```bash
pip install pip-tools
pip-compile scripts/requirements.in -o scripts/requirements.txt
```

---

## Linting / syntax validation

A lightweight PowerShell syntax check runs against all modules and the entry point:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate_syntax.ps1
```

This uses PowerShell's built-in parser (`[System.Management.Automation.Language.Parser]`)
and exits non-zero on any syntax error.

---

## Rebuilding the icon (dev-only)

The `.ico` file in `scripts/assets/` is pre-built and committed.
Only regenerate it if the icon design changes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Icon.ps1
```

---

## Project structure

```
.github/
  docs/
    ARCHITECTURE.md   # What the tool does and why (requirements, features)
    DESIGN.md         # How it is built (algorithms, data flow, module layout)
    CONTRIBUTING.md   # This file

scripts/
  VentBackupManager.ps1        # Wizard entry point
  Install-DesktopShortcut.ps1  # Creates a Desktop shortcut (run once)
  Build-Icon.ps1               # Dev-only: regenerates the .ico asset
  validate_syntax.ps1          # Dev-only: PS syntax check
  analyze_shield_reference.py  # Dev-only: one-off icon pixel analysis
  requirements.in              # Direct Python dependencies
  requirements.txt             # Pinned Python lockfile
  assets/
    VentBackupManager.ico      # Pre-built icon (committed binary)
  modules/
    VBM-Parsers.psm1
    VBM-Analyzer.psm1
    VBM-GoldenArchive.psm1
    VBM-Export.psm1
    VBM-Backup.psm1
    VBM-Dedup.psm1
    VBM-UI.psm1
  tests/
    Run-Tests.ps1              # Test runner (wraps Pester)
    Fixtures.ps1               # Shared test helpers and in-memory fixture builders
    VBM-*.Tests.ps1            # One file per module

Launch-VentBackupManager.cmd   # Double-click launcher for end users
README.md                      # End-user guide
```
