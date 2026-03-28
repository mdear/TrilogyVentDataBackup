# Ventilator Backup Manager

A Windows tool for backing up, organizing, and verifying Philips Respironics
Trilogy 200 ventilator data from SD cards.

---

## What This Tool Does

- **Backs up** ventilator SD cards to your computer with a dated folder name
- **Analyzes** your existing backups and shows you what devices and date ranges
  each one contains
- **Detects contamination** — cases where data from one ventilator accidentally
  overwrote data from another
- **Creates golden archives** — one clean, verified copy of all data per device,
  ready to hand to a clinician or load into DirectView
- **Prepares SD cards** for clinic visits with only the data the clinician needs
- **Gap Analysis** — shows a chronological swim lane per device so you can see at a
  glance which months of therapy data are missing across all your backups

---

## Requirements

- **Windows 10 or 11** (any edition — Home, Pro, etc.)
- **PowerShell 5.1** — already installed on every Windows 10/11 computer
- No additional software or downloads needed

> **Tip:** To check your PowerShell version, press `Win + R`, type `powershell`,
> press Enter, then type `$PSVersionTable.PSVersion` and press Enter. The first
> number should be **5** or higher.

---

## Installation

There is nothing to install. The tool runs directly from this folder.

### Step 1 — Verify the folder structure

Make sure these items are present in this folder:

```
📁 VentDataBackup_2023-2026
 ├── Launch-VentBackupManager.cmd    ← double-click this to start
 ├── 📁 scripts
 │    ├── 📁 modules                 ← PowerShell code lives here
 │    ├── Install-DesktopShortcut.ps1
 │    └── ...
 ├── 📁 12.1.2025                    ← your existing backups
 ├── 📁 12.1.2025.002
 └── ...
```

### Step 2 — Run the tool

**Double-click** `Launch-VentBackupManager.cmd`.

A command window will open and the wizard will walk you through each step
with numbered menus. Follow the on-screen prompts — no typing commands required.

> **If Windows shows a "Windows protected your PC" warning:**
>
> 1. Click **"More info"**
> 2. Click **"Run anyway"**
>
> This happens because the file was downloaded from the internet (via Dropbox).
> It is safe — the script only reads and copies ventilator data files.

### Step 3 — Desktop shortcut (automatic)

The first time you run the tool it will ask if you want a Desktop shortcut.
Press **Y** and it creates one. That's it — you never need to open this folder again.

> If you accidentally said "never ask again" and want the shortcut later,
> delete `scripts\settings.json` and run the tool once more.

---

## How to Back Up an SD Card

