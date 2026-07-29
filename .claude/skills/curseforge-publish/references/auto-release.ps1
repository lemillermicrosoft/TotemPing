<#
.SYNOPSIS
    Fully automated release: infer semver bump from git log, generate changelog,
    then run the full build -> git tag/push -> GitHub release -> CurseForge upload
    pipeline via release-addon.ps1.

.DESCRIPTION
    Bump inference (conventional-commit-ish, case-insensitive):
      * BREAKING CHANGE in body, or "!" before ":" in subject   -> MAJOR
      * feat(...)/feature(...)                                   -> MINOR
      * anything else (fix, chore, docs, refactor, perf, etc.)   -> PATCH

    Reads commits since the last "v*" tag (or the whole history if none exists).
    Groups them into Features / Fixes / Other and writes CHANGELOG_RELEASE.md,
    which release-addon.ps1 then passes to GitHub Releases and CurseForge.

.PARAMETER RepoRoot
    Repo root. Defaults to the repo containing this script.

.PARAMETER ReleaseType
    CurseForge release type: release | beta | alpha. Default: release.

.PARAMETER ForceBump
    Override the inferred bump. One of: major, minor, patch.

.PARAMETER MinBump
    Floor for the inferred bump (in case there are zero interesting commits).
    Default: patch.

.PARAMETER DryRun
    Show what would happen; no version/toc changes, no git writes, no uploads.

.EXAMPLE
    .\auto-release.ps1 -DryRun
    .\auto-release.ps1
    .\auto-release.ps1 -ForceBump minor
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [ValidateSet("release","beta","alpha")][string]$ReleaseType = "release",
    [ValidateSet("major","minor","patch")][string]$ForceBump,
    [ValidateSet("major","minor","patch")][string]$MinBump = "patch",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $here "..\..\..\..")).Path }

function Get-LastTag {
    param([string]$RepoRoot)
    Push-Location $RepoRoot
    try {
        $tag = (git tag --list "v*" --sort=-v:refname 2>$null) | Select-Object -First 1
        if ($tag) { return $tag.Trim() } else { return $null }
    } finally { Pop-Location }
}

function Get-CommitsSince {
    param([string]$RepoRoot, [string]$Tag)
    Push-Location $RepoRoot
    try {
        $range = if ($Tag) { "$Tag..HEAD" } else { "HEAD" }
        # Use printable delimiters (git %x escapes don't survive PowerShell arg handling on Win PS 5.1).
        # <<F>> between fields, <<R>> between records. Extremely unlikely to appear in commit text.
        $raw = git log $range --format="%H<<F>>%s<<F>>%b<<R>>" 2>$null
        if (-not $raw) { return @() }
        $entries = ($raw -join "`n") -split "<<R>>" | Where-Object { $_.Trim() }
        $out = @()
        foreach ($e in $entries) {
            $parts = $e -split "<<F>>", 3
            if ($parts.Count -lt 2) { continue }
            $out += [pscustomobject]@{
                Sha     = $parts[0].Trim()
                Subject = $parts[1].Trim()
                Body    = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
            }
        }
        return $out
    } finally { Pop-Location }
}

function Get-CommitBumpAndKind {
    param([string]$Subject, [string]$Body)
    $s = $Subject
    $b = $Body
    # BREAKING CHANGE anywhere in body, or bang before colon (feat!:, fix!:, chore(scope)!:)
    if ($b -match '(?i)BREAKING CHANGE' -or $s -match '^[A-Za-z]+(\([^)]+\))?!:') {
        return @{ Bump = 'major'; Kind = 'breaking' }
    }
    if ($s -match '^(?i)(feat|feature)(\([^)]+\))?:') {
        return @{ Bump = 'minor'; Kind = 'feature' }
    }
    if ($s -match '^(?i)(fix|bugfix|hotfix)(\([^)]+\))?:') {
        return @{ Bump = 'patch'; Kind = 'fix' }
    }
    return @{ Bump = 'patch'; Kind = 'other' }
}

function Get-BumpRank { param([string]$B)
    switch ($B) { 'major' {3} 'minor' {2} 'patch' {1} default {0} }
}
function Get-BumpFromRank { param([int]$R)
    switch ($R) { 3 {'major'} 2 {'minor'} default {'patch'} }
}

# ---- Inspect history ----
$lastTag = Get-LastTag -RepoRoot $RepoRoot
$commits = Get-CommitsSince -RepoRoot $RepoRoot -Tag $lastTag

if (-not $commits -or $commits.Count -eq 0) {
    $sinceLabel = if ($lastTag) { $lastTag } else { 'start of history' }
    Write-Warning ("[auto-release] No commits since {0}; nothing to release." -f $sinceLabel)
    return
}

$classified = foreach ($c in $commits) {
    $cls = Get-CommitBumpAndKind -Subject $c.Subject -Body $c.Body
    [pscustomobject]@{
        Sha = $c.Sha.Substring(0, [Math]::Min(7, $c.Sha.Length))
        Subject = $c.Subject
        Body = $c.Body
        Bump = $cls.Bump
        Kind = $cls.Kind
    }
}

