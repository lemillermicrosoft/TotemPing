# Scaffold Strategies

This skill must work even when no existing addon directory is available.

## Strategy A: Zero-dependency scaffold (default)
Use this when no source project exists.

Creates:
- <AddonName>/
- <AddonName>/PLAN.md
- <AddonName>/.claude/skills/ (empty if no source skills found)
- <AddonName>/.agent/skills link to .claude/skills
- WoW AddOns link from game folder to <AddonName> repo folder

PowerShell:
```powershell
$target = "C:\Users\<user>\repos\<AddonName>"
$wowAddons = "C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns"
$addonName = Split-Path -Path $target -Leaf

New-Item -ItemType Directory -Path $target -Force | Out-Null
Set-Content -Path (Join-Path $target "PLAN.md") -Value "# <AddonName> Plan" -Encoding UTF8

$destSkills = Join-Path $target ".claude\skills"
New-Item -ItemType Directory -Path $destSkills -Force | Out-Null

$agentDir = Join-Path $target ".agent"
$agentSkills = Join-Path $agentDir "skills"
New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
if (Test-Path $agentSkills) { Remove-Item -Path $agentSkills -Recurse -Force }
try {
  New-Item -ItemType SymbolicLink -Path $agentSkills -Target $destSkills -ErrorAction Stop | Out-Null
} catch {
  New-Item -ItemType Junction -Path $agentSkills -Target $destSkills | Out-Null
}

$wowLink = Join-Path $wowAddons $addonName
if (Test-Path $wowAddons) {
  if (Test-Path $wowLink) { Remove-Item -Path $wowLink -Recurse -Force }
  try {
    New-Item -ItemType SymbolicLink -Path $wowLink -Target $target -ErrorAction Stop | Out-Null
  } catch {
    New-Item -ItemType Junction -Path $wowLink -Target $target | Out-Null
  }
}

Get-ChildItem -Path $target -Force | Select-Object Name, Mode
```

## Strategy B: Copy skills from known or workspace source
Use this when source skills are available.

PowerShell:
```powershell
$target = "C:\Users\<user>\repos\<AddonName>"
$sourceSkills = "C:\Users\<user>\repos\<SourceAddon>\\.claude\\skills"   # optional
$workspaceSkills = "C:\Users\<user>\repos\<CurrentWorkspace>\\.claude\\skills"

$destSkills = Join-Path $target ".claude\skills"
New-Item -ItemType Directory -Path $destSkills -Force | Out-Null

$effectiveSkillsSource = $null
if (Test-Path $sourceSkills) {
  $effectiveSkillsSource = $sourceSkills
} elseif (Test-Path $workspaceSkills) {
  $effectiveSkillsSource = $workspaceSkills
}

if ($effectiveSkillsSource) {
  Copy-Item -Path (Join-Path $effectiveSkillsSource "*") -Destination $destSkills -Recurse -Force
}
```

## Strategy Selection Rule
- Default to Strategy A.
- Use Strategy B whenever a source path or workspace source exists.
- Never block project creation on missing source directories.
- Always create .agent/skills and WoW AddOns links as part of bootstrap.
