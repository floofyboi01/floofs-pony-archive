<#
.SYNOPSIS
    Packages and sideloads Floof's Pony Archive to a Roku in developer mode.

.EXAMPLE
    .\deploy.ps1 -RokuIp 192.168.1.42 -Password rokudev

.EXAMPLE
    # Zip only, don't upload
    .\deploy.ps1 -PackageOnly

.NOTES
    The Roku dev server uses HTTP digest auth, which Invoke-WebRequest cannot
    do against Roku's implementation, so curl.exe (bundled with Windows 10+)
    does the upload.
#>
[CmdletBinding()]
param(
    [string] $RokuIp,
    [string] $Password = "rokudev",
    [switch] $PackageOnly,
    [switch] $Launch,
    [string] $ContentId
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$zipPath = Join-Path $root "dist\pony-archive.zip"

#-------------------------------------------------------------------
# 1. Sanity check the project layout
#-------------------------------------------------------------------

$required = @(
    "manifest",
    "source\main.brs",
    "source\Util.brs",
    "components\MainScene.xml",
    "components\MainScene.brs",
    "components\DbTask.xml",
    "components\DbTask.brs",
    "components\SubtitleTask.xml",
    "components\SubtitleTask.brs"
)

foreach ($rel in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $rel))) {
        throw "Missing required file: $rel"
    }
}

# Every image referenced by the manifest must exist, or the Roku rejects the zip.
$manifestText = Get-Content -LiteralPath (Join-Path $root "manifest") -Raw
$imageRefs = [regex]::Matches($manifestText, 'pkg:/([^\s=]+\.png)') |
    ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique

$missingImages = @()
foreach ($ref in $imageRefs) {
    $local = Join-Path $root ($ref -replace '/', '\')
    if (-not (Test-Path -LiteralPath $local)) { $missingImages += $ref }
}
if ($missingImages.Count -gt 0) {
    Write-Host "Missing images referenced by manifest:" -ForegroundColor Yellow
    $missingImages | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host "Generating them now..." -ForegroundColor Cyan
    & node (Join-Path $root "tools\make-images.js")
    if ($LASTEXITCODE -ne 0) { throw "Image generation failed." }
}

#-------------------------------------------------------------------
# 2. Build the zip
#-------------------------------------------------------------------

$distDir = Join-Path $root "dist"
if (-not (Test-Path -LiteralPath $distDir)) {
    New-Item -ItemType Directory -Path $distDir | Out-Null
}
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

# Collect the channel payload. The manifest must sit at the zip root, so we
# never zip the project directory itself.
$payload = @()
$payload += [pscustomobject]@{ Path = (Join-Path $root "manifest"); Entry = "manifest" }

foreach ($dir in @("source", "components", "images")) {
    $src = Join-Path $root $dir
    if (-not (Test-Path -LiteralPath $src)) { continue }
    Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
        $payload += [pscustomobject]@{
            Path  = $_.FullName
            # ZIP requires forward slashes (APPNOTE 4.4.17.1). .NET's
            # CreateFromDirectory emits backslashes on Windows, which Roku's
            # unzip turns into literal filenames and the channel then fails
            # to find its components. Write entry names by hand instead.
            Entry = ($rel -replace '\\', '/')
        }
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
try {
    $archive = New-Object System.IO.Compression.ZipArchive(
        $stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($item in $payload) {
            $entry = $archive.CreateEntry($item.Entry,
                [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($item.Path)
                $entryStream.Write($bytes, 0, $bytes.Length)
            }
            finally { $entryStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}
finally { $stream.Dispose() }

$sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
Write-Host "Built $zipPath ($sizeKb KB)" -ForegroundColor Green

if ($PackageOnly) { return }

#-------------------------------------------------------------------
# 3. Upload
#-------------------------------------------------------------------

if (-not $RokuIp) {
    throw "No -RokuIp supplied. Re-run with -RokuIp <address>, or use -PackageOnly."
}

# Fail fast with a clear message if the dev server isn't listening.
Write-Host "Checking dev server at $RokuIp ..." -ForegroundColor Cyan
$probe = curl.exe -s -o $null -w "%{http_code}" --max-time 8 "http://$RokuIp/" 2>$null
if ($probe -notmatch '^(200|401)$') {
    throw @"
No Roku developer web server answered at http://$RokuIp/ (got '$probe').

Check that:
  * the IP is correct (Settings > Network > About on the Roku)
  * developer mode is enabled and the device has rebooted since
  * the PC and the Roku are on the same network/VLAN
"@
}

Write-Host "Uploading channel ..." -ForegroundColor Cyan
$response = curl.exe -s --max-time 180 `
    --digest -u "rokudev:$Password" `
    -F "mysubmit=Install" `
    -F "archive=@$zipPath" `
    -F "passwd=" `
    "http://$RokuIp/plugin_install"

if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }

if ($response -match "Identical to previous version") {
    Write-Host "Roku reports the package is identical to what is already installed." -ForegroundColor Yellow
}
elseif ($response -match "Install Success|Application Received|Received, running install") {
    Write-Host "Install succeeded." -ForegroundColor Green
}
elseif ($response -match "Failed to create package|compile|error|Error") {
    Write-Host "Install reported a problem:" -ForegroundColor Red
    # Surface just the readable part of Roku's HTML response.
    $plain = ($response -replace '<[^>]+>', ' ') -replace '\s{2,}', ' '
    Write-Host $plain.Trim() -ForegroundColor Red
    Write-Host "`nFull compiler output: telnet $RokuIp 8085" -ForegroundColor Yellow
    exit 1
}
else {
    $plain = ($response -replace '<[^>]+>', ' ') -replace '\s{2,}', ' '
    Write-Host "Unexpected response: $($plain.Trim())" -ForegroundColor Yellow
}

#-------------------------------------------------------------------
# 4. Optionally launch
#-------------------------------------------------------------------

if ($Launch) {
    $launchUrl = "http://${RokuIp}:8060/launch/dev"
    if ($ContentId) { $launchUrl += "?contentId=$ContentId" }
    Write-Host "Launching: $launchUrl" -ForegroundColor Cyan
    curl.exe -s -d "" $launchUrl | Out-Null
}

Write-Host "`nLive BrightScript log:  telnet $RokuIp 8085" -ForegroundColor DarkGray
