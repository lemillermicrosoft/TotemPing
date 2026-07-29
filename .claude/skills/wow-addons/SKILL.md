# World of Warcraft Addon Development

## Overview

Use this skill for practical WoW addon work across Vanilla/Classic, TBC, Wrath, and Modern clients.

Focus on:

- Safe UI/API usage and taint avoidance
- Idiomatic Lua 5.1 patterns
- Clear SavedVariables and event-driven architecture
- Packaging and release hygiene for addon publishing

## When to use this skill

Use this skill when the user asks to:

- Build or modify addon Lua/XML/TOC files
- Debug addon runtime behavior, events, or frame updates
- Improve addon performance or state management
- Prepare release artifacts (version bump and publish zip)

## General rules

- Prefer event-driven updates over heavy OnUpdate loops.
- Keep frame and secure action handling taint-safe.
- Use TOC as the source of truth for runtime load order.
- Keep release changes atomic and reproducible.

## File structure conventions

Recommend a simple layout:

```text
MyAddon/
  MyAddon.toc
  Core.lua
  Events.lua
  UI/
    MainFrame.lua
  Data/
  README.md
  LICENSE
```

## TOC and versioning guidance

- Keep addon runtime version in one Lua constant (for UI display) and keep it aligned with TOC metadata.
- Prefer these fields in TOC:
  - `## Interface: <client_interface_number>`
  - `## Version: <semver_like_value>`
- Ensure any in-UI version text reads from the Lua version constant, not hardcoded text.

## TalonTracker release flow (atomic)

For this repository, bump version and package publish zip in the same workflow.

1. Update version and interface metadata:
   - `TalonTracker.toc`
     - `## Interface: ...`
     - `## Version: x.y.z`
   - `Core.lua`
     - `TT.VERSION = "x.y.z"`
2. Build publish archive immediately after bump.
3. Output archive path:
   - `dist/TalonTracker-vx.y.z.zip`
4. Zip root must be `TalonTracker/`.
5. Include runtime files listed in TOC plus `README.md` and `LICENSE`.
6. Exclude development-only folders and files (for example `.git`, `.claude`, `.agent`, `screenshots`, `scripts`).
7. Validate archive contents before completing the task.

## Packaging checklist

- TOC version and Lua version match exactly.
- Interface number is current for target client flavor.
- Archive name matches version.
- Archive root folder is correct for addon installation.
- No dev-only files included.
