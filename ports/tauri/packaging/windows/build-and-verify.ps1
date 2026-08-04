[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?$')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$portRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$appRoot = Join-Path $portRoot 'app'
$stagingRoot = Join-Path $portRoot 'packaging\.staging\windows'
$verifier = Join-Path $PSScriptRoot 'verify-bundle.ps1'

if (-not (Test-Path $stagingRoot -PathType Container)) {
    throw "Windows staging is missing: $stagingRoot"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
$installerOutput = Join-Path $OutputDir "ScanStudio-$Version-Windows-x86_64-preview-setup.exe"
$portableOutput = Join-Path $OutputDir "ScanStudio-$Version-Windows-x86_64-preview-portable.zip"
foreach ($path in @($installerOutput, $portableOutput)) {
    if (Test-Path $path) {
        throw "Refusing to overwrite release output: $path"
    }
}

function Find-BundleRoot {
    param([Parameter(Mandatory = $true)][string]$Tree)

    $matches = @(
        Get-ChildItem -LiteralPath $Tree -Recurse -File -Filter 'provenance.json' |
            Where-Object {
                $directory = $_.Directory.FullName
                (Test-Path (Join-Path $directory 'Licenses') -PathType Container) -and
                (Test-Path (Join-Path $directory 'CorrespondingSource') -PathType Container)
            } |
            ForEach-Object { $_.Directory.FullName }
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one bundled resource root under $Tree, found $($matches.Count): $matches"
    }
    return $matches[0]
}

function Invoke-BundleVerifier {
    param([Parameter(Mandatory = $true)][string]$Root)

    & pwsh -NoProfile -NonInteractive -File $verifier -Root $Root
    if ($LASTEXITCODE -ne 0) {
        throw "Windows resource verifier failed with exit code $LASTEXITCODE"
    }
}

function Assert-MainExecutable {
    param([Parameter(Mandatory = $true)][string]$Tree)

    $executables = @(Get-ChildItem -LiteralPath $Tree -Recurse -File -Filter 'scanstudio-app.exe')
    if ($executables.Count -ne 1) {
        throw "Expected exactly one ScanStudio executable under $Tree, found $($executables.Count): $executables"
    }
}

function Invoke-EngineSmoke {
    param([Parameter(Mandatory = $true)][string]$Tree)

    $engines = @(
        Get-ChildItem -LiteralPath $Tree -Recurse -File |
            Where-Object { $_.Name -like 'scanstudio-engine*.exe' }
    )
    if ($engines.Count -ne 1) {
        throw "Expected exactly one engine sidecar under $Tree, found $($engines.Count): $engines"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $engines[0].FullName
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment.Remove('SCANSTUDIO_BRIDGE_CMD')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start engine sidecar: $($engines[0].FullName)"
    }

    @(
        '{"id":1,"method":"engine.hello","params":{"clientName":"package-smoke","protocolVersion":1}}',
        '{"id":2,"method":"scanner.list","params":{}}',
        '{"id":3,"method":"engine.shutdown","params":{}}'
    ) | ForEach-Object { $process.StandardInput.WriteLine($_) }
    $process.StandardInput.Close()

    if (-not $process.WaitForExit(15000)) {
        $process.Kill($true)
        throw 'Engine sidecar did not exit after engine.shutdown'
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0) {
        throw "Engine sidecar exited $($process.ExitCode): $stderr"
    }

    $responses = @(
        $stdout -split '\r?\n' |
            Where-Object { $_.Trim() } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    foreach ($id in 1, 2, 3) {
        $response = @($responses | Where-Object { $_.id -eq $id })
        if ($response.Count -ne 1 -or $null -ne $response[0].error) {
            throw "Engine smoke did not return one successful response for id $id`: $stdout"
        }
    }
    $hello = @($responses | Where-Object { $_.id -eq 1 })[0]
    if ($hello.result.engineName -ne 'scanstudio-engine' -or $hello.result.protocolVersion -ne 1) {
        throw "Engine hello response was invalid: $($hello | ConvertTo-Json -Compress -Depth 10)"
    }
    $list = @($responses | Where-Object { $_.id -eq 2 })[0]
    if ($null -eq $list.result.devices) {
        throw "Engine scanner.list response was invalid: $($list | ConvertTo-Json -Compress -Depth 10)"
    }
}

Invoke-BundleVerifier -Root $stagingRoot

$buildConfig = Join-Path ([System.IO.Path]::GetTempPath()) ("scanstudio-tauri-version-" + [guid]::NewGuid().ToString('N') + '.json')
@{ version = $Version } | ConvertTo-Json -Compress | Set-Content -LiteralPath $buildConfig -Encoding utf8NoBOM -NoNewline

Push-Location $appRoot
try {
    npm ci
    npm run sync-engine
    npm test
    npx tsc --noEmit
    npm run build
    cargo test --locked --manifest-path src-tauri\Cargo.toml
    npm run tauri -- build --ci --bundles nsis --config $buildConfig -- --locked
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $buildConfig -Force -ErrorAction SilentlyContinue
}

$installers = @(Get-ChildItem -Path (Join-Path $appRoot 'src-tauri\target\release\bundle\nsis') -File -Filter '*-setup.exe')
if ($installers.Count -ne 1) {
    throw "Expected exactly one NSIS installer, found $($installers.Count): $installers"
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("scanstudio-windows-package-" + [guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $temporaryRoot 'installed'
$portableExtract = Join-Path $temporaryRoot 'portable-extract'
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null

try {
    $installerProcess = Start-Process -FilePath $installers[0].FullName -ArgumentList @('/S', "/D=$installRoot") -Wait -PassThru
    if ($installerProcess.ExitCode -ne 0) {
        throw "NSIS silent install exited $($installerProcess.ExitCode)"
    }
    if (-not (Test-Path $installRoot -PathType Container)) {
        throw "NSIS installer did not create the requested install directory: $installRoot"
    }

    $installedBundleRoot = Find-BundleRoot -Tree $installRoot
    Invoke-BundleVerifier -Root $installedBundleRoot
    Assert-MainExecutable -Tree $installRoot
    Invoke-EngineSmoke -Tree $installRoot

    Copy-Item -LiteralPath $installers[0].FullName -Destination $installerOutput
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $installRoot,
        $portableOutput,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    [System.IO.Compression.ZipFile]::ExtractToDirectory($portableOutput, $portableExtract)
    $portableBundleRoot = Find-BundleRoot -Tree $portableExtract
    Invoke-BundleVerifier -Root $portableBundleRoot
    Assert-MainExecutable -Tree $portableExtract
    Invoke-EngineSmoke -Tree $portableExtract
}
finally {
    if (Test-Path $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Get-FileHash -Algorithm SHA256 -Path $installerOutput, $portableOutput |
    Select-Object Hash, Path |
    Format-Table -AutoSize
