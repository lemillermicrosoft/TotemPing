# Symlink Patterns

Use these link patterns for Windows-based WoW addon projects.

## 1) Internal skills link

Goal:
- Keep .agent/skills aligned to .claude/skills in the new addon repo.

Preferred command (PowerShell):
```powershell
$agentDir = Join-Path $target ".agent"
$agentSkills = Join-Path $agentDir "skills"
$claudeSkills = Join-Path $target ".claude\skills"

New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
if (Test-Path $agentSkills) { Remove-Item -Path $agentSkills -Recurse -Force }

try {
  New-Item -ItemType SymbolicLink -Path $agentSkills -Target $claudeSkills -ErrorAction Stop | Out-Null
} catch {
  # Fallback when symlink privileges are unavailable.
  New-Item -ItemType Junction -Path $agentSkills -Target $claudeSkills | Out-Null
}
```

## 2) WoW AddOns deployment link

Goal:
- Link the addon repo directly into the WoW AddOns folder for live testing.

Preferred command (PowerShell):
```powershell
$addonName = Split-Path -Path $target -Leaf
$wowAddons = "C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns"
$wowLink = Join-Path $wowAddons $addonName

if (-not (Test-Path $wowAddons)) {
  throw "WoW AddOns path not found: $wowAddons"
}
if (Test-Path $wowLink) { Remove-Item -Path $wowLink -Recurse -Force }

try {
  New-Item -ItemType SymbolicLink -Path $wowLink -Target $target -ErrorAction Stop | Out-Null
} catch {
  # Fallback when symlink privileges are unavailable.
  New-Item -ItemType Junction -Path $wowLink -Target $target | Out-Null
}
```

## Validation

```powershell
Get-Item $agentSkills | Format-List FullName,LinkType,Target,Attributes
Get-Item $wowLink | Format-List FullName,LinkType,Target,Attributes
```

## Notes

- SymbolicLink may require Developer Mode or elevated permissions.
- Junction fallback works for directory links in most local setups.
- Remove an existing real directory only when it is safe and expected.
