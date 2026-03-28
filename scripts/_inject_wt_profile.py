"""
Injects a Windows Terminal profile for VentBackupManager into settings.json.
Called by Install-DesktopShortcut.ps1 with four positional arguments:
  1. path to settings.json
  2. profile GUID
  3. profile name
  4. path to VentBackupManager.ico
  5. path to Launch-VentBackupManager.cmd
  6. backup root directory
"""
import sys
import json
import shutil
import re

settings_path = sys.argv[1]
guid          = sys.argv[2]
name          = sys.argv[3]
ico           = sys.argv[4]
cmd           = sys.argv[5]
root          = sys.argv[6]

# Back up before touching
shutil.copy2(settings_path, settings_path + ".bak")

# Windows Terminal settings.json is JSONC (allows // comments).
# Strip line comments before parsing so json.loads succeeds.
with open(settings_path, encoding="utf-8-sig") as f:
    raw = f.read()

# Remove // ... line comments (but not URLs like https://)
stripped = re.sub(r'(?<![:/])//[^\n]*', '', raw)

data = json.loads(stripped)

profiles = data.setdefault("profiles", {})
lst = profiles.setdefault("list", [])

# Remove any stale entry with our guid
lst[:] = [p for p in lst if p.get("guid") != guid]

# Prepend our profile
lst.insert(0, {
    "guid": guid,
    "name": name,
    "commandline": f'cmd.exe /c "{cmd}"',
    "icon": ico,
    "startingDirectory": root,
    "hidden": False,
})

# Write back as standard JSON (WT accepts plain JSON fine)
with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4)

print(f"Profile '{name}' injected into {settings_path}")
