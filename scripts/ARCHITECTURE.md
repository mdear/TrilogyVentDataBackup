# VentBackupManager — Architecture

## Table of Contents

- [Background](#background)
- [Problem Statement](#problem-statement)
- [Goals](#goals)
- [Device Inventory](#device-inventory)
- [SD Card Data Format Reference](#sd-card-data-format-reference)
  - [/Trilogy/ — Main Telemetry](#trilogy--main-telemetry-flat-directory-no-subdirectories)
  - [/P-Series/ — Periodic Session Data](#p-series--periodic-session-data)
  - [EDF+ Header Structure](#edf-header-structure-256-bytes-ascii)
  - [PP_*.json Fields](#ppjson-fields-periodic-properties)
  - [Telemetry Growth Model](#telemetry-growth-model)
- [Backup Inventory and Contamination Map](#backup-inventory-and-contamination-map)
  - [".002" Suffix Convention](#002-suffix-convention)
  - ["vent 2" Provenance](#vent-2-provenance)
  - [Contamination Mechanism (12.1.2025.002)](#contamination-mechanism-1212025002)
  - [Cross-Backup Analysis Statistics](#cross-backup-analysis-statistics)
- [Features](#features)
  - [1. Analyze (Table of Contents)](#1-analyze-table-of-contents)
  - [2. Prepare SD Card for Clinician](#2-prepare-sd-card-for-clinician)
  - [3. Golden Archive](#3-golden-archive)
  - [4. Back Up an SD Card (Ingest)](#4-back-up-an-sd-card-ingest)
  - [5. Compact (Deduplicate)](#5-compact-deduplicate)
  - [6. Validate Backup(s)](#6-validate-backups)
- [Data Corruption Handling](#data-corruption-handling)
  - [Correctable](#correctable-using-data-from-other-backups)
  - [Flaggable Only](#flaggable-only-no-automated-fix-possible)
- [User Interface](#user-interface)
  - [Wizard Mode](#wizard-mode-default-for-non-technical-users)
  - [CLI Mode](#cli-mode-for-power-users-and-automation)

---

## Background

A family in Ontario, Canada relies on Philips Respironics Trilogy 200 ventilators
for life-critical respiratory support. These devices are loaned from the Ontario
Ventilation Equipment Pool and are periodically swapped out for service or
refurbishment. Each ventilator records telemetry, alarm history, prescription changes,
and waveform data to an SD card.

Over several years, a family member has been manually copying SD card contents into
backup folders on a local machine synced to Dropbox. These backups were taken at
irregular intervals with inconsistent naming, and some copies inadvertently merged
data from multiple SD cards — contaminating the archive.

## Problem Statement

1. **Inconsistent backup naming**: Folder names vary wildly (e.g. "trilogy 1.31.2022",
   "12.1.2025.002", "Tril 077908-17-2025") with no standard convention
2. **Cross-contamination**: The ventilator's Trilogy data folder is flat — all devices
   write files with the same naming pattern (AD_YYYYMM_NNN.edf). When two SD cards
   are copied into the same folder, files from one device silently overwrite files from
   another
3. **No visibility**: There is no structured way to see which devices or date ranges
   each backup covers, or where gaps exist
4. **No validation**: Filenames don't indicate which device produced them. Only the
   binary EDF header contains the true device serial number
5. **Clinician handoff**: When returning a device or sharing data with a clinician,
   there is no way to produce a clean, verified export that Philips DirectView software
   can read

## Goals

- Provide a clear "table of contents" across all backup data — what devices,
  what date ranges, what's clean, what's contaminated
- Detect and document cross-contamination automatically
- Build verified "golden" archives that separate data cleanly by device
- Enable producing DirectView-compatible exports for clinicians
- Allow safe deduplication to reduce storage footprint
- Be usable by a non-technical family member (wizard-style prompts) while also
  supporting power-user CLI invocation

## Device Inventory

The family has used four Trilogy 200 units over the 2021–2025 period:

| Serial Number  | Model        | Product Type | Status              | Data Span           |
|----------------|-------------|--------------|---------------------|---------------------|
| TVXX0000002    | CA1032800   | 0x32         | Retired ~Mar 2023   | Jul 2021 – Mar 2023 |
| TVXX0000001    | CA1032800   | 0x32         | Active              | Mar 2023 – Dec 2025 |
| TVXX000000D    | CA1032800B  | 0x65         | Active              | May 2024 – Dec 2025 |
| TVXX0000004    | CA1032800B  | 0x65         | Active ("vent 2")   | Jan 2024 – Aug 2025 |

Devices are swapped regularly. The device roster at any point in time may differ
from the roster at another point. The tool must not assume a fixed set of devices.

## SD Card Data Format Reference

The Trilogy 200 writes two top-level directories to its SD card:

### /Trilogy/ — Main Telemetry (flat directory, no subdirectories)

| File Pattern | Format | Granularity | Content |
|---|---|---|---|
| AD_YYYYMM_NNN.edf | EDF+ (binary, 256-byte header) | Monthly | Alarm detail — 1-second records, 1 signal |
| DD_YYYYMM_NNN.edf | EDF+ | Monthly | Detail data — 300-second records, 10 signals |
| WD_YYYYMMDD_NNN.edf | EDF+ | Daily | Waveform detail — 60-second records, 7 signals |
| EL_{SN}_{YYYYMMDD}.csv | Binary CSV (null-byte separators) | Per-event | Event log: alarms, mode changes, prescriptions |
| {PT}_{SN}_{Type}_{UnixTS}.bin | Opaque binary | Snapshot | Data dump (Type 17) or config dump (Type 18). PT = hex digits without "0x" prefix (e.g. "32" not "0x32") |

**AD/DD files come in matching pairs** with the same YYYYMM_NNN suffix. Both files
cover the same month and sequence number. One known anomaly: AD_202507_014 exists
with no matching DD file.

**NNN is a sequence counter** within each month (or day for WD). When a new therapy
session starts within the same period, NNN increments. Multiple files per month/day
is normal.

**The flat namespace is the root cause of cross-contamination**: All devices write
AD_202408_000.edf, DD_202408_000.edf, etc. with the same filename patterns. The
device identity is embedded inside the EDF header, not in the filename.

### /P-Series/ — Periodic Session Data

```
/P-Series/
  last.txt                    → Active device serial number (single line, e.g. "TVXX0000001")
  {SerialNumber}/             → One folder per device that has used this SD card
    prop.txt                  → Device identity: CF, SN, MN, PT (hex), SV, DF, VC (VC optional — newer devices only)
    FILES.SEQ                 → Growing index of all P-Series files (one path per line, CRC-32 hash as last line)
    TRANSMITFILE.SEQ          → Subset of FILES.SEQ: transmission queue (fewer entries, different CRC)
    SL_SAPPHIRE.json          → Large JSON: header + base64 "Periodic_Annot" field with encoded
                                 EDF annotations (prescriptions, alarms, mode changes). Grows monotonically. ~1MB+
    P0/ through P7/           → 8-slot circular ring buffer
      PP_YYYYMMDD_NNN.json    → Periodic Properties: device snapshot (BlowerHours, battery health,
                                 SD card status, firmware, timestamps). N+1 PP files per slot
                                 (last PP is "start" marker for next day's slot)
      PD_YYYYMMDD_NNN.edf    → Periodic Detail (EDF+)
      PA_YYYYMMDD_NNN.edf    → Periodic Alarm (EDF+)
```

**Ring buffer behavior**: Slots P0→P1→...→P7→P0 cycle. Each slot holds ~1 day of
sessions. When P7 is full, P0 is overwritten. Only the most recent 8 days of session
data survive on the SD card at any time. Historical ring buffer data is only preserved
if a backup captured it.

**FILES.SEQ vs TRANSMITFILE.SEQ**: FILES.SEQ contains all recorded P-Series file paths.
TRANSMITFILE.SEQ contains a subset (files pending wireless transmission). Both end with
a CRC-32 hash on the final line. In the oldest backup, FILES.SEQ has 86 lines vs
TRANSMITFILE.SEQ's 77 lines.

### EDF+ Header Structure (256 bytes, ASCII)

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 8 | Version (always "0") |
| 8 | 80 | Patient ID |
| 88 | 80 | Recording ID — **contains device identity** |
| 168 | 8 | Start Date (dd.mm.yy) |
| 176 | 8 | Start Time (hh.mm.ss) |
| 184 | 8 | Header byte count |
| 192 | 44 | Reserved (contains "EDF+D" for discontinuous) |
| 236 | 8 | Number of data records |
| 244 | 8 | Record duration (seconds) |
| 252 | 4 | Number of signals |

**Recording ID format**: `Startdate DD-MMM-YYYY X X TGY200 0 {SN} {MN} {DevClass} {FW_version}`

Example: `Startdate 04-OCT-2024 X X TGY200 0 TVXX0000004 CA1032800B 0x8408 14.2.05`

**WARNING**: The `{DevClass}` field (0x8408) is a **constant** across all four known
devices regardless of model or Product Type. It is NOT the same as the PT field from
prop.txt. Do not use it for device identification. The SN field is the authoritative
source of device identity for any EDF file.

### PP_*.json Fields (Periodic Properties)

Key fields: TimeStamp (Unix epoch), SN, MN, RASP_ID, Software_V, Boot_V, DSP_V,
CalibrationDate, INTBattery_SN/CycleCount/Health/ManuDate, BlowerHours (cumulative,
in 1/10th-hour increments ≈ 6-minute units), SDCard_Status/SN/Cap/RemCap/ManuDate,
LocaleOffset, DETBattery_SN/CycleCount/Health/ManuDate, CRC.

### Telemetry Growth Model

**Active "tip" files** are the current month's AD/DD and current day's WD files.
These grow as new data records are appended. All historical (sealed) files are static
and never change.

**Monotonically growing files**: FILES.SEQ, TRANSMITFILE.SEQ, and SL_SAPPHIRE.json
always grow. A backup showing a smaller version of these files than an older backup
indicates corruption (partial copy while file was being written).

**Size regression = contamination signal**: If a file in backup B is drastically smaller
than the same filename in older backup A, one of two things happened:
1. A different device's smaller file overwrote it (cross-contamination)
2. The file was copied mid-write (truncated tip)

## Backup Inventory and Contamination Map

| Folder                    | Backup Date   | Integrity     | Devices on Card                      |
|---------------------------|---------------|---------------|--------------------------------------|
| trilogy 1.31.2022         | Jan 31, 2022  | Clean         | TVXX0000002                          |
| trilogy   5.9.2022        | May 9, 2022   | Clean         | TVXX0000002                          |
| 4.10.2024                 | Oct 4, 2024   | Clean         | TVXX0000002, TVXX0000001             |
| 4.10.2024/vent 2          | Oct 4, 2024   | Clean         | TVXX0000004 (separate SD card)       |
| 12.1.2025                 | Dec 1, 2025   | Clean         | TVXX0000001, TVXX0000002, TVXX000000D|
| 12.1.2025.002             | Dec 1, 2025   | Contaminated  | All 4 (95 files overwritten)         |
| Tril 077908-17-2025       | Aug 17, 2025  | Clean         | TVXX0000004                          |

### ".002" Suffix Convention

`12.1.2025.002` is a second backup pass taken the same day as `12.1.2025`. This
appears to have been a copy from a different SD card (the "vent 2" card containing
TVXX0000004 data) pasted into the same backup folder. Because Trilogy filenames are
device-agnostic, TVXX0000004's files overwrote TVXX0000001's files wherever they
shared the same name (AD_YYYYMM_NNN.edf collisions).

### "vent 2" Provenance

The `4.10.2024/vent 2/` subfolder is the only clean backup of the TVXX0000004 SD
card. The data there covers Jan 2024 – Aug 2024. `Tril 077908-17-2025` is a later
clean backup of the same TVXX0000004 card (data through Aug 2025). The naming
"077908" appears to be a partial serial number or reference ID.

### Contamination Mechanism (12.1.2025.002)

95 Trilogy EDF files in this folder have EDF headers showing TVXX0000004 as the
device serial — but the backup was supposed to contain TVXX0000001 data (matching
the clean `12.1.2025` backup). What happened:

1. `12.1.2025` was copied from the primary SD card (TVXX0000001 + historical devices)
2. A second copy was made from TVXX0000004's SD card into the same folder structure
3. TVXX0000004's AD/DD/WD files for overlapping months silently overwrote
   TVXX0000001's files (same filenames, different device data)
4. P-Series was unaffected for existing devices (separate subfolders per SN)
   but TVXX0000004's P-Series folder was added

**Detection algorithm**: Determine the "majority" device per Trilogy folder by
counting EDF headers. Files whose embedded SN differs from the majority SN are
flagged as contamination. For multi-device SD cards (which legitimately have
multiple devices from historical usage), the expected device set comes from the
P-Series/last.txt and prop.txt cross-reference.

### Cross-Backup Analysis Statistics

- **205 content mismatches** across backup Trilogy folders (same filename, different hash)
- **12 P-Series steering file mismatches** (FILES.SEQ, TRANSMITFILE.SEQ, SL_SAPPHIRE.json — expected growth)
- **920 exact duplicates** (hash-identical files across backups)
- **Pattern**: Many files are smaller in newer backups vs older — indicates tip file
  replacement or partial copies during active recording

## Features

### 1. Analyze (Table of Contents)

Scan a backup root directory and produce a structured report showing:
- Per-backup: which devices are present, date ranges per device, file counts, integrity
- Per-device timeline: which backups contain data, coverage span, gaps
- Contamination alerts: files whose embedded device serial doesn't match context
- Anomaly flags: missing file pairs, truncated files, size regressions vs older backups
- Where the most recent backup fits in the overall data picture

### 2. Prepare SD Card for Clinician

The primary user-facing action. Internally this:
- Builds or updates a "golden archive" containing verified, per-device data
- Suggests which device(s) to include on the export media: if no prior golden exists,
  suggests all devices; otherwise suggests only devices whose data has changed since
  the last golden. The user can accept the suggestion or override it.
- Writes the export to the target SD card or folder

For single-device exports, the output mirrors the native SD card layout so DirectView
can read it directly. For multi-device exports, each device gets a subdirectory with
a README explaining where to point DirectView.

If the target already has content, the user sees a directory listing (names, dates,
sizes) and must confirm before overwriting.

### 3. Golden Archive

The golden archive is the verified "source of truth" built from all clean backups.
A golden must be **internally self-consistent**: every Trilogy file type that depends
on pairing (AD/DD) or on a month having a complete pair (WD, EL_, PP JSON ring data)
must have its counterpart present. Building a golden may require *rewinding* the
collected file set to the latest self-consistent state — dropping or replacing files
that would violate consistency, and logging every such action in the per-device
`rewindLog` field in `manifest.json`.

**Contaminated backup salvage**: Devices whose data exists exclusively in a
contaminated backup are not silently omitted. The golden builder performs a second
gather pass over contaminated backups and rescues:
- Trilogy EDF files whose embedded header SN unambiguously identifies the target device
- P-Series files via their `P-Series/{SN}/` path (equally unambiguous)
Salvage events appear in the `rewindLog`. The salvaged files are then subject to the
same rewind consistency rules as data from clean backups.

**First golden**: Collects all clean, verified data across all devices from all backups.
When the same filename exists in multiple backups, the largest version wins (most
complete "tip" file). Every file's embedded serial number is verified against its
claimed device.

**Subsequent goldens**: Only includes devices whose data has changed since the last
golden. Each included device still gets its complete dataset (not just deltas) to
remain independently DirectView-readable. Devices with unchanged data are excluded —
the roster reflects data changes, not the current physical device roster.

#### 3a. Forced Device List (Override)

Normally the golden algorithm automatically selects devices: all devices for the
first golden, only changed devices for subsequent goldens. In some situations a
specific list of devices must be forced into the golden regardless of the algorithm's
suggestion — for example:

- A new SD card was used in a ventilator that already has prior data; the new card's
  data must be merged and all affected devices re-consolidated.
- Clinical requirements demand that a specific device's data be re-exported even if
  unchanged (e.g. for audit purposes or after a firmware update).
- The first card was returned early and a second card was inserted before a full golden
  was taken: the operator knows which devices are affected.

When a forced device list is provided, the tool bypasses the automatic changed-vs-unchanged
heuristic and builds a complete golden for exactly the specified devices. All other
devices (not in the forced list) are excluded from this golden run. The reason for
the override is recorded in `manifest.json` under `forcedDevicesReason` so the chain
of custody is documented.

**Wizard**: An additional prompt appears before device selection — "Force specific
devices into this golden run? (Y/N)". If Yes, the user selects which devices to force
and provides a free-text reason. The reason and selected SNs are shown in a
confirmation summary before the golden is built.

**CLI**: `New-GoldenArchive` and `Update-GoldenArchive` each accept `-ForceDevices`
(string array of SNs) and `-ForceReason` (string). When `-ForceDevices` is supplied
the algorithm skips its normal changed-data detection and uses the supplied list.
At the `VentBackupManager.ps1` entry point the same parameters are exposed as
`-ForceDevices` and `-ForceReason` and are forwarded to both Golden and Prepare
actions.

#### 3b. Split-SD Card Detection and Merge

A ventilator may have used **two separate SD cards** at different points in time.
This produces two datasets for the same device serial number (SN) that are temporally
non-overlapping — i.e. the date ranges do not intersect. This is distinct from:

- Cross-contamination (same filename, different device)
- Normal tip-file growth (same filename, same device, different size)

**Detection algorithm** (run during `Get-BackupTOC` / `Test-BackupIntegrity`):

1. Group all backups by device SN.
2. For each device SN, collect all (backup folder, earliest date, latest date) tuples.
3. Identify pairs of backups for the same SN where:
   - Both backups are clean (not contaminated).
   - Their date ranges do NOT overlap (latest of the earlier set < earliest of the
     later set, with at least a 1-month gap to exclude tip-file boundary effects).
   - The two sets have **different P-Series BlowerHours trajectories** for the same
     device: each SD card starts its BlowerHours from where the device left off, so a
     continuity break (BlowerHours jumps forward significantly, or resets, between
     the two sets) confirms a card swap rather than a single continuous recording.
4. Flag any such SN as `SplitSD = $true` in the TOC device record.
5. The TOC will show two row-groups per affected SN: the earlier card's span and
   the later card's span, each labelled with the backup folder(s) it came from.

**Merge logic** (applied automatically during `New-GoldenArchive` and
`Update-GoldenArchive`):

When a device is flagged SplitSD, the golden builder collects Trilogy files from
ALL contributing backups (both card spans) and applies the standard largest-wins
deduplication. Because the date ranges are non-overlapping, the same filename
(e.g. AD_202408_000.edf) cannot legitimately appear in both spans — any collision
is a contamination signal and is flagged as an anomaly rather than silently resolved.
P-Series ring buffer files are merged across both spans as they would be for any
multi-backup device. The manifest's `sourceFolders` for that SN records all
contributing backups and a `splitSD` flag is set to `true`.

**Manifest annotation** (`manifest.json`):
```json
{
  "TVXX0000001": {
    "splitSD": true,
    "splitSDSpans": [
      { "earliest": "2023-03", "latest": "2024-07", "sourceFolders": ["4.10.2024"] },
      { "earliest": "2024-09", "latest": "2025-12", "sourceFolders": ["12.1.2025"] }
    ],
    "rewindLog": [
      { "Action": "SalvagedFromContaminated", "File": "Trilogy/AD_202408_099.edf",
        "Reason": "EDF header SN confirmed as TVXX0000001 in contaminated backup '12.1.2025.002'" },
      { "Action": "DroppedOrphan", "File": "Trilogy/AD_202407_000.edf",
        "Reason": "AD_202407_000.edf has no matching DD_202407_000.edf (partial SD flush)" }
    ]
  }
}
```

#### 3c. Golden Content Validation

Every golden archive built by `New-GoldenArchive` or `Update-GoldenArchive` must pass
a two-stage validation pass before being presented to the user as complete.

**Stage 1 — `Test-GoldenIntegrity` (hash/existence)**  
Verifies every file listed in `manifest.json` is present on disk with a matching MD5
hash, and that each EDF file's embedded serial number matches the device folder it
lives in. This is a fast, manifest-driven pass that confirms no files were lost or
corrupted during the copy operations that built the golden. AD/DD pair completeness
is intentionally **not** checked here — it is handled by `Test-GoldenContent`, which
reports AD/DD pairing problems as **Errors** (see `EdfPairing` category below).
Because the rewind step ensures every correctly-built golden is already self-consistent,
an EdfPairing finding is an archive-integrity problem, not merely a source-data gap.

**Stage 2 — `Test-GoldenContent` (deep format validation)**  
A thorough per-file format inspection that runs across every file in the golden — not
just those referenced by the manifest hash table — to ensure the archive will load
correctly in Philips DirectView and that every file conforms to its expected binary
or text format. This pass may surface issues that are not detectable from hashes
alone (e.g., a valid file whose EDF header fields are internally inconsistent, or a
PP JSON file missing a required `TimeStamp` field).

Issues are classified into three severity levels:

| Severity | Meaning | DirectView impact |
|----------|---------|-------------------|
| **Critical** | DirectView will not load this device's data | Export must be blocked or re-run |
| **Error** | Data integrity compromise (wrong SN, invalid required field, parse failure) | Data may be misleading or unreadable |
| **Warning** | Format anomaly that DirectView may tolerate, but indicates a potential problem | Should be reviewed before handing to clinician |

Issues are further categorised to aid diagnosis:

| Category | Covers |
|----------|--------|
| `DirectViewCompat` | Missing `Trilogy/` or `P-Series/` directories, missing `last.txt`, missing `prop.txt`, no AD_*.edf files |
| `EdfFormat` | EDF header field violations: version, header byte count, StartDate/StartTime format, NumDataRecords validity, NumSignals range, SN mismatch; also BIN filename pattern failures and EL_ CSV binary SN check |
| `EdfPairing` | AD_YYYYMM_NNN.edf without a matching DD_YYYYMM_NNN.edf (or vice versa). Severity is **Error** because the rewind step ensures every correctly-built golden is self-consistent; an EdfPairing finding means the rewind was bypassed or failed, which is an archive-integrity problem. |
| `PSeriesFormat` | prop.txt field validation (SN, MN, PT, SV presence and format), FILES.SEQ/TRANSMITFILE.SEQ parse and superset check, SL_SAPPHIRE.json JSON validity, PP JSON required-field and SN checks |
| `ManifestSchema` | manifest.json parse failure, missing required keys, invalid field values, device folder ↔ manifest entry mismatches |
| `DirectoryStructure` | Device folders present on disk but absent from manifest, or vice versa |

**EDF header field rules** enforced by `Test-GoldenContent`:

| Field | Rule | Severity if violated |
|-------|------|----------------------|
| File size | ≥ 256 bytes | Critical |
| Version | Exactly `"0"` | Error |
| HeaderBytes | Positive multiple of 256 — (1 + num_signals) × 256, e.g. 256 (0 signals), 512 (1 signal), 2816 (10 signals) | Error |
| StartDate | Matches `dd.mm.yy` | Warning |
| StartTime | Matches `hh.mm.ss` | Warning |
| NumDataRecords | `"-1"` or non-negative integer | Error |
| NumSignals | ≥ 1 | Error |
| RecordDuration | Non-negative integer | Warning |
| RecordingID SN | Matches device folder SN | Error |
| RecordingID format | Begins with `"Startdate "` | Warning |
| Filename YYYYMM vs StartDate mm/yy | Must agree (allowing tip-file boundary) | Warning |

**P-Series rules** enforced by `Test-GoldenContent`:

| File | Rules | Severity |
|------|-------|----------|
| `last.txt` | Present; content trims to device SN | Critical / Error |
| `prop.txt` | Present; SN field matches device folder; PT in `0x...` hex; MN and SV present | Critical / Error / Warning |
| `FILES.SEQ` | Parseable; at least one entry; TRANSMITFILE.SEQ line count ≤ FILES.SEQ count | Warning |
| `SL_SAPPHIRE.json` | First byte is `{` (valid JSON object start); full parse if ≤ 500 KB | Warning |
| `PP_*.json` | Parseable; `SN` and `TimeStamp` present; SN matches device; TimeStamp > 0; BlowerHours non-negative if present | Error / Warning |

**DirectView compatibility gate**: A golden is only considered DirectView-ready if every
included device has zero Critical issues. The operator is shown the full issue list
so they can make an informed decision before exporting; the tool does not block the
export silently.

**Integration**: `Test-GoldenContent` is called unconditionally at the end of every
`New-GoldenArchive` and `Update-GoldenArchive` run, immediately after
`Test-GoldenIntegrity`. Both results are printed to the console. The golden path is
still returned to the caller even if issues are found; the decision to proceed with
export is left to the operator.

### 4. Back Up an SD Card (Ingest)

Copy raw SD card contents into a consistently-named, timestamped backup folder.
Verify integrity of the copy. Immediately show the user where this new data fits
relative to existing backups.

### 5. Compact (Deduplicate)

Optional hardlink-based deduplication across backup folders to reduce storage.

This is a potentially destructive operation. Before proceeding, the tool:
- Warns the user explicitly about the risks
- Asks the user to designate a safety backup location (external drive, cloud-only
  Dropbox path, etc.)
- Creates a full independent copy at that location and verifies it
- Only then replaces duplicates with hardlinks
- Validates the result; rolls back from the safety copy if anything fails

If a hardlinked file is later improperly overwritten, all links to that content are
corrupted. The tool guards against this by detecting hardlinks before any write
operation and refusing to modify files with link count > 1 unless explicitly forced.

**Dropbox warning**: Dropbox does NOT properly support NTFS hardlinks. It may upload
separate copies (defeating storage savings) or corrupt files during sync. The tool
must warn the user if BackupRoot is inside a Dropbox-synced folder and recommend
using a non-synced safety backup location.

### 6. Validate Backup(s)

Scans all backup folders in the root (running `Analyze` first) and discovers all
`_golden_*` archive folders. Presents a unified numbered list so the user can
select any combination to validate. Golden archives are validated with
`Test-GoldenIntegrity` (SHA-256 manifest check) and `Test-GoldenContent`
(per-file format + DirectView compatibility). Regular backup folders are validated
with `Test-BackupIntegrity` (contamination, missing pairs, truncation, P-Series
consistency). Results and anomalies are displayed inline.

## Data Corruption Handling

### Correctable (using data from other backups)
- Cross-contamination where the original version exists in a clean backup
- Truncated "tip" files where a later backup has the complete version
- Missing AD/DD pairs where the other half exists elsewhere
- Incomplete P-Series ring buffer data reconstructable from FILES.SEQ

### Flaggable Only (no automated fix possible)
- Bit-rot or silent corruption with no matching clean version anywhere
- Date ranges that were never captured in any backup
- Truncated files where no larger version exists
- BIN file corruption (opaque binary, no header to validate)
- EL_ CSV internal record corruption (binary format, can verify header only)

## User Interface

### Wizard Mode (default, for non-technical users)
Numbered menu with clear descriptions. Guides the user step by step with
plain-language prompts, path validation, and confirmation before destructive actions.

The intended delivery for non-technical users is:
1. **`Launch-VentBackupManager.cmd`** — a double-clickable launcher in the backup
   root folder. Handles execution policy and calls `scripts/VentBackupManager.ps1`.
2. **Desktop shortcut** — `scripts/Install-DesktopShortcut.ps1` creates a desktop
   shortcut to the `.cmd` launcher with the custom icon. The user runs this once.
3. **`README.md`** — plain-language guide in the backup root explaining what the
   tool does and how to run it, written for a non-technical caregiver.

### CLI Mode (for power users and automation)
Parameter-driven invocation. Golden and Export are available as separate actions
for finer-grained control, plus a combined "Prepare" action matching the wizard flow.
