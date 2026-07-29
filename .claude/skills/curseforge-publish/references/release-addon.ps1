<#
.SYNOPSIS
    Full release pipeline: build zip, git tag/push, GitHub release, CurseForge upload.

.PARAMETER RepoRoot
    Repo root. Defaults to script location's parent chain.

.PARAMETER BumpPatch / BumpMinor / BumpMajor / SetVersion
    Passed through to build-addon.ps1.

.PARAMETER ReleaseType
    CurseForge release type: release | beta | alpha. Default from .curseforge.json.

.PARAMETER SkipGit
    Skip git commit/tag/push.

.PARAMETER SkipGitHub
    Skip GitHub release (still tags/pushes if git not skipped).

.PARAMETER SkipCurseForge
    Skip CurseForge upload.

.PARAMETER DryRun
    Show what would happen without side effects.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$BumpPatch,
    [switch]$BumpMinor,
    [switch]$BumpMajor,
    [string]$SetVersion,
    [ValidateSet("release","beta","alpha")][string]$ReleaseType,
    [switch]$SkipGit,
    [switch]$SkipGitHub,
    [switch]$SkipCurseForge,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $here "..\..\..\..")).Path }

# Refresh env from persistent scopes (User/Machine) in case shell started before token was set
foreach ($v in 'CURSEFORGE_API_TOKEN') {
    if (-not (Get-Item -Path "Env:$v" -ErrorAction SilentlyContinue).Value) {
        $val = [Environment]::GetEnvironmentVariable($v,'User')
        if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v,'Machine') }
        if ($val) { Set-Item -Path "Env:$v" -Value $val }
    }
}
# Refresh PATH so gh is discoverable if installed after shell start
$env:Path = ([Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User'))

Write-Host "==== [release-addon] Build ====" -ForegroundColor Cyan
$buildArgs = @{ RepoRoot = $RepoRoot; Validate = $true }
if ($DryRun)     { $buildArgs.DryRun = $true }
if ($BumpPatch)   { $buildArgs.BumpPatch = $true }
if ($BumpMinor)   { $buildArgs.BumpMinor = $true }
if ($BumpMajor)   { $buildArgs.BumpMajor = $true }
if ($SetVersion)  { $buildArgs.SetVersion = $SetVersion }

$buildScript = Join-Path $here "build-addon.ps1"
$result = & $buildScript @buildArgs
if (-not $result) { throw "Build failed." }

$addon = $result.AddonName
$version = $result.Version
$zipPath = $result.ZipPath
$tag = "v$version"

Write-Host ("[release-addon] {0} {1} -> {2}" -f $addon, $tag, $zipPath) -ForegroundColor Green

# Changelog for GitHub/CurseForge
$changelogPath = Join-Path $RepoRoot "CHANGELOG_RELEASE.md"
$changelog = if (Test-Path -LiteralPath $changelogPath) { Get-Content -LiteralPath $changelogPath -Raw } else { "Release $tag" }

Push-Location $RepoRoot
try {
    if (-not $SkipGit) {
        Write-Host "==== [release-addon] Git ====" -ForegroundColor Cyan
        $status = (git status --porcelain) -join "`n"
        if ($status) {
            if ($DryRun) {
                Write-Host "[release-addon] DryRun: would commit:" -ForegroundColor Yellow
                Write-Host $status
            } else {
                git add -A | Out-Null
                git commit -m ("chore(release): {0} {1}" -f $addon, $tag) | Out-Null
            }
        }
        # Tag
        $existing = git tag --list $tag
        if ($existing) {
            Write-Warning "Tag $tag already exists; skipping tag creation."
        } elseif ($DryRun) {
            Write-Host "[release-addon] DryRun: would tag $tag" -ForegroundColor Yellow
        } else {
            git tag -a $tag -m ("Release {0}" -f $tag) | Out-Null
        }
        if (-not $DryRun) {
            git push | Out-Null
            git push --tags | Out-Null
        }

        if (-not $SkipGitHub) {
            Write-Host "==== [release-addon] GitHub Release ====" -ForegroundColor Cyan
            $gh = Get-Command gh -ErrorAction SilentlyContinue
            if (-not $gh) {
                Write-Warning "gh CLI not found; skipping GitHub release. Install with: winget install --id GitHub.cli"
            } else {
                $notesFile = [System.IO.Path]::GetTempFileName()
                Set-Content -LiteralPath $notesFile -Value $changelog -Encoding utf8
                try {
                    if ($DryRun) {
                        Write-Host ("[release-addon] DryRun: gh release create {0} {1} -F <notes>" -f $tag, $zipPath) -ForegroundColor Yellow
                    } else {
                        gh release create $tag $zipPath -t $tag -F $notesFile
                    }
                } finally { Remove-Item -LiteralPath $notesFile -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    if (-not $SkipCurseForge) {
        Write-Host "==== [release-addon] CurseForge ====" -ForegroundColor Cyan
        $uploadScript = Join-Path $here "upload-curseforge.ps1"
        $uploadArgs = @{ RepoRoot = $RepoRoot; ZipPath = $zipPath }
        if ($ReleaseType) { $uploadArgs.ReleaseType = $ReleaseType }
        if ($DryRun) { $uploadArgs.DryRun = $true }
        & $uploadScript @uploadArgs
    }
}
finally { Pop-Location }

Write-Host ("[release-addon] Done: {0} {1}" -f $addon, $tag) -ForegroundColor Green
