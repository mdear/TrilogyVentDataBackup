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
3. Select which device(s) to include
4. The tool copies a clean, verified set of files to a location you choose
   (e.g., a blank SD card or USB drive)

The output is compatible with Philips **DirectView** software.

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