1. Remove the SD card from the ventilator and insert it into your computer
   (use a USB card reader if your computer doesn't have a built-in SD slot)
2. Double-click `Launch-VentBackupManager.cmd` (or the desktop shortcut)
3. Choose **"Back Up an SD Card"** from the menu
4. The wizard will ask you to select the SD card drive letter
5. The backup is saved into a new dated folder inside this directory

> **Important:** Do not rename or move the backup folders. The tool uses them
> to track your backup history.

---

## How to Prepare Data for a Clinician

1. Launch the tool
2. Choose **"Prepare SD Card for Clinician"**
3. Choose **Recommended** devices (pre-selected by the tool) or **Custom** to
   pick specific devices and add an audit note
4. Optionally enter a **date range** to restrict the data (custom path only)
5. The tool copies a clean, verified set of files to a location you choose
   (e.g., a blank SD card or USB drive)

The output is compatible with Philips **DirectView** software.

---

## Device Selection for Golden Archives (Wizard)

When building or updating a golden archive via the wizard, you are presented
with two options:

```
  R)  Accept recommended selection and proceed
  C)  Custom selection  —  choose specific devices and add a note
```

**R — Recommended** accepts the pre-computed device set automatically:
- First golden: all known devices are included.
- Update golden: only devices with new or changed data since the last golden.

**C — Custom** lets you manually choose specific devices. You must supply a
brief **audit note** explaining the reason (it is recorded in the archive
manifest). You can also optionally apply an inclusive **date range filter** on
the custom path.

The wizard CLI path (`-Action Golden` / `-Action Prepare`) bypasses this menu
and accepts `-ForceDevices`, `-ForceReason`, `-FromDate`, and `-ToDate` directly.

---

## TOC Cache

The **Analyze** function builds a Table of Contents (TOC) by scanning every
backup folder and running integrity checks. On large backup roots this takes
tens of seconds.

To avoid repeating this work unnecessarily, a fingerprint of the backup folder
contents (file paths, sizes, and timestamps) is stored in:

```
{BackupRoot}\.toc-cache\toc.fingerprint
{BackupRoot}\.toc-cache\toc.clixml
```

On each subsequent **non-interactive** TOC call (e.g. during Prepare), the
fingerprint is recomputed and compared. If nothing has changed, the cached TOC
is loaded from disk in milliseconds instead of being rebuilt.

The cache is **automatically invalidated** when:
- Any file inside a regular backup folder is added, removed, or modified.
- The tool forces a rebuild (the Analyze wizard choice always rebuilds).

Changes inside `_golden_*` archive folders do **not** invalidate the cache —
golden archives are derived from regular backups and do not affect the scan.

---

## Golden Archives in TOC Analysis

The **Analyze** view now includes a **GOLDEN ARCHIVES** section below the
regular backups table. For each `_golden_*` folder it shows:

- Sequence number and creation date (from `manifest.json`)
- Active date filter, if one was applied at build time
- Per-device serial number with data date range and file count

This makes it easy to see at a glance exactly which data is captured in each
golden archive without opening any files.

---

## Date Range Filter for Golden Archives

When building a golden archive (via **Prepare** or **Golden Archive** in the wizard,
or via the `-Action Golden` / `-Action Prepare` CLI flags), you can optionally restrict
which data is included using an **inclusive date range**.

- **What it filters**: EDF therapy-data files (AD_/DD_/WD_) and P-Series per-session
  (PP) files whose month falls outside the specified range are excluded from all
  selected devices.  Device identity files (prop.txt, FILES.SEQ, SL_SAPPHIRE.json,
  etc.) are always included regardless of the date range.
- **Self-consistency guaranteed**: After filtering, the standard pairing and rewind
  rules still run, so the resulting golden archive is always internally consistent
  and passes integrity and content validation.
- **Manifest recorded**: The `dateFilter` field in `manifest.json` records the
  `from`/`to` bounds for audit purposes.

### Wizard

After selecting devices, you will be asked:

```
  From date (inclusive) [blank = no lower bound]: 2024-03-01
  To date   (inclusive) [blank = no upper bound]: 2025-06-30
```

Leave **both** blank to include all available data (the default behaviour).

### CLI

Use `-FromDate` and `-ToDate` (both in `YYYY-MM-DD` format):

```powershell
# Golden only — restrict to data from March 2024 through June 2025
.\VentBackupManager.ps1 -Action Golden -FromDate '2024-03-01' -ToDate '2025-06-30'

# Prepare (golden + export) — lower bound only
.\VentBackupManager.ps1 -Action Prepare -Target D:\ -FromDate '2024-06-01'

# No date filter (default) — include everything
.\VentBackupManager.ps1 -Action Golden
```

Both flags are optional and independent — you can supply either, both, or neither.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "PowerShell is not available" | Your Windows installation is damaged. Run Windows Update. |
| "scripts\VentBackupManager.ps1 not found" | The `scripts` folder is missing. Re-download or re-sync from Dropbox. |
| SmartScreen "protected your PC" warning | Click "More info" → "Run anyway". |
| Nothing happens when double-clicking | Right-click the `.cmd` file → "Run as administrator". |
| SD card not detected | Try a different USB port or card reader. Check that the card appears in File Explorer. |

---

## Folder Reference

| Folder | Purpose |
|--------|---------|
| `scripts/` | All tool code — do not modify |
| `scripts/modules/` | PowerShell modules (parsers, analyzers, etc.) |
| `scripts/assets/` | Generated icon file |
| `.github/docs/ARCHITECTURE.md` | Technical reference — what the tool does and why |
| `.github/docs/DESIGN.md` | Technical reference — how the tool is built |
| `_golden_*/` | Clean per-device archives (created by the tool) |
| Everything else | Your ventilator backup folders |

---

## Safety

- The tool **never deletes** your original backup folders
- Before any compaction or deduplication, it creates a safety copy first
- All operations can be cancelled at any step in the wizard
- Your data stays on your computer — nothing is uploaded anywhere