# Choose bump: highest of (inferred, MinBump); ForceBump wins outright.
if ($ForceBump) {
    $bump = $ForceBump
} else {
    $inferred = ($classified | ForEach-Object { Get-BumpRank $_.Bump } | Measure-Object -Maximum).Maximum
    $floor = Get-BumpRank $MinBump
    $bump = Get-BumpFromRank ([Math]::Max($inferred, $floor))
}

# ---- Compute prospective next version ----
function Read-TocVersion {
    param([string]$RepoRoot)
    $toc = Get-ChildItem -LiteralPath $RepoRoot -Filter *.toc -File | Where-Object {
        $_.BaseName -eq (Split-Path -Leaf $RepoRoot)
    } | Select-Object -First 1
    if (-not $toc) { $toc = Get-ChildItem -LiteralPath $RepoRoot -Filter *.toc -File | Select-Object -First 1 }
    if (-not $toc) { throw "No .toc file found" }
    $line = Select-String -Path $toc.FullName -Pattern '^## Version:\s*(.+)$' | Select-Object -First 1
    return @{ Toc = $toc.FullName; Version = $line.Matches[0].Groups[1].Value.Trim() }
}
function Step-Ver { param([string]$V,[string]$Bump)
    $core = $V; $suffix = ""
    if ($V.Contains('-')) { $core = $V.Substring(0,$V.IndexOf('-')); $suffix = $V.Substring($V.IndexOf('-')) }
    $p = $core.Split('.'); while ($p.Count -lt 3) { $p += "0" }
    $maj=[int]$p[0]; $min=[int]$p[1]; $pat=[int]$p[2]
    switch ($Bump) {
        'major' { $maj++; $min=0; $pat=0 }
        'minor' { $min++; $pat=0 }
        default { $pat++ }
    }
    return "$maj.$min.$pat$suffix"
}

$info = Read-TocVersion -RepoRoot $RepoRoot
$currentVer = $info.Version
$nextVer = Step-Ver -V $currentVer -Bump $bump
$nextTag = "v$nextVer"

# ---- Build changelog ----
$feats = @($classified | Where-Object { $_.Kind -eq 'feature' -or $_.Kind -eq 'breaking' })
$fixes = @($classified | Where-Object { $_.Kind -eq 'fix' })
$others = @($classified | Where-Object { $_.Kind -eq 'other' })

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# $nextTag")
[void]$sb.AppendLine()
if ($lastTag) {
    [void]$sb.AppendLine("Changes since $lastTag.")
} else {
    [void]$sb.AppendLine("Initial tagged release.")
}
[void]$sb.AppendLine()

function Add-Section { param($Title, $Items)
    if (-not $Items -or $Items.Count -eq 0) { return }
    [void]$sb.AppendLine("## $Title")
    foreach ($it in $Items) {
        # Strip conventional-commit prefix from the display line but keep scope readable.
        $line = $it.Subject
        $line = [regex]::Replace($line, '^(?i)(feat|feature|fix|bugfix|hotfix|chore|docs|refactor|perf|test|build|ci|style)(\([^)]+\))?!?:\s*', '')
        [void]$sb.AppendLine("- $line ($($it.Sha))")
    }
    [void]$sb.AppendLine()
}

Add-Section "Features" $feats
Add-Section "Fixes" $fixes
Add-Section "Other" $others

$changelog = $sb.ToString().TrimEnd() + "`r`n"

# ---- Report ----
Write-Host ""
Write-Host "==== [auto-release] Plan ====" -ForegroundColor Cyan
Write-Host ("Repo:         {0}" -f $RepoRoot)
$lastTagLabel = if ($lastTag) { $lastTag } else { '(none)' }
Write-Host ("Last tag:     {0}" -f $lastTagLabel)
Write-Host ("Commits:      {0}" -f $commits.Count)
Write-Host ("Inferred bump:{0}" -f $bump)
Write-Host ("Version:      {0} -> {1}" -f $currentVer, $nextVer)
Write-Host ("Release type: {0}" -f $ReleaseType)
Write-Host ""
Write-Host "---- CHANGELOG_RELEASE.md ----" -ForegroundColor DarkGray
Write-Host $changelog
Write-Host "-------------------------------" -ForegroundColor DarkGray

# ---- Write changelog ----
$changelogPath = Join-Path $RepoRoot "CHANGELOG_RELEASE.md"
if ($DryRun) {
    Write-Host ("[auto-release] DryRun: would write {0}" -f $changelogPath) -ForegroundColor Yellow
} else {
    Set-Content -LiteralPath $changelogPath -Value $changelog -Encoding utf8
    Write-Host ("[auto-release] Wrote {0}" -f $changelogPath) -ForegroundColor Green
}

# ---- Delegate to release-addon.ps1 ----
$releaseScript = Join-Path $here "release-addon.ps1"
$releaseArgs = @{
    RepoRoot    = $RepoRoot
    ReleaseType = $ReleaseType
}
switch ($bump) {
    'major' { $releaseArgs.BumpMajor = $true }
    'minor' { $releaseArgs.BumpMinor = $true }
    default { $releaseArgs.BumpPatch = $true }
}
if ($DryRun) { $releaseArgs.DryRun = $true }

Write-Host ""
Write-Host "==== [auto-release] Handoff to release-addon.ps1 ====" -ForegroundColor Cyan
& $releaseScript @releaseArgs
