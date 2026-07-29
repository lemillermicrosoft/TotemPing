<#
.SYNOPSIS
    Package a WoW addon for CurseForge distribution.

.DESCRIPTION
    Generic packager for WoW addons. Auto-detects addon name from the TOC file
    in the repo root. Reads version from `## Version:` in the TOC, optionally
    bumps semver, syncs matching `X.VERSION = "..."` lines in Lua files, stages
    TOC-listed files into a temp folder, and produces `dist/<Addon>-v<version>.zip`.

.PARAMETER RepoRoot
    Repo root. Defaults to two levels up from this script (…/skills/curseforge-publish/references → repo root).

.PARAMETER BumpPatch
    Increment patch component before build (x.y.Z -> x.y.Z+1).

.PARAMETER BumpMinor
    Increment minor component (resets patch to 0).

.PARAMETER BumpMajor
    Increment major component (resets minor and patch to 0).

.PARAMETER SetVersion
    Explicit version string, e.g. "1.2.3". Wins over bump flags.

.PARAMETER Validate
    After build, list zip entries and run sanity checks.

.PARAMETER SkipLuaVersionSync
    Do not update `X.VERSION = "..."` lines in Lua files.

.EXAMPLE
    .\build-addon.ps1                       # build at current TOC version
    .\build-addon.ps1 -BumpPatch -Validate  # bump patch, build, validate
    .\build-addon.ps1 -SetVersion 1.0.0
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$BumpPatch,
    [switch]$BumpMinor,
    [switch]$BumpMajor,
    [string]$SetVersion,
    [switch]$Validate,
    [switch]$SkipLuaVersionSync,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    param([string]$Explicit)
    if ($Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
    # references/ -> curseforge-publish/ -> skills/ -> .claude/ -> repo root
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Resolve-Path -LiteralPath (Join-Path $here "..\..\..\..")).Path
}

function Find-TocFile {
    param([string]$RepoRoot)
    $tocFiles = Get-ChildItem -LiteralPath $RepoRoot -Filter *.toc -File
    # Prefer TOC whose base name matches the repo folder name
    $repoName = Split-Path -Leaf $RepoRoot
    $match = $tocFiles | Where-Object { $_.BaseName -eq $repoName } | Select-Object -First 1
    if ($match) { return $match }
    if ($tocFiles.Count -eq 1) { return $tocFiles[0] }
    if ($tocFiles.Count -eq 0) { throw "No .toc file found in $RepoRoot" }
    throw ("Multiple .toc files in {0}; expected one matching '{1}': {2}" -f $RepoRoot, $repoName, ($tocFiles.Name -join ", "))
}

function Get-TocVersion {
    param([string]$TocPath)
    $line = Select-String -Path $TocPath -Pattern '^## Version:\s*(.+)$' | Select-Object -First 1
    if (-not $line) { throw "Could not find '## Version:' in $TocPath" }
    return $line.Matches[0].Groups[1].Value.Trim()
}

function Get-TocEntries {
    param([string]$TocPath)
    Get-Content -LiteralPath $TocPath | ForEach-Object {
        $t = $_.Trim()
        if ($t -and -not $t.StartsWith("#")) { $t }
    }
}

function Step-SemVer {
    param([string]$Version, [switch]$Major, [switch]$Minor, [switch]$Patch)
    # Split off pre-release/build suffix (e.g. "0.5.0-alpha")
    $core = $Version
    $suffix = ""
    $dash = $Version.IndexOf('-')
    if ($dash -ge 0) {
        $core = $Version.Substring(0, $dash)
        $suffix = $Version.Substring($dash) # includes the dash
    }
    $parts = $core.Split('.')
    while ($parts.Count -lt 3) { $parts += "0" }
    $maj = [int]$parts[0]; $min = [int]$parts[1]; $pat = [int]$parts[2]
    if ($Major) { $maj++; $min = 0; $pat = 0 }
    elseif ($Minor) { $min++; $pat = 0 }
    elseif ($Patch) { $pat++ }
    return ("{0}.{1}.{2}{3}" -f $maj, $min, $pat, $suffix)
}

function Update-TocVersion {
    param([string]$TocPath, [string]$NewVersion)
    $content = Get-Content -LiteralPath $TocPath -Raw
    $updated = [regex]::Replace($content, '(?m)^(##\s*Version:\s*).+$', ('${1}' + $NewVersion))
    if ($content -eq $updated) { throw "Failed to update version line in $TocPath" }
    Set-Content -LiteralPath $TocPath -Value $updated -NoNewline:$false -Encoding utf8
}

