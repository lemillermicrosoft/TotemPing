# WoW Addon List Image (IconTexture) Skill

## Overview

Use this skill when an addon should show a custom image in the in-game AddOns list.

In your installed addons, this is done with TOC metadata:

- `## IconTexture: <texture path or FileDataID>`

## What was validated from your local AddOns folder

Scanned path:

- `C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns`

Observed working examples:

- Questie: `## IconTexture: Interface\AddOns\Questie\Icons\questie.png`
- GatherMate2: `## IconTexture: Interface\AddOns\GatherMate2\Artwork\Icon.tga`
- WeakAuras: `## IconTexture: Interface\AddOns\WeakAuras\Media\Textures\icon.blp`
- MoveAny: `## IconTexture: 135994` (numeric FileDataID)

Conclusion:

- The correct key for addon-list image is `IconTexture` in the TOC.
- Blizzard file paths and addon-local paths both work.
- File extension may be present or omitted depending on the texture.

## When to use this

Use when user asks:

- "Why does my addon have no image in the AddOns menu?"
- "How do I add an icon like other addons?"
- "What TOC field controls addon image?"

## Implementation pattern

1. Place a texture in your addon folder.
- Recommended location: `Media\icon` (or `Media\icon.blp` / `Media\icon.tga` / `Media\icon.png`).

2. Add metadata to the addon TOC near title/version lines.

Example:

```toc
## Interface: 11508
## Title: SwingPulse
## Notes: Minimal melee swing timer with optional dual-wield tracking.
## Author: GitHub Copilot c/o deehoc
## Version: 0.1.3
## IconTexture: Interface\AddOns\SwingPulse\Media\icon
## SavedVariables: SwingPulseDB
```

3. Reload UI or restart client and open AddOns list to verify image appears.

## Rules and pitfalls

- Use exactly `## IconTexture:` (case-sensitive convention).
- Use a valid WoW texture path format rooted at `Interface\...`.
- Prefer backslashes in TOC paths for consistency with most addons.
- If using a numeric value, it must be a valid FileDataID.
- Ensure the image file is included in the installed addon folder.
- If icon does not appear, confirm:
  - Path spelling and addon folder name match exactly.
  - Texture exists in that location.
  - You edited the active TOC for the current client flavor.

## Optional fallback strategy

If addon-local texture has issues, use a known Blizzard icon first to validate metadata wiring:

- `## IconTexture: Interface\Icons\INV_Misc_QuestionMark`

Then switch back to your addon-local icon path.

## SwingPulse-specific note

Current `SwingPulse.toc` does not include an `IconTexture` line yet. Add one once your icon asset is placed.
