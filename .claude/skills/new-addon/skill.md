# New Addon Bootstrap Workflow

## Overview

Use this skill to spin up a brand-new WoW addon repository folder quickly and consistently.

This workflow is intentionally zero-dependency by default and does not require any pre-existing addon directory.

This workflow captures what worked for creating the DPSPulse addon while keeping prior-project reuse optional for source content only:

- define a clear product concept and pick a name
- create the addon root folder
- write a PLAN.md with implementation scope and milestones
- copy .claude/skills into the new addon
- link .agent/skills to .claude/skills in the new addon
- link the new addon folder into WoW AddOns for live testing
- verify the resulting structure before coding

## When to use this skill

Use this when the user asks to:

- create a new addon from scratch in a sibling repo folder
- generate a practical execution plan before implementation
- copy skills and create standard local symlink layout for agent tooling
- create a WoW AddOns directory link for development deployment

## Inputs to collect first

- Addon name (example: DPSPulse)
- Target path (example: C:\Users\leroy\repos\DPSPulse)
- Core feature intent (example: realtime rolling DPS graph)

Optional input:

- Source addon path to copy skills from (if omitted, prefer current workspace .claude/skills when available)

## Step-by-step workflow

1. Finalize a name
- Propose 5-10 names matching the addon concept.
- Recommend top 3 with rationale (clarity, memorability, discoverability).
- Confirm the selected name before creating files.
- Reference: `references/naming-playbook.md`

2. Create the addon folder
- Create the target directory with a non-destructive command.
- Keep path naming exact to the chosen addon name.

3. Create PLAN.md
- Add a concrete implementation plan with these sections:
  - Vision
  - Scope (MVP)
  - Technical Tasks
  - QA and validation
  - Post-MVP ideas
  - Deliverables
- Keep tasks action-oriented so they can be executed in order.
- Reference: `references/plan-template.md`

4. Copy .claude/skills into the new addon
- Preferred source order:
  - explicit source path provided by user
  - current workspace `.claude/skills` if present
- Destination: `<new-addon>/.claude/skills`
- If no source exists, create destination folder and continue.
- Reference: `references/scaffold-strategies.md`

5. Create .agent/skills link
- Ensure `<new-addon>/.agent/skills` points to `<new-addon>/.claude/skills`.
- Use SymbolicLink first and Junction fallback when needed.
- Reference: `references/symlink-patterns.md`

6. Create WoW AddOns deployment link
- Link `<new-addon>` to:
  - `C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\<AddonName>`
- Use SymbolicLink first and Junction fallback when needed.
- Reference: `references/symlink-patterns.md`

7. Verify the scaffold
- Confirm target root contains at least:
  - PLAN.md
- Verify `.claude/skills` exists and list copied folders.
- Verify `.agent/skills` link target.
- Verify WoW AddOns link target.

## Default behavior

- Default strategy: create addon directory, PLAN.md, and both symlink patterns.
- Skills source is flexible: explicit source, workspace source, or empty destination fallback.
- Never require another addon directory for this skill to succeed.

## Recommended PowerShell template

Use this as a safe bootstrap command pattern:

```powershell
$target = "C:\Users\leroy\repos\<NewAddonName>"
$workspaceSkills = "C:\Users\leroy\repos\<CurrentWorkspace>\\.claude\\skills"
$sourceSkills = "C:\Users\leroy\repos\<SourceAddon>\\.claude\\skills"  # optional
$wowAddons = "C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns"
$addonName = Split-Path -Path $target -Leaf

New-Item -ItemType Directory -Path $target -Force | Out-Null

$plan = @'
# <NewAddonName> Plan

## Vision
...
'@
Set-Content -Path (Join-Path $target 'PLAN.md') -Value $plan -Encoding UTF8

# Ensure .claude/skills exists, copy from source if available.
$destClaude = Join-Path $target '.claude'
$destSkills = Join-Path $destClaude 'skills'
New-Item -ItemType Directory -Path $destClaude -Force | Out-Null
New-Item -ItemType Directory -Path $destSkills -Force | Out-Null

$effectiveSkillsSource = $null
if ($sourceSkills -and (Test-Path $sourceSkills)) {
  $effectiveSkillsSource = $sourceSkills
} elseif (Test-Path $workspaceSkills) {
  $effectiveSkillsSource = $workspaceSkills
}

if ($effectiveSkillsSource) {
  Copy-Item -Path (Join-Path $effectiveSkillsSource '*') -Destination $destSkills -Recurse -Force
}

# Create .agent/skills -> .claude/skills
$agentDir = Join-Path $target '.agent'
$agentSkills = Join-Path $agentDir 'skills'
New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
if (Test-Path $agentSkills) { Remove-Item -Path $agentSkills -Recurse -Force }
try {
  New-Item -ItemType SymbolicLink -Path $agentSkills -Target $destSkills -ErrorAction Stop | Out-Null
} catch {
  New-Item -ItemType Junction -Path $agentSkills -Target $destSkills | Out-Null
}

# Create WoW AddOns deployment link
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

## Conversation-specific record (DPSPulse)

- Selected name: DPSPulse
- Created folder: C:\Users\leroy\repos\DPSPulse
- Created file: C:\Users\leroy\repos\DPSPulse\PLAN.md
- Copied skills from: C:\Users\leroy\repos\TalonTracker\.claude\skills
- Verified copied skill directories were present in destination

## Guardrails

- Never delete or reset unrelated existing repositories.
- Use non-destructive creation and copy operations.
- Verify source path exists before copy attempts.
- Prefer explicit post-step verification over assumptions.
- Do not treat missing source addon paths as errors for baseline scaffold creation.
- Prefer SymbolicLink with Junction fallback on Windows.