function Update-LuaVersions {
    param([string]$RepoRoot, [string]$NewVersion)
    $changed = @()
    $luaFiles = Get-ChildItem -LiteralPath $RepoRoot -Filter *.lua -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\dist\\' -and $_.FullName -notmatch '\\\.tmp\\' }
    foreach ($f in $luaFiles) {
        $orig = Get-Content -LiteralPath $f.FullName -Raw
        # Match: <Ident>.VERSION = "x.y.z"  (also handles single quotes)
        $updated = [regex]::Replace($orig, '([A-Za-z_][A-Za-z0-9_]*\.VERSION\s*=\s*)(["''])[^"'']+\2', ('${1}${2}' + $NewVersion + '${2}'))
        if ($orig -ne $updated) {
            Set-Content -LiteralPath $f.FullName -Value $updated -NoNewline:$false -Encoding utf8
            $changed += $f.FullName
        }
    }
    return $changed
}

# -------- main --------

$RepoRoot = Resolve-RepoRoot -Explicit $RepoRoot
$toc = Find-TocFile -RepoRoot $RepoRoot
$addonName = $toc.BaseName
$currentVersion = Get-TocVersion -TocPath $toc.FullName

$newVersion = $currentVersion
if ($SetVersion) {
    $newVersion = $SetVersion.Trim()
} elseif ($BumpMajor -or $BumpMinor -or $BumpPatch) {
    $newVersion = Step-SemVer -Version $currentVersion -Major:$BumpMajor -Minor:$BumpMinor -Patch:$BumpPatch
}

if ($newVersion -ne $currentVersion) {
    if ($DryRun) {
        Write-Host ("[build-addon] DryRun: would bump {0} -> {1} (TOC + Lua unchanged)" -f $currentVersion, $newVersion) -ForegroundColor Yellow
    } else {
        Write-Host ("[build-addon] Version {0} -> {1}" -f $currentVersion, $newVersion)
        Update-TocVersion -TocPath $toc.FullName -NewVersion $newVersion
        if (-not $SkipLuaVersionSync) {
            $changed = Update-LuaVersions -RepoRoot $RepoRoot -NewVersion $newVersion
            foreach ($c in $changed) { Write-Host ("[build-addon] Synced Lua VERSION in: {0}" -f (Resolve-Path -Relative $c)) }
        }
    }
}

$version = $newVersion
$distDir = Join-Path $RepoRoot "dist"
if (-not (Test-Path -LiteralPath $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

$zipPath = Join-Path $distDir ("{0}-v{1}.zip" -f $addonName, $version)
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-release-{1}" -f $addonName, [guid]::NewGuid())
$stageRoot = Join-Path $tempRoot $addonName
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

try {
    # Copy TOC
    Copy-Item -LiteralPath $toc.FullName -Destination (Join-Path $stageRoot $toc.Name) -Force

    # Copy TOC-listed entries
    $entries = Get-TocEntries -TocPath $toc.FullName
    foreach ($entry in $entries) {
        $source = Join-Path $RepoRoot $entry
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing TOC entry source: $entry" }
        $dest = Join-Path $stageRoot $entry
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        # Handle folder XML includes (e.g. Bindings.xml, embedded libs referenced as folders)
        if ((Get-Item -LiteralPath $source).PSIsContainer) {
            Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
        } else {
            Copy-Item -LiteralPath $source -Destination $dest -Force
        }
    }

    # Always include Media/ if present (icons/textures referenced by TOC IconTexture etc.)
    $mediaDir = Join-Path $RepoRoot "Media"
    if (Test-Path -LiteralPath $mediaDir) {
        Copy-Item -LiteralPath $mediaDir -Destination (Join-Path $stageRoot "Media") -Recurse -Force
    }

    # Include README + LICENSE + Bindings.xml if present
    foreach ($extra in @("README.md","LICENSE","LICENSE.md","LICENSE.txt","Bindings.xml","CHANGELOG.md","CHANGELOG_RELEASE.md")) {
        $src = Join-Path $RepoRoot $extra
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $stageRoot $extra) -Force
        }
    }

    Compress-Archive -Path $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal -Force
    Write-Host ("[build-addon] Created: {0}" -f $zipPath) -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

if ($Validate) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = $zip.Entries | Select-Object -ExpandProperty FullName
        Write-Host "[build-addon] Archive entries:"
        $entries | ForEach-Object { Write-Host "  $_" }

        $bad = $entries | Where-Object { $_ -match '(^|/)\.(git|claude|agent|tmp|vscode)(/|$)' -or $_ -match '(^|/)tools/' -or $_ -match '(^|/)dist/' }
        if ($bad) {
            Write-Warning "Dev-only entries found in archive:"
            $bad | ForEach-Object { Write-Warning "  $_" }
        } else {
            Write-Host "[build-addon] Validation OK: no dev-only entries." -ForegroundColor Green
        }
    }
    finally { $zip.Dispose() }
}

# Emit result object for pipeline consumers
[pscustomobject]@{
    AddonName = $addonName
    Version   = $version
    ZipPath   = $zipPath
    RepoRoot  = $RepoRoot
}
