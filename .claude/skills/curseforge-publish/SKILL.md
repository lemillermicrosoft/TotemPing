# CurseForge Publish Workflow

Automates building, versioning, tagging, GitHub-releasing, and CurseForge-uploading a WoW addon.

## When to use

The user asks to:

- prepare/build a new release zip
- bump version (patch/minor/major/explicit) and package in one pass
- publish to CurseForge
- cut a full release (git tag + GitHub release + CurseForge upload)
- verify release archive contents

## Scripts (in `references/`)

All scripts are self-contained PowerShell and auto-detect the repo root from their own location. Run from anywhere; typical use is from the repo root.

### `build-addon.ps1` — package zip
Reads `## Version:` from the single `.toc`, optionally bumps semver, syncs `X.VERSION = "..."` lines in `.lua` files, stages TOC-listed entries + `Media/`, `README.md`, `LICENSE`, `CHANGELOG_RELEASE.md` (if present) into a temp folder, produces `dist/<Addon>-v<version>.zip`.

```powershell
.\.claude\skills\curseforge-publish\references\build-addon.ps1                     # build current version
.\.claude\skills\curseforge-publish\references\build-addon.ps1 -BumpPatch -Validate
.\.claude\skills\curseforge-publish\references\build-addon.ps1 -SetVersion 1.0.0
```

Flags: `-BumpPatch`, `-BumpMinor`, `-BumpMajor`, `-SetVersion x.y.z`, `-Validate`, `-SkipLuaVersionSync`.

### `upload-curseforge.ps1` — upload zip to CurseForge
Requires `.curseforge.json` in repo root (see below) and `$env:CURSEFORGE_API_TOKEN`.

```powershell
.\.claude\skills\curseforge-publish\references\upload-curseforge.ps1                      # newest zip in dist/
.\.claude\skills\curseforge-publish\references\upload-curseforge.ps1 -ZipPath dist\X.zip -ReleaseType beta
.\.claude\skills\curseforge-publish\references\upload-curseforge.ps1 -DryRun
```

### `auto-release.ps1` — hands-off release
Infers major/minor/patch from git log since the last `v*` tag using conventional-commit heuristics (`BREAKING CHANGE`/`!` → major, `feat` → minor, everything else → patch), writes `CHANGELOG_RELEASE.md` grouped into Features/Fixes/Other, then delegates to `release-addon.ps1`.

```powershell
.\.claude\skills\curseforge-publish\references\auto-release.ps1 -DryRun
.\.claude\skills\curseforge-publish\references\auto-release.ps1
.\.claude\skills\curseforge-publish\references\auto-release.ps1 -ForceBump minor
```

Flags: `-ReleaseType release|beta|alpha` (default `release`), `-ForceBump major|minor|patch`, `-MinBump major|minor|patch` (default `patch`), `-DryRun`.

### `release-addon.ps1` — full pipeline
Chains build → git commit/tag/push → GitHub release (via `gh`) → CurseForge upload.

```powershell
.\.claude\skills\curseforge-publish\references\release-addon.ps1 -BumpPatch
.\.claude\skills\curseforge-publish\references\release-addon.ps1 -SetVersion 1.2.0 -ReleaseType beta
.\.claude\skills\curseforge-publish\references\release-addon.ps1 -BumpPatch -DryRun
```

Flags: any `build-addon.ps1` version flags plus `-ReleaseType`, `-SkipGit`, `-SkipGitHub`, `-SkipCurseForge`, `-DryRun`.

### `sync-tooling.ps1` — propagate this skill to sibling addon repos
Since the skill is copy-pasted per repo (each cloner should get working tooling), use this to keep them in sync after edits.

```powershell
.\.claude\skills\curseforge-publish\references\sync-tooling.ps1 -To ..\TalonTracker,..\DPSPulse
```

## Configuration

### Per-repo `.curseforge.json` (required for uploads)

Place at repo root:

```json
{
  "projectId": 123456,
  "gameVersions": ["11.1.5"],
  "releaseType": "release"
}
```

- `projectId`: from the CurseForge project page sidebar.
- `gameVersions`: array of version names (e.g. `"11.1.5"`) or slugs; resolved to numeric IDs via the CurseForge API at upload time.
  - Alternatively, `gameVersionIds`: an array of numeric IDs (bypasses lookup).
- `releaseType`: `release` | `beta` | `alpha`. Overridable per-invocation.

### Environment

- `CURSEFORGE_API_TOKEN` — get from CurseForge → avatar → *My API Tokens*.
  - Set persistently: `[Environment]::SetEnvironmentVariable("CURSEFORGE_API_TOKEN", "…", "User")`
- `gh` CLI (optional) — needed for GitHub release step. Install: `winget install --id GitHub.cli`; auth: `gh auth login`.

## Release checklist

- Version bumped in TOC (and auto-synced to `X.VERSION` in Lua).
- `## Interface:` value is current for the target WoW flavor. (Not auto-updated; edit manually before release.)
- `CHANGELOG_RELEASE.md` written (used as GitHub + CurseForge notes).
- Archive validated: no dev-only paths (`.git`, `.claude`, `.agent`, `.tmp`, `tools/`, `dist/`).
- Zip root folder equals addon name (installs cleanly into `Interface/AddOns`).

## Notes

- Deterministic packaging: only TOC-listed files + `Media/`, README, LICENSE, CHANGELOG go into the zip.
- Dev-only content (`.git`, `.claude`, `.agent`, `.tmp`, `tools/`, `dist/`, `PLAN.md`, research notes) is excluded by construction — the packager only copies allow-listed paths.
- CurseForge upload API reference: https://support.curseforge.com/en/support/solutions/articles/9000197321
- Omit hidden/private easter eggs from generated release notes unless explicitly asked.
