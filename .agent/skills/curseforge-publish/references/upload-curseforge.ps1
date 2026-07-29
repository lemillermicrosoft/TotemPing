<#
.SYNOPSIS
    Upload a built addon zip to CurseForge via the official upload API.

.DESCRIPTION
    Reads .curseforge.json in the repo root for projectId, gameVersions
    (or gameVersionTypes), and default releaseType. Uses $env:CURSEFORGE_API_TOKEN
    for authentication. Resolves game version slugs to numeric IDs via
    the CurseForge upload API (https://wow.curseforge.com/api/game/versions).

    API docs: https://support.curseforge.com/en/support/solutions/articles/9000197321

.PARAMETER RepoRoot
    Repo root. Defaults to two levels up from this script (references -> skill -> skills -> .claude -> repo).

.PARAMETER ZipPath
    Path to the zip to upload. Defaults to the newest zip in dist/.

.PARAMETER Changelog
    Changelog text (Markdown). If omitted, uses CHANGELOG_RELEASE.md in repo root, else generated placeholder.

.PARAMETER ChangelogType
    text | html | markdown. Default markdown.

.PARAMETER ReleaseType
    release | beta | alpha. Overrides .curseforge.json.

.PARAMETER DisplayName
    Optional display name (default: zip basename).

.PARAMETER DryRun
    Show payload but do not upload.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$ZipPath,
    [string]$Changelog,
    [ValidateSet("text","html","markdown")][string]$ChangelogType = "markdown",
    [ValidateSet("release","beta","alpha")][string]$ReleaseType,
    [string]$DisplayName,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    param([string]$Explicit)
    if ($Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Resolve-Path -LiteralPath (Join-Path $here "..\..\..\..")).Path
}

$RepoRoot = Resolve-RepoRoot -Explicit $RepoRoot

# Config
$configPath = Join-Path $RepoRoot ".curseforge.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Missing .curseforge.json in $RepoRoot. Create one with { projectId, gameVersions, releaseType }."
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

if (-not $config.projectId) {
    throw "projectId missing in .curseforge.json. Find it on the CurseForge project page (top-right sidebar)."
}
$projectId = [int]$config.projectId

if (-not $ReleaseType) {
    if ($config.releaseType) { $ReleaseType = $config.releaseType } else { $ReleaseType = "release" }
}

# Token
$token = $env:CURSEFORGE_API_TOKEN
if (-not $token) { $token = [Environment]::GetEnvironmentVariable('CURSEFORGE_API_TOKEN','User') }
if (-not $token) { $token = [Environment]::GetEnvironmentVariable('CURSEFORGE_API_TOKEN','Machine') }
if (-not $token) { throw "CURSEFORGE_API_TOKEN env var is not set." }

# Zip
if (-not $ZipPath) {
    $distDir = Join-Path $RepoRoot "dist"
    $ZipPath = (Get-ChildItem -LiteralPath $distDir -Filter *.zip -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    if (-not $ZipPath) { throw "No zip found in $distDir." }
}
if (-not [IO.Path]::IsPathRooted($ZipPath)) {
    $ZipPath = Join-Path $RepoRoot $ZipPath
}
if (-not (Test-Path -LiteralPath $ZipPath)) { throw "Zip not found: $ZipPath" }
$ZipPath = (Resolve-Path -LiteralPath $ZipPath).Path
Write-Host ("[cf-upload] Uploading: {0}" -f $ZipPath)

if (-not $DisplayName) { $DisplayName = [IO.Path]::GetFileNameWithoutExtension($ZipPath) }

# Changelog
if (-not $Changelog) {
    $changelogPath = Join-Path $RepoRoot "CHANGELOG_RELEASE.md"
    if (Test-Path -LiteralPath $changelogPath) {
        $Changelog = Get-Content -LiteralPath $changelogPath -Raw
    } else {
        $Changelog = "Release $DisplayName"
    }
}

# Resolve game version IDs
$apiBase = "https://wow.curseforge.com/api"
$headers = @{ "X-Api-Token" = $token }

Write-Host "[cf-upload] Fetching game version list..."
$allVersions = Invoke-RestMethod -Uri "$apiBase/game/versions" -Headers $headers -Method Get

$gameVersionIds = @()
if ($config.gameVersionIds) {
    $gameVersionIds = @($config.gameVersionIds | ForEach-Object { [int]$_ })
}
elseif ($config.gameVersions) {
    foreach ($v in $config.gameVersions) {
        $match = $allVersions | Where-Object { $_.name -eq $v -or $_.slug -eq $v } | Select-Object -First 1
        if (-not $match) { throw "gameVersion '$v' not found in CurseForge API list." }
        $gameVersionIds += [int]$match.id
    }
}
else {
    throw "Neither gameVersions nor gameVersionIds set in .curseforge.json."
}

$metadata = @{
    changelog     = $Changelog
    changelogType = $ChangelogType
    displayName   = $DisplayName
    gameVersions  = $gameVersionIds
    releaseType   = $ReleaseType
}

Write-Host "[cf-upload] Metadata:" -ForegroundColor Cyan
$metadata | ConvertTo-Json -Depth 5 | Write-Host

if ($DryRun) {
    Write-Host "[cf-upload] DryRun: not uploading." -ForegroundColor Yellow
    return
}

# Multipart upload
$metadataJson = $metadata | ConvertTo-Json -Depth 5 -Compress
$uploadUri = "$apiBase/projects/$projectId/upload-file"

# Use HttpClient for reliable multipart
Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.Add("X-Api-Token", $token)

$form = [System.Net.Http.MultipartFormDataContent]::new()
$metaContent = [System.Net.Http.StringContent]::new($metadataJson)
$form.Add($metaContent, "metadata")

$fileStream = [System.IO.File]::OpenRead($ZipPath)
try {
    $fileContent = [System.Net.Http.StreamContent]::new($fileStream)
    $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/zip")
    $form.Add($fileContent, "file", [IO.Path]::GetFileName($ZipPath))

    $response = $client.PostAsync($uploadUri, $form).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        throw ("CurseForge upload failed ({0}): {1}" -f [int]$response.StatusCode, $body)
    }
    Write-Host ("[cf-upload] Success. Response: {0}" -f $body) -ForegroundColor Green
    return ($body | ConvertFrom-Json)
}
finally {
    $fileStream.Dispose()
    $client.Dispose()
}
