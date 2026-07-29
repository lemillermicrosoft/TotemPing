# WoW Addon Sync Workflow

## Overview

Use this skill when the user wants to copy the current repository addon files into the local World of Warcraft AddOns folder for testing.

Primary target:

- C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\TalonTracker

This workflow mirrors the repository into the game addon folder while excluding development-only files and skill content.

## When to use this skill

Use this skill when the user asks to:

- sync or deploy current addon changes for in-game testing
- update the local TalonTracker addon folder from this repo
- create repeatable test deployment commands

## Rules

- Never copy .claude or any skill files/folders.
- Never copy .git metadata.
- Keep destination folder name TalonTracker.
- Prefer robocopy for fast incremental sync on Windows.
- Run a dry-run first when possible.

## Default sync commands

From repository root:

```powershell
$Source = "C:\Users\leroy\repos\TalonTracker"
$Dest   = "C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\TalonTracker"

# 1) Preview changes only (dry-run)
robocopy $Source $Dest /MIR /L /NFL /NDL /NJH /NJS /NP `
  /XD ".git" ".claude" 

# 2) Apply sync
robocopy $Source $Dest /MIR /R:1 /W:1 /NFL /NDL /NP `
  /XD ".git" ".claude"
```

## Optional helper script

If asked to automate, create scripts/sync-addon.ps1 with these behaviors:

1. Accept -DryRun switch.
2. Validate source exists.
3. Create destination if missing.
4. Run robocopy with exclusions:
   - directories: .git, .claude
5. Exit non-zero if robocopy returns a failure code greater than 7.

## Suggested development workflow

1. Implement code changes in repo.
2. Run lint/tests if available.
3. Run dry-run sync.
4. Run real sync.
5. Reload UI in-game and test.

## In-game test reminder

After syncing, use /reload in World of Warcraft to load the latest addon files.
