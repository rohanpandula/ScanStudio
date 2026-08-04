<#
.SYNOPSIS
    Offline bundle verifier for the Windows staging tree (Windows-native twin
    of packaging/windows/verify-bundle.sh). Asserts the shared GPL / path
    guarantees from packaging/license-manifest.json against an assembled
    bundle root. Pure layout checks - runnable on a windows-latest CI runner
    against the staging tree or the extracted installer payload.

.PARAMETER Root
    Absolute path to the assembled Windows bundle root to verify.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Root
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Root -PathType Container)) {
    Write-Error "bundle root does not exist: $Root"
    exit 64
}

$manifestPath = Join-Path $PSScriptRoot '..\license-manifest.json'
if (-not (Test-Path $manifestPath)) {
    Write-Error "license manifest not found: $manifestPath"
    exit 64
}
$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json

$failures = 0

# 1) sharedRequiredPaths + perPlatform.windows.additionalRequiredPaths.
$required = @($manifest.sharedRequiredPaths) + @($manifest.perPlatform.windows.additionalRequiredPaths)
foreach ($entry in $required) {
    if (Test-Path (Join-Path $Root $entry)) {
        Write-Host "PASS  $entry"
    }
    else {
        Write-Host "FAIL  $entry" -ForegroundColor Red
        $failures += 1
    }
}

# 2) verify the exact checksummed dependency-notice corpus and npm closure.
$noticeVerifier = Join-Path $PSScriptRoot '..\lib\verify_dependency_notices.py'
& python $noticeVerifier $Root
if ($LASTEXITCODE -ne 0) {
    Write-Host 'FAIL  dependency notice verification' -ForegroundColor Red
    $failures += 1
}

# 3) pinned offline requirements and local-source installer semantics.
$requirementsPath = Join-Path $Root 'wsl-requirements.txt'
$requirementsText = if (Test-Path $requirementsPath -PathType Leaf) {
    Get-Content -Raw -Path $requirementsPath
} else { '' }
$pins = @(
    'setuptools==83.0.0',
    'numpy==2.5.1',
    'tifffile==2026.7.31',
    'imagecodecs==2026.6.26',
    'opencv-python-headless==4.14.0.94',
    'pyusb==1.3.1',
    'jinja2==3.1.6',
    'MarkupSafe==3.0.3',
    'python-sane==2.9.2'
)
foreach ($pin in $pins) {
    if ($requirementsText.Contains("$pin --hash=sha256:")) {
        Write-Host "PASS  pinned offline requirement $pin"
    }
    else {
        Write-Host "FAIL  pinned offline requirement $pin" -ForegroundColor Red
        $failures += 1
    }
}

$installerPath = Join-Path $Root 'install-bridge-wsl.sh'
$installerText = if (Test-Path $installerPath -PathType Leaf) {
    Get-Content -Raw -Path $installerPath
} else { '' }
if ($installerText.Contains('--no-index') -and $installerText.Contains('--no-deps')) {
    Write-Host 'PASS  WSL installer disables remote/local dependency resolution'
}
else {
    Write-Host 'FAIL  WSL installer must use --no-index and --no-deps' -ForegroundColor Red
    $failures += 1
}
$coolscanOffset = $installerText.IndexOf('Installing CoolscanPy from shipped')
$bridgeOffset = $installerText.IndexOf('Installing scanstudio-bridge from shipped')
if ($coolscanOffset -ge 0 -and $bridgeOffset -gt $coolscanOffset) {
    Write-Host 'PASS  CoolscanPy local install precedes bridge local install'
}
else {
    Write-Host 'FAIL  CoolscanPy must install before scanstudio-bridge' -ForegroundColor Red
    $failures += 1
}

$checksumPath = Join-Path $Root 'Wheelhouse\SHA256SUMS'
if (Test-Path $checksumPath -PathType Leaf) {
    foreach ($line in Get-Content -Path $checksumPath) {
        $parts = $line -split '\s{2,}', 2
        $artifact = if ($parts.Count -eq 2) { $parts[1] } else { '' }
        if (-not $artifact -or -not (Test-Path (Join-Path $Root "Wheelhouse\$artifact") -PathType Leaf)) {
            Write-Host "FAIL  wheelhouse checksum entry has no artifact: $artifact" -ForegroundColor Red
            $failures += 1
        }
    }
    Write-Host 'PASS  wheelhouse checksum ledger resolves locally'
}

# 4) no file under -Root may contain any forbidden developer-path substring.
foreach ($substring in @($manifest.forbiddenPathSubstrings)) {
    $matches = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Select-String -SimpleMatch -Pattern $substring -List
    if ($matches) {
        Write-Host "FAIL  forbidden path substring '$substring' found in:" -ForegroundColor Red
        foreach ($m in $matches) { Write-Host "  $($m.Path)" -ForegroundColor Red }
        $failures += 1
    }
    else {
        Write-Host "PASS  no forbidden path substring '$substring'"
    }
}

if ($failures -gt 0) {
    Write-Host "verify-bundle: $failures check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host 'verify-bundle: all checks passed'
exit 0
