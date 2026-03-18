# VentBackupManager — Design Document

## Table of Contents

- [Overview](#overview)
- [Implementation Notes for Fresh Sessions](#implementation-notes-for-fresh-sessions)
  - [PowerShell Execution Notes](#powershell-execution-notes)
  - [Validation Rules by File Type](#validation-rules-by-file-type)
  - [Contamination Detection Algorithm](#contamination-detection-algorithm-for-test-backupintegrity)
  - [DirectView Compatibility Requirements](#directview-compatibility-requirements)
  - [Golden Archive Semantics](#golden-archive-semantics)
- [Module Layout](#module-layout)
- [VBM-Parsers.psm1](#vbm-parserspsm1)
- [VBM-Analyzer.psm1](#vbm-analyzerpsm1)
  - [Get-BackupInventory](#get-backupinventory--backuproot-path)
  - [Get-BackupTOC](#get-backuptoc--inventory-array---progresscallback-scriptblock)
  - [Test-BackupIntegrity](#test-backupintegrity--backupdetail-obj)
  - [Get-DeviceTimeline](#get-devicetimeline--toc-obj--deviceserial-string)
  - [Write-ContaminationReadme](#write-contaminationreadme--backuppath-path--anomalies-array--toc-obj)
  - [Show-TOC](#show-toc--toc-obj)
- [VBM-GoldenArchive.psm1](#vbm-goldenarchivepsm1)
  - [New-GoldenArchive](#new-goldenarchive--toc-obj--goldenroot-path---devices-string)
  - [Update-GoldenArchive](#update-goldenarchive--toc-obj--goldenroot-path--previousgolden-path)
  - [manifest.json Schema](#manifestjson-schema)
  - [Test-GoldenIntegrity](#test-goldenintegrity--goldenpath-path)
- [VBM-Export.psm1](#vbm-exportpsm1)
  - [Export-ToTarget](#export-totarget--goldenpath-path--target-path---devices-string)
  - [Show-TargetContents](#show-targetcontents--target-path)
  - [Write-ExportReadme](#write-exportreadme--target-path--devices-hashtable)
- [VBM-Backup.psm1](#vbm-backuppsm1)
  - [Import-SDCard](#import-sdcard--source-path--backuproot-path)
- [VBM-Dedup.psm1](#vbm-deduppsm1)
  - [Invoke-Compaction](#invoke-compaction--backuproot-path--safetypath-path)
  - [Test-IsHardlinked](#test-ishardlinked--path-path)
- [VBM-UI.psm1](#vbm-uipsm1)
  - [Wizard Functions](#wizard-functions)
  - [Show-DeviceSelection Behavior](#show-deviceselection-behavior)
- [VentBackupManager.ps1 (Entry Point)](#ventbackupmanagerps1-entry-point)
- [Data Flow Summary](#data-flow-summary)

---

## Overview

This document describes the software design: module decomposition, function signatures,
data structures, algorithms, and data flow. See ARCHITECTURE.md for the "why" and "what",
including the complete data format reference for all file types.

## Implementation Notes for Fresh Sessions

This section captures decisions and pitfalls discovered during reverse-engineering.
Read ARCHITECTURE.md "SD Card Data Format Reference" before implementing.

### PowerShell Execution Notes
- **Run scripts with `-File`, not `-Command`** — avoids variable interpolation issues
- **Execution policy**: The default policy on end-user machines blocks unsigned scripts.
  `Launch-VentBackupManager.cmd` invokes PowerShell with `-ExecutionPolicy Bypass` so
  the user never sees a security error. Direct invocations (dev/testing) should also
  use `-ExecutionPolicy Bypass -File script.ps1`.
- All modules use `Import-Module` with relative paths from the entry point
- **Source `.psm1` and `.ps1` files must be saved as UTF-8 with BOM**. PowerShell 5.1
  reads BOM-less files as Windows-1252 (CP1252). UTF-8 bytes for non-ASCII characters
  such as em-dash (U+2014, `\xE2\x80\x94`) or bullet (U+2022) decode as CP1252 sequences
  where `\x94` maps to U+201D (right curly quote), which PS 5.1 treats as a string
  terminator. All output files and scripts must be UTF-8 with BOM.
- UTF-8 with BOM is safe for all output files (PowerShell default)
- Use `[System.IO.File]::ReadAllBytes()` for binary reads (EDF headers, EL_ CSV)
- Use `Get-Content -Raw` for text files (prop.txt, last.txt, PP JSON)

### Validation Rules by File Type
- **EDF files < 256 bytes → corrupt** (header alone is 256 bytes)
- **EDF NumDataRecords = "-1"** is valid per spec (unknown at write time, active tip)
- **AD/DD pairing**: AD_YYYYMM_NNN must have DD_YYYYMM_NNN. Flag unpaired as anomaly, not error.
- **SL_SAPPHIRE.json**: size must grow monotonically across backups for same device.
  If backup B has smaller SL_SAPPHIRE.json than older backup A → flag as truncated copy.
- **FILES.SEQ line count must be ≥ TRANSMITFILE.SEQ line count** (superset rule).
- **BIN files: opaque** — cannot validate content, only validate filename pattern parse.
- **EL_ CSV: binary format** — validate SN from first ~100 bytes with
  `$enc.GetString($bytes, 0, [Math]::Min($bytes.Length, 100))` and regex `TV\w+`.
  Do not attempt CSV text parsing.
- **PP JSON**: must have `SN` and `TimeStamp` fields. `BlowerHours` is in 1/10th-hour
  units (~6 minutes). `TimeStamp` is Unix epoch seconds.
- **prop.txt PT field is hex** (0x32, 0x65) — corresponds to BIN filename
  ProductType but BIN uses bare hex digits ("32", "65"), not "0x32".
  To compare: strip "0x" prefix from prop.txt PT before matching BIN filenames.
- **prop.txt VC key is optional** — only present on newer CA1032800B devices.
  Parser must not fail if VC is absent.
- **EDF RecordingID field labeled DevClass (0x8408) is a CONSTANT** across all
  devices. Do NOT use it for device identification. Use the SN field only.

### Contamination Detection Algorithm (for `Test-BackupIntegrity`)
1. For each backup, build the **expected device set** from P-Series:
   enumerate all `P-Series/{SN}/prop.txt` entries. This is the authoritative
   device roster for that SD card image.
2. If no P-Series exists, fall back to majority-SN voting across EDF headers.
3. For each Trilogy EDF file, read the header and extract the SN.
4. If the SN is in the expected device set → legitimate.
5. If the SN is NOT in the expected set → flag as contamination.
6. Cross-reference with `P-Series/last.txt` to identify the *active* device
   (the one currently recording). Files from non-active but expected devices
   are historical data, not contamination.
7. **Majority-inversion trap**: A contaminated backup may have MORE foreign
   files than original files (e.g., 12.1.2025.002 has 95 TVXX0000004 files
   overwriting TVXX0000001). Never rely on majority voting alone — always
   prefer the P-Series roster, and cross-reference against the clean copy
   of the same backup if one exists (e.g., 12.1.2025 vs 12.1.2025.002).

### DirectView Compatibility Requirements
- Single-device export must mirror native SD card layout exactly:
  `/Trilogy/`, `/P-Series/`, with `last.txt` pointing to the device SN
- Subsequent goldens must produce a complete, standalone dataset per included
  device — DirectView expects all files present, not deltas
- Multi-device exports use `/{SN}/Trilogy/` and `/{SN}/P-Series/` subdirectories.
  DirectView is pointed at each `{SN}/` subfolder individually.

### Golden Archive Semantics
- **Roster = devices with CHANGED DATA**, not current physical device roster
- First golden: all devices with any data
- Subsequent golden: only devices with new/modified data since last golden
- Each included device gets its complete dataset (self-contained)
- `manifest.json` references the previous golden for full chain of custody

## Module Layout

```
{BackupRoot}/
  Launch-VentBackupManager.cmd   # Double-click launcher for non-technical users.
                                 # Sets execution policy bypass and calls VentBackupManager.ps1.
  README.md                      # User-facing guide: what the tool does, how to run it.

scripts/
  VentBackupManager.ps1          # Entry point: CLI params + wizard dispatcher.
                                 # On first run (wizard mode), calls _CheckDesktopShortcut —
                                 # see "First-Run Setup" section below.
  Install-DesktopShortcut.ps1    # Creates a Desktop shortcut pointing to
                                 # Launch-VentBackupManager.cmd with the .ico file.
                                 # Invoked automatically by VentBackupManager.ps1 on first
                                 # wizard run when user requests it. Can also be run directly.
  settings.json                  # Local state file — created on first wizard run.
                                 # Persists per-user preferences (e.g. skipShortcutPrompt).
                                 # NOT committed to source control (see .gitignore).
  Build-Icon.ps1                 # Dev-only: regenerates assets/VentBackupManager.ico.
                                 # Not used at runtime; run once during development.
  assets/
    VentBackupManager.ico        # Pre-built multi-resolution icon (16/32/48/256px PNG frames).
                                 # Committed to repo as a binary asset; do NOT regenerate at
                                 # runtime. Used by Install-DesktopShortcut.ps1.
  modules/
    VBM-Parsers.psm1             # File format parsers (EDF, PP, prop, FILES.SEQ, etc.)
    VBM-Analyzer.psm1            # Scan backups, build TOC, detect contamination
    VBM-GoldenArchive.psm1       # Build/update golden archives
    VBM-Export.psm1              # Write golden archive to SD card / folder
    VBM-Backup.psm1              # Ingest SD card to timestamped backup folder
    VBM-Dedup.psm1               # Hardlink deduplication with safety protocol
    VBM-UI.psm1                  # Wizard prompts, progress display, formatting
  ARCHITECTURE.md                # Why and what (requirements, features)
  DESIGN.md                      # How (this file)
```

## VBM-Parsers.psm1

Stateless functions that parse every file format on the SD card.

| Function | Input | Returns |
|----------|-------|---------|
| `Read-EdfHeader` | Path | PSObject with Version, PatientID, RecordingID, StartDate, StartTime, HeaderBytes, Reserved, NumDataRecords, RecordDuration, NumSignals, FileSize |
| `Get-EdfDeviceSerial` | Path | String serial number extracted from RecordingID via regex `\b(TV\w+)\b` |
| `Get-EdfDateInfo` | Path | PSObject with FileType (AD/DD/WD/PD/PA), Year, Month, Day, Sequence, IsDaily — parsed from filename |
| `Read-PropFile` | Path | PSObject from key=value lines: CF, SN, MN, PT, SV, DF, VC |
| `Read-LastTxt` | Path | String (trimmed file content) |
| `Read-FilesSeq` | Path | PSObject with Paths (string array), CrcHash (last line if 8 hex chars), LineCount |
| `Read-PpJson` | Path | Parsed JSON object (TimeStamp, SN, MN, BlowerHours, battery fields, SD card fields, CRC) |
| `Get-BinFileInfo` | Path | PSObject with ProductType, SerialNumber, DumpType, UnixTimestamp, DateTime — parsed from filename pattern `{PT}_{SN}_{Type}_{UnixTS}.bin` |
| `Get-ElCsvInfo` | Path | PSObject with SerialNumber, DateString — parsed from filename `EL_{SN}_{YYYYMMDD}.csv` |
| `Get-PpJsonDateInfo` | Path | PSObject with Year, Month, Day, Sequence — parsed from `PP_YYYYMMDD_NNN.json` |
| `Get-FileHashMD5` | Path | MD5 hash string via `Get-FileHash` |

## VBM-Analyzer.psm1

Scans backup directories and builds the data model used by all other modules.

### `Get-BackupInventory -BackupRoot <path>`
Discovers backup folders. A valid backup folder has a `Trilogy/` or `P-Series/`
subdirectory. Also discovers nested backup locations (e.g. `4.10.2024/vent 2/`).

**Exclusion patterns** (folders inside BackupRoot that are NOT backups):
- `scripts/` — the toolchain itself
- `_golden_*` — golden archive output directories
- Any folder starting with `.` or `_` (convention for non-backup data)
- `nul` (artifact file sometimes created by Windows)

These must be skipped during discovery to prevent false positives.

Returns: Array of PSObjects:
```
@{
    Name        = "12.1.2025"
    Path        = "D:\...\12.1.2025"
    HasTrilogy  = $true
    HasPSeries  = $true
    SubBackups  = @()  # e.g. "vent 2" nested inside
}
```

### `Get-BackupTOC -Inventory <array> [-ProgressCallback <scriptblock>]`
For each backup, scans every file:
- EDF files: reads header to get device SN, date info, file size
- BIN files: parses filename for SN + timestamp
- EL_ CSV: parses filename for SN + date
- P-Series: reads last.txt, prop.txt, FILES.SEQ per device folder
- PP JSON: reads timestamp and BlowerHours

Returns a TOC object:
```
@{
    Backups = @{
        "12.1.2025" = @{
            Path = "..."
            Devices = @{
                "TVXX0000001" = @{
                    TrilogyFiles = @(...)   # array of file detail objects
                    PSeriesFiles = @(...)
                    EarliestDate = "2023-03"
                    LatestDate   = "2025-12"
                    FileCount    = 750
                    Model        = "CA1032800"
                    ProductType  = "0x32"
                    Firmware     = "14.2.05"
                }
            }
            Integrity = "Clean" | "Contaminated"
            Anomalies = @(...)
        }
    }
    Devices = @{
        "TVXX0000001" = @{
            BackupPresence = @("12.1.2025", "4.10.2024")
            OverallEarliest = "2023-03"
            OverallLatest   = "2025-12"
            TotalUniqueFiles = 800
        }
    }
}
```

### `Test-BackupIntegrity -BackupDetail <obj> -TOC <obj>`
Checks a single backup for issues. Requires the full TOC for cross-backup
comparisons (truncation detection).
1. **Contamination**: For each EDF file, verify that the embedded SN is in the
   expected device set (derived from P-Series roster, NOT majority voting).
   Flag files where SN is not in the expected set.
2. **Missing pairs**: AD_YYYYMM_NNN must have matching DD_YYYYMM_NNN and vice versa.
3. **Truncated files**: Compare file sizes against the same filename in other backups
   (via TOC). If this backup has a drastically smaller version, flag as potentially
   truncated or contaminated.
4. **P-Series consistency**: FILES.SEQ entries should match actual files on disk.
5. **Size regression**: For monotonically growing files (FILES.SEQ, SL_SAPPHIRE.json),
   compare against older backups of the same device. Smaller = corruption.

Returns array of anomaly objects: `@{ Type, Severity, File, Detail, Suggestion }`.

### `Get-DeviceTimeline -TOC <obj> -DeviceSerial <string>`
Builds a per-device chronological view across all backups.

### `Write-ContaminationReadme -BackupPath <path> -Anomalies <array> -TOC <obj>`
Generates `README.md` in the backup folder listing contaminated files, expected vs
actual SN, and where clean versions can be found.

### `Show-TOC -TOC <obj>`
Renders the Table of Contents to the console:
- Summary table of all backups
- Per-device timeline with ASCII bar chart
- Contamination warnings highlighted
- Shows where the most recent backup fits in the timeline

## VBM-GoldenArchive.psm1

### `New-GoldenArchive -TOC <obj> -GoldenRoot <path> [-Devices <string[]>] [-ForceDevices <string[]>] [-ForceReason <string>]`
Builds the first golden archive.

**Algorithm**:
1. For each device (or specified subset):
   a. Gather all files attributed to that device across all clean backups.
      Attribution comes from EDF header SN (Trilogy files), filename SN
      (EL_ CSV, BIN), or folder path (P-Series/{SN}/).
   b. Group by (device SN + relative filename), e.g. group all copies of
      `AD_202303_000.edf` attributed to TVXX0000001 across backups.
      **IMPORTANT**: The same filename (e.g. AD_202408_000.edf) may exist
      for DIFFERENT devices — SN filtering in step (a) prevents cross-device
      mixing. Never group by filename alone.
   c. For each group: pick the file with the largest size (most complete tip)
   d. Verify picked file's EDF header SN matches the target device
   e. Copy into `_golden_YYYY-MM-DD/{SN}/Trilogy/` and `.../P-Series/`
2. For P-Series: take the most recent backup's version of steering files
   (FILES.SEQ, TRANSMITFILE.SEQ, SL_SAPPHIRE.json, prop.txt) since they grow
   monotonically. Ring buffer slots (P0-P7): collect ALL unique files from
   ALL backups since the ring buffer is circular and older backups may hold
   sessions that were since overwritten on the SD card.
3. If device is flagged `SplitSD = $true` (see `Detect-SplitSD`): merge files
   from all contributing backup spans. Collision on the same filename for the
   same device across non-overlapping spans is flagged as a contamination anomaly
   rather than silently resolved.
4. Generate `last.txt` inside each device's P-Series directory pointing to
   that device's SN (i.e., `_golden_YYYY-MM-DD/{SN}/P-Series/last.txt`
   contains `{SN}`).
5. Write `manifest.json` and `README.md`
6. Run `Test-GoldenIntegrity` then `Test-GoldenContent` on the result.
   Both results are printed to the console. Issues do not block the return;
   the golden path is returned to the caller regardless.

**ForceDevices override**: When `-ForceDevices` is supplied, that array is used as
the target device list regardless of the algorithm's own suggestion or the `-Devices`
parameter. `$ForceReason` is recorded in `manifest.json` as `forcedDevicesReason`.
Both `-ForceDevices` and `-ForceReason` should be supplied together; if only
`-ForceDevices` is given, a generic reason is recorded.

### `Update-GoldenArchive -TOC <obj> -GoldenRoot <path> -PreviousGolden <path> [-ForceDevices <string[]>] [-ForceReason <string>]`
Builds an incremental golden.

**Algorithm**:
1. Load previous golden's `manifest.json`
2. For each device in TOC, compare current file hashes against manifest
3. Identify devices with changed data (new files, larger files, different hashes)
4. **If `-ForceDevices` is supplied**: skip step 3 entirely and use the supplied
   list as the set of devices to include. Record `forcedDevicesReason` in the new
   manifest. This is the primary mechanism for the "force specific devices" feature.
5. For each included device: build complete dataset (same as `New-GoldenArchive`,
   including SplitSD merge logic if applicable)
6. Unchanged/excluded devices are omitted from this golden
7. Write new `manifest.json` referencing the previous golden
8. Run `Test-GoldenIntegrity` then `Test-GoldenContent`; print results to console

### `Detect-SplitSD -TOC <obj>` (VBM-Analyzer.psm1)

Analyses device data across all clean backups to identify SNs that appear to have
come from two separate SD cards (non-overlapping date ranges).

**Returns**: Hashtable of `SN -> @{ SplitSD=$true; Spans=@( @{BackupNames=@(...); Earliest="..."; Latest="..."} ) }`,
only for devices where a split is detected. Devices without a split are omitted.

**Algorithm**:
1. For each SN in `$TOC.Devices`, collect the `(BackupName, EarliestDate, LatestDate)`
   tuples from all clean backups where that SN appears.
2. Sort the tuples by `EarliestDate`.
3. Walk the sorted list: if the gap between the `LatestDate` of group N and
   `EarliestDate` of group N+1 exceeds the `SplitGapMonths` threshold (default 2
   months), AND the BlowerHours trajectory from PP JSON files shows a discontinuity
   (i.e. the later set's earliest BlowerHours value is not a natural continuation of
   the earlier set's latest value — a delta jump > `BlowerHoursJumpThreshold` in
   10th-hour units, default 1440 = 144 hours = 6 days), flag as SplitSD.
4. If PP JSON data is unavailable, fall back to date-gap alone (less reliable —
   emit a warning anomaly but still flag SplitSD).

**Threshold rationale**: A 2-month gap is chosen because tip files cover one month,
so a gap of > 2 months between two datasets that purport to be the same device cannot
be a simple tip-file boundary — it means the card was absent or swapped. The
BlowerHours guard prevents false positives where a device was legitimately offline
(hospitalization, power failure) for > 2 months.

### `manifest.json` Schema:
```json
{
  "version": 1,
  "created": "2025-12-01T18:30:00Z",
  "goldenSequence": 1,
  "previousGolden": null,
  "backupRoot": "D:\\...\\VentDataBackup_2023-2026",
  "forcedDevicesReason": null,
  "devices": {
    "TVXX0000001": {
      "model": "CA1032800",
      "productType": "0x32",
      "firmware": "14.2.05",
      "trilogyDateRange": { "earliest": "2023-03", "latest": "2025-12" },
      "pSeriesDateRange": { "earliest": "2023-06-05", "latest": "2025-12-02" },
      "_note": "pSeriesDateRange derived from PP JSON filenames (PP_YYYYMMDD_NNN.json) across all clean backups",
      "trilogyFileCount": 750,
      "pSeriesFileCount": 95,
      "sourceFolders": ["12.1.2025", "4.10.2024"],
      "splitSD": false,
      "splitSDSpans": null,
      "fileHashes": { "Trilogy/AD_202303_000.edf": "A1B2C3...", "..." : "..." }
    },
    "TVXX0000004": {
      "splitSD": true,
      "splitSDSpans": [
        { "earliest": "2024-01", "latest": "2024-08", "sourceFolders": ["4.10.2024/vent 2"] },
        { "earliest": "2025-01", "latest": "2025-08", "sourceFolders": ["Tril 077908-17-2025"] }
      ]
    }
  }
}
```

### `Test-GoldenIntegrity -GoldenPath <path>`
Fast hash-and-existence pass. Verifies every file listed in `manifest.json` is
present on disk with a matching MD5 hash, and that each EDF file's embedded SN
matches its device folder. Also checks AD/DD pair completeness within `Trilogy/`.

Returns `PSCustomObject @{ Passed; FileCount; Failures }`.

### `Test-GoldenContent -GoldenPath <path>`
Deep format and DirectView-compatibility validation. Scans every file in the golden
(not just manifest-referenced files). Called unconditionally after every
`New-GoldenArchive` / `Update-GoldenArchive` run, after `Test-GoldenIntegrity`.

**Returns**:
```powershell
[PSCustomObject]@{
    Passed        = $true   # $false if any Critical or Error issues found
    FileCount     = 0       # total files inspected
    CriticalCount = 0       # DirectView-blocking failures
    ErrorCount    = 0       # data-integrity failures
    WarningCount  = 0       # format anomalies (tolerable but should be reviewed)
    Issues        = @(      # flat array of all issues, any severity
        [PSCustomObject]@{
            Severity = 'Critical' | 'Error' | 'Warning'
            Category = 'DirectViewCompat' | 'EdfFormat' | 'EdfPairing' |
                       'PSeriesFormat' | 'ManifestSchema' | 'DirectoryStructure'
            Device   = 'TVXX0000001'   # device folder (SN), empty for manifest-level issues
            File     = 'Trilogy/AD_202303_000.edf'  # relative path within device folder
            Message  = 'HeaderBytes is 512, expected 256'
        }
    )
}
```

**Validation passes performed** (see ARCHITECTURE.md §3c for full rule table):
1. `manifest.json` schema: version=1, goldenSequence≥1, created ISO format,
   forcedDevicesReason null or non-empty, devices section present,
   on-disk device folders match manifest entries.
2. Per-device directory structure: device folder, `Trilogy/`, `P-Series/` exist.
3. DirectView compatibility gate: `P-Series/last.txt` present and matches SN,
   `P-Series/{SN}/prop.txt` present, at least one `AD_*.edf` in `Trilogy/`.
4. EDF header fields: size ≥ 256, Version="0", HeaderBytes=256, StartDate/Time
   format, NumDataRecords valid, NumSignals ≥ 1, RecordDuration non-negative,
   RecordingID SN matches device folder, filename YYYYMM consistent with StartDate.
5. AD/DD pair completeness (thorough: both directions).
6. BIN file filename-pattern parse; SN extracted from name matches device folder.
7. EL_ CSV: filename pattern; first 100 binary bytes contain device SN.
8. `P-Series/{SN}/prop.txt`: SN, MN, PT (0x... hex), SV fields present and valid.
9. `FILES.SEQ` / `TRANSMITFILE.SEQ` parseable; TRANSMITFILE.SEQ line count ≤ FILES.SEQ.
10. `SL_SAPPHIRE.json` first byte is `{` (lightweight JSON-object guard).
11. `PP_*.json` (all ring slots P0–P7): parseable, SN matches device folder,
    TimeStamp > 0, BlowerHours non-negative if present.

**Private helper used internally**: `_NewContentIssue -Severity -Category -Device -File -Message`
returns the issue PSCustomObject; not exported.

## VBM-Export.psm1

### `Export-ToTarget -GoldenPath <path> -Target <path> [-Devices <string[]>]`
Copies golden archive content to a target (SD card or folder).

- **Single device**: Copies `{SN}/Trilogy/*` → `{Target}/Trilogy/` and
  `{SN}/P-Series/{SN}/*` → `{Target}/P-Series/{SN}/` — mirrors native SD card
  layout. Also creates `{Target}/P-Series/last.txt` pointing to the device SN.
  DirectView expects: `{Target}/Trilogy/` + `{Target}/P-Series/last.txt` +
  `{Target}/P-Series/{SN}/prop.txt` + ring buffer data.
- **Multi device**: Creates `{Target}/{SN}/Trilogy/` and `{Target}/{SN}/P-Series/`
  per device (each with its own last.txt), plus a root `README.md` for the clinician.
  DirectView is pointed at each `{Target}/{SN}/` subfolder individually.

### `Show-TargetContents -Target <path>`
Lists top-level directory of target showing filename, last modified date, size.
Used before overwrite confirmation.

### `Write-ExportReadme -Target <path> -Devices <hashtable>`
Generates clinician-facing README.md explaining the multi-device layout and where to
point DirectView for each device subfolder.

## VBM-Backup.psm1

### `Import-SDCard -Source <path> -BackupRoot <path>`
1. Read `last.txt` from source to identify active device
2. Create folder `{BackupRoot}/backup_YYYY-MM-DD_{SN}`
3. Robocopy/Copy-Item with verification
4. `Test-CopyIntegrity` — hash every file in source vs destination
5. Return the new backup path for immediate TOC integration

## VBM-Dedup.psm1

### `Invoke-Compaction -BackupRoot <path> -SafetyPath <path>`
Full dedup pipeline:
1. **Dropbox check**: Detect if BackupRoot is inside a Dropbox-synced folder
   (look for `.dropbox` or `.dropbox.cache` in ancestor directories). If so,
   warn the user that Dropbox does not honor NTFS hardlinks — it will re-upload
   separate copies, defeating storage savings, and may cause sync corruption.
   Recommend using Compact only on a non-synced local copy.
2. `Invoke-SafetyBackup` → `Test-SafetyBackup`
3. Scan all files under BackupRoot, group by MD5 hash
4. For each group with > 1 file: keep one as the "master", replace others with
   hardlinks via `fsutil hardlink create`
5. `Test-PostDedupIntegrity` — verify every file is readable and hashes match
6. On failure: `Invoke-DedupRollback` from safety backup

### `Test-IsHardlinked -Path <path>`
Uses `fsutil hardlink list` to check link count > 1. Used as a guard before any
write operation across the entire toolset.

## VBM-UI.psm1

### Wizard Functions
- `Show-MainMenu` → returns choice (1-5)
- `Read-ValidatedPath -Prompt <string> [-MustExist]` → validated path string
- `Read-YesNo -Prompt <string> [-Default <bool>]` → boolean
- `Show-DeviceSelection -Devices <hashtable> -Suggested <string[]>` → selected SN array
- `Show-ForceDevicesPrompt -Devices <hashtable>` → `@{ ForceDevices=$true/$false; SelectedSNs=@(...); Reason="..." }`
- `Write-ProgressBar -Activity <string> -Current <int> -Total <int>`
- `Write-TimelineChart -DeviceTimeline <obj>` → ASCII bar chart to console
  **Note**: `Show-TOC` (in VBM-Analyzer) contains its own inline timeline renderer
  appropriate for the full TOC summary view. `Write-TimelineChart` is a general-purpose
  chart for single-device or caller-assembled timelines and is not called by `Show-TOC`.

### `Show-DeviceSelection` Behavior
Presents the device list with a pre-selected suggestion:
- First golden: all devices suggested
- Subsequent golden: only devices with changed data suggested
User can accept `[Enter]` or type device numbers to override.

### `Show-ForceDevicesPrompt` Behavior
Shown in the wizard immediately before the regular `Show-DeviceSelection` step,
only when building or updating a golden archive.

1. Asks: "Force specific devices into this golden run regardless of change detection?
   (This overrides the automatic algorithm.) [y/N]"
2. If **No** (default): returns `@{ ForceDevices=$false }` and the caller proceeds
   with normal `Show-DeviceSelection`.
3. If **Yes**:
   a. Shows the full device list with checkboxes (same format as `Show-DeviceSelection`)
      but with NO pre-selection (user must explicitly choose).
   b. Prompts: "Reason for forcing these devices (free text, recorded in manifest):"
   c. Prompts for confirmation: shows chosen SNs and reason, asks "Confirm? [Y/n]".
   d. Returns `@{ ForceDevices=$true; SelectedSNs=@(...); Reason="..." }`.
4. The caller passes `SelectedSNs` as `-ForceDevices` and `Reason` as `-ForceReason`
   to `New-GoldenArchive` / `Update-GoldenArchive`.

## VentBackupManager.ps1 (Entry Point)

```powershell
[CmdletBinding()]
param(
    [ValidateSet('Analyze','Backup','Golden','Export','Prepare','Compact')]
    [string]$Action,
    [string]$BackupRoot,

    # Backup (ingest)
    [string]$Source,

    # Golden archive
    [string]$GoldenRoot,
    [string[]]$Devices,

    # Forced device override (bypasses changed-data detection)
    [string[]]$ForceDevices,
    [string]$ForceReason,

    # Export / Prepare
    [string]$GoldenPath,
    [string]$Target,

    # Compact
    [string]$SafetyBackup
)
```

If `$Action` is provided → CLI mode, dispatch directly.
If no parameters → wizard mode via `Show-MainMenu` loop.

`-ForceDevices` and `-ForceReason` are forwarded to `New-GoldenArchive` or
`Update-GoldenArchive` when the `Golden` or `Prepare` action is invoked from CLI.
In wizard mode, these come from `Show-ForceDevicesPrompt` instead.

### First-Run Setup (`_CheckDesktopShortcut`)

Runs once at wizard startup, before the main menu appears. Manages the Desktop
shortcut lifecycle without requiring any manual user steps.

**Logic**:
1. Load `scripts/settings.json` (if it exists); default to empty object.
2. If `settings.skipShortcutPrompt` is `$true` → return immediately (user opted out).
3. Check whether `{Desktop}\Ventilator Backup Manager.lnk` exists → return if so.
4. If neither condition is met, prompt the user once:
   - **Y** — call `Install-DesktopShortcut.ps1` and confirm success.
   - **N** — do nothing; prompt will appear again on next run.
   - **X** — set `settings.skipShortcutPrompt = $true`, persist to `settings.json`, never prompt again.

**State file** (`scripts/settings.json`):

```json
{
  "skipShortcutPrompt": true
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `skipShortcutPrompt` | bool | When `true`, the shortcut prompt is permanently suppressed for this installation. |

The file is created only when the user chooses **X**. It is a local machine preference
and is excluded from source control via `.gitignore`.

## Data Flow Summary

```
Analyze:    BackupRoot → Get-BackupInventory → Get-BackupTOC → Show-TOC
                                             → Test-BackupIntegrity → Write-ContaminationReadme
                                             → Detect-SplitSD (annotates TOC.Devices[*].SplitSD)

Prepare:    BackupRoot → Get-BackupTOC → Detect-SplitSD
(wizard)               → Show-ForceDevicesPrompt
                          → [force=N] Show-DeviceSelection (suggest changed-or-new devices)
                          → [force=Y] use ForceDevices SNs + ForceReason
                       → [if no golden] New-GoldenArchive(-ForceDevices, -ForceReason)
                       → [if golden exists] Update-GoldenArchive(-ForceDevices, -ForceReason)
                       → Show-TargetContents → confirm → Export-ToTarget

Backup:     Source → Import-SDCard (copy + hash-verify inline) → Get-BackupTOC → Show-TOC

Compact:    BackupRoot → warn → Read-ValidatedPath (safety location)
                       → Invoke-SafetyBackup → Test-SafetyBackup
                       → Invoke-Compaction → Test-PostDedupIntegrity
                       → [on failure] Invoke-DedupRollback
```

## Known Edge Cases & Regression Guards

This section catalogs real-world edge cases discovered during reverse-engineering.
Every item here caused (or would have caused) a bug. Implementers: treat these as
mandatory test cases.

### File Format Edge Cases
1. **EDF NumDataRecords = "-1"**: Valid per EDF+ spec. Means record count was unknown
   at write time (active tip file). Do NOT reject or parse as integer without handling.
2. **EDF file exactly 256 bytes**: Valid header but zero data records. Do not reject —
   this represents an empty recording session.
3. **EL_ CSV files are binary**: Despite the `.csv` extension, these use null-byte
   separators. `Get-Content` will silently corrupt them. Always use
   `[System.IO.File]::ReadAllBytes()` for any read beyond filename parsing.
4. **BIN ProductType is bare hex digits**: Filename uses `32_TV...` (not `0x32`).
   To match against prop.txt PT (`0x32`): strip the `0x` prefix before comparing,
   or parse both as integers.
5. **PP JSON may have N+1 files per ring slot**: The last PP file in a slot is the
   "start marker" for the next day. Don't assume exactly 1 PP + 1 PD + 1 PA per slot.
6. **SL_SAPPHIRE.json >1MB**: Don't load with `Get-Content | ConvertFrom-Json` in
   a pipeline that buffers the whole string. Use `-Raw` and be aware of memory usage.
7. **prop.txt VC key is optional**: Present only on newer CA1032800B devices.
   Parser must handle missing keys gracefully (hashtable, not fixed property set).
8. **Trilogy folder may contain ZERO WD files**: Waveform recording can be disabled.
   Don't assume WD files always exist alongside AD/DD.

### Contamination & Multi-Device Edge Cases
9. **Same filename, different device**: AD_202408_000.edf exists in multiple backups
   with different device SNs. The filename is NOT a unique identifier across devices.
   Always pair filename with device SN for identity.
10. **Majority-inversion in contaminated backups**: In 12.1.2025.002, TVXX0000004
    overwrote 95 files, potentially outnumbering TVXX0000001's remaining files.
    Majority-SN voting would identify TVXX0000004 as "expected" — which is wrong.
    Always use P-Series/{SN}/ directory listing as the authoritative device roster.
11. **Multi-device SD card is legitimate**: 4.10.2024 has TVXX0000002 + TVXX0000001.
    Both are expected — old devices leave historical data on the card. Don't flag
    multi-device as contamination; flag only devices not in the P-Series roster.
12. **Nested backup inside backup**: `4.10.2024/vent 2/` is a separate backup
    (different SD card) nested inside another. Inventory must discover these
    recursively but treat them as independent backups with their own device set.
13. **Contamination only affects Trilogy/**: P-Series is immune because devices get
    per-SN subdirectories. Contamination of P-Series would require manual file
    manipulation, not a simple SD card copy.

### Golden Archive Edge Cases
14. **Tip file larger in older backup**: If the same AD file is 500KB in backup A
    (Oct 2024) and 200KB in backup B (Dec 2025), the older backup's version is more
    complete — the newer backup's copy was from a different device (contamination) or
    a mid-write copy. "Largest wins" is correct ONLY after confirming both copies
    belong to the same device.
15. **Ring buffer slot collision across backups**: Two backups may have different
    data in P5/ (recorded on different days). Both are valuable historical data.
    Golden should collect ALL unique ring buffer files, keyed by (slot + filename).
    Where the same ring-slot filename appears in multiple backups, keep the **largest**
    copy (same "largest wins" rule as Trilogy files — a smaller version may be a
    mid-write tip). This is consistent with edge case 14.
16. **FILES.SEQ paths may reference overwritten ring buffer slots**: FILES.SEQ is
    cumulative and lists files that no longer exist on the SD card. Do not fail
    validation if some FILES.SEQ entries don't resolve to actual files.
17. **Golden inside BackupRoot**: If the user creates `_golden_2025-12-01/` inside
    the backup root, `Get-BackupInventory` must exclude it. Same for `scripts/`.

### Platform & Environment Edge Cases
18. **Paths with multiple consecutive spaces**: `trilogy   5.9.2022` has 3 spaces.
    PowerShell handles this but shell quoting can break. Always quote all paths.
19. **Dropbox Smart Sync**: Files may be "online only" and not available locally.
    File reads will fail with access errors. `Read-EdfHeader` and other parsers
    silently return `$null` for inaccessible files (try/catch), causing them to be
    silently omitted from the TOC. **Mitigation**: at the start of `Get-BackupTOC`,
    warn the user if BackupRoot is inside a Dropbox-synced folder (check for
    `.dropbox` or `.dropbox.cache` in ancestor directories) and advise making
    all files available offline before scanning.
20. **NTFS hardlinks don't cross volumes**: `fsutil hardlink create` fails if
    source and target are on different drives. Safety backup is likely on a
    different drive — hardlinks cannot span this.
21. **`fsutil` requires elevated privileges on some systems**: May need to detect
    and request elevation, or fall back to a copy-based approach.
22. **SD card is FAT32**: SD cards formatted as FAT32 don't support hardlinks,
    long filenames may truncate, and file timestamps may have 2-second granularity.
    Export operations should use Copy-Item, not hardlinks.
