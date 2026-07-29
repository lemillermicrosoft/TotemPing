<#
.SYNOPSIS
    Copy this skill's reference scripts to another addon repo.

.DESCRIPTION
    Since the skill lives duplicated in each repo (self-contained), this
    script keeps them in sync. Run from the "source of truth" repo to push
    updated scripts to another repo's `.claude/skills/curseforge-publish/`.

.PARAMETER To
    Target repo root (or comma-separated list). Example: ..\TalonTracker
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string[]]$To
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$sourceSkillRoot = (Resolve-Path -LiteralPath (Join-Path $here "..")).Path

foreach ($target in $To) {
    $targetRepo = (Resolve-Path -LiteralPath $target).Path
    $targetSkill = Join-Path $targetRepo ".claude\skills\curseforge-publish"
    Write-Host ("[sync] {0} -> {1}" -f $sourceSkillRoot, $targetSkill) -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $targetSkill)) {
        New-Item -ItemType Directory -Path $targetSkill -Force | Out-Null
    }
    # Copy SKILL.md and references/
    Copy-Item -LiteralPath (Join-Path $sourceSkillRoot "SKILL.md") -Destination (Join-Path $targetSkill "SKILL.md") -Force
    $refsSrc = Join-Path $sourceSkillRoot "references"
    $refsDst = Join-Path $targetSkill "references"
    if (Test-Path -LiteralPath $refsDst) { Remove-Item -LiteralPath $refsDst -Recurse -Force }
    Copy-Item -LiteralPath $refsSrc -Destination $refsDst -Recurse -Force
    Write-Host "[sync] done." -ForegroundColor Green
}
