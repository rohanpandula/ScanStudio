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

# GitHub Actions Windows runners do not set $HOME (they use $USERPROFILE). The
# Rust engine's preview tests expect a home directory via the HOME env var;
# mirror the user profile so those tests run (runner-env fix, nothing else
# depends on HOME from this point).
if ($env:HOME -eq $null) {
    $env:HOME = $env:USERPROFILE
}

$portRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$appRoot = Join-Path $portRoot 'app'
$stagingRoot = Join-Path $portRoot 'packaging\.staging\windows'
$verifier = Join-Path $PSScriptRoot 'verify-bundle.ps1'
$launcherBlackBox = Join-Path $PSScriptRoot 'tests\test-hardware-session-launcher.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

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

function Copy-VerifiedOutputNoClobber {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Verified release source is missing: $Source"
    }

    $sourceStream = $null
    $destinationStream = $null
    $destinationCreated = $false
    $copyError = $null
    try {
        $sourceStream = [IO.File]::Open(
            $Source,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $destinationStream = [IO.File]::Open(
            $Destination,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $destinationCreated = $true
        $sourceStream.CopyTo($destinationStream)
        $destinationStream.Flush($true)
    }
    catch {
        $copyError = $_
    }
    finally {
        if ($null -ne $destinationStream) {
            $destinationStream.Dispose()
        }
        if ($null -ne $sourceStream) {
            $sourceStream.Dispose()
        }
    }

    if ($null -ne $copyError) {
        if ($destinationCreated -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            Remove-Item -LiteralPath $Destination -Force
        }
        throw $copyError
    }

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash
    $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
    if ($sourceHash -cne $destinationHash) {
        Remove-Item -LiteralPath $Destination -Force
        throw "Published release output failed its SHA-256 comparison: $Destination"
    }
}

function Publish-VerifiedOutputs {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerSource,
        [Parameter(Mandatory = $true)][string]$PortableSource
    )

    $publishedByThisRun = [Collections.Generic.List[string]]::new()
    try {
        Copy-VerifiedOutputNoClobber -Source $InstallerSource -Destination $installerOutput
        $publishedByThisRun.Add($installerOutput)
        Copy-VerifiedOutputNoClobber -Source $PortableSource -Destination $portableOutput
        $publishedByThisRun.Add($portableOutput)
    }
    catch {
        foreach ($publishedPath in $publishedByThisRun) {
            Remove-Item -LiteralPath $publishedPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-ScanStudioProductRegistryEntries {
    foreach ($softwareRoot in @(
        'Registry::HKEY_CURRENT_USER\Software',
        'Registry::HKEY_CURRENT_USER\Software\WOW6432Node'
    )) {
        if (-not (Test-Path -LiteralPath $softwareRoot)) {
            continue
        }
        foreach ($manufacturerKey in (Get-ChildItem -LiteralPath $softwareRoot -ErrorAction SilentlyContinue)) {
            $productKeyPath = Join-Path $manufacturerKey.PSPath 'ScanStudio'
            if (-not (Test-Path -LiteralPath $productKeyPath)) {
                continue
            }
            $productKey = $null
            try {
                $productKey = Get-Item -LiteralPath $productKeyPath -ErrorAction Stop
                [pscustomobject]@{
                    Path = $productKeyPath
                    InstallLocation = [string]$productKey.GetValue('')
                    ValueNames = @($productKey.GetValueNames())
                }
            }
            finally {
                if ($null -ne $productKey) {
                    $productKey.Close()
                }
            }
        }
    }
}

function Test-SameFileSystemPath {
    param(
        [AllowEmptyString()][string]$Left,
        [AllowEmptyString()][string]$Right
    )

    if (-not $Left -or -not $Right) {
        return $false
    }
    try {
        $normalizedLeft = $Left.Trim().Trim([char]0x22)
        $normalizedRight = $Right.Trim().Trim([char]0x22)
        return [IO.Path]::GetFullPath($normalizedLeft) -ieq [IO.Path]::GetFullPath($normalizedRight)
    }
    catch {
        return $false
    }
}

function Test-RegistryValueExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $properties = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    return $null -ne $properties -and $null -ne $properties.PSObject.Properties[$Name]
}

function Assert-NoExistingScanStudioInstall {
    # Verification performs a real current-user NSIS install and uninstall.
    # Refuse to run where that round trip could overwrite a real copy's
    # shortcuts or uninstall registration.
    $conflicts = [Collections.Generic.List[string]]::new()
    $programs = [Environment]::GetFolderPath('Programs')
    $desktop = [Environment]::GetFolderPath('Desktop')
    $candidatePaths = @()
    if ($env:LOCALAPPDATA) {
        $candidatePaths += (Join-Path $env:LOCALAPPDATA 'ScanStudio')
    }
    if ($programs) {
        $candidatePaths += (Join-Path $programs 'ScanStudio.lnk')
        $candidatePaths += (Join-Path $programs 'ScanStudio Hardware Session.lnk')
    }
    if ($desktop) {
        $candidatePaths += (Join-Path $desktop 'ScanStudio.lnk')
    }
    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            $conflicts.Add($candidatePath)
        }
    }

    foreach ($process in @(Get-Process -Name 'scanstudio-app' -ErrorAction SilentlyContinue)) {
        $conflicts.Add("running scanstudio-app process PID $($process.Id)")
    }

    $runKey = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-RegistryValueExists -Path $runKey -Name 'ScanStudio') {
        $conflicts.Add("$runKey [value ScanStudio]")
    }

    # Tauri's NSIS template uses this fixed product-name uninstall key. Check
    # it directly instead of relying only on a mutable DisplayName value.
    foreach ($fixedRegistryPath in @(
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScanStudio',
        'Registry::HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\ScanStudio'
    )) {
        if (Test-Path -LiteralPath $fixedRegistryPath) {
            $conflicts.Add($fixedRegistryPath)
        }
    }

    # Tauri also stores the install directory at
    # HKCU\Software\<manufacturer>\ScanStudio. The manufacturer is generated
    # from bundle metadata, so scan exactly one level rather than guessing its
    # current value or recursing through arbitrary user registry state.
    foreach ($productEntry in @(Get-ScanStudioProductRegistryEntries)) {
        $conflicts.Add($productEntry.Path)
    }

    foreach ($uninstallRoot in @(
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $uninstallRoot)) {
            continue
        }
        foreach ($entry in (Get-ChildItem -LiteralPath $uninstallRoot -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $properties -and
                $null -ne $properties.PSObject.Properties['DisplayName'] -and
                $properties.DisplayName -eq 'ScanStudio') {
                $conflicts.Add($entry.PSPath)
            }
        }
    }

    if ($conflicts.Count -gt 0) {
        $details = $conflicts -join [Environment]::NewLine
        throw "Package verification requires a clean Windows account or VM; an existing ScanStudio install would be modified by the temporary NSIS round trip:$([Environment]::NewLine)$details"
    }
}

Assert-NoExistingScanStudioInstall

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

function Get-MainExecutable {
    param([Parameter(Mandatory = $true)][string]$Tree)

    $executables = @(Get-ChildItem -LiteralPath $Tree -Recurse -File -Filter 'scanstudio-app.exe')
    if ($executables.Count -ne 1) {
        throw "Expected exactly one ScanStudio executable under $Tree, found $($executables.Count): $executables"
    }
    return $executables[0]
}

function Assert-HardwareSessionLauncherLayout {
    param([Parameter(Mandatory = $true)][string]$Tree)

    $mainExecutable = Get-MainExecutable -Tree $Tree
    foreach ($fileName in @(
        'Start-ScanStudio-Hardware-Session.cmd',
        'Start-ScanStudio-Hardware-Session.ps1',
        'scanstudio-hardware-session-latch.sh'
    )) {
        $expectedPath = Join-Path $mainExecutable.Directory.FullName $fileName
        if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
            throw "Hardware-session file must be beside scanstudio-app.exe: $expectedPath"
        }
    }
    return $mainExecutable
}

function Invoke-HardwareSessionLauncherBlackBox {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell 5.1 is missing: $windowsPowerShell"
    }
    & $windowsPowerShell `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $launcherBlackBox `
        -LauncherRoot $Root
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell launcher black-box suite failed with exit code $LASTEXITCODE for $Root"
    }
}

function Assert-HardwareSessionShortcut {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$MainExecutable)

    $shortcutPath = Join-Path `
        ([Environment]::GetFolderPath('Programs')) `
        'ScanStudio Hardware Session.lnk'
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        throw "Installed hardware-session shortcut is missing: $shortcutPath"
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $expectedTarget = Join-Path $MainExecutable.Directory.FullName 'Start-ScanStudio-Hardware-Session.cmd'
        if ([IO.Path]::GetFullPath($shortcut.TargetPath) -ine [IO.Path]::GetFullPath($expectedTarget)) {
            throw "Hardware-session shortcut target is '$($shortcut.TargetPath)', expected '$expectedTarget'"
        }
        $expectedIcon = $MainExecutable.FullName + ',0'
        if ($shortcut.IconLocation -ine $expectedIcon) {
            throw "Hardware-session shortcut icon is '$($shortcut.IconLocation)', expected '$expectedIcon'"
        }
    }
    finally {
        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
    return $shortcutPath
}

function Assert-TemporaryUninstallOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$Uninstaller,
        [AllowEmptyString()][string]$ExpectedProductRegistryPath = ''
    )

    foreach ($process in @(Get-Process -Name 'scanstudio-app' -ErrorAction SilentlyContinue)) {
        throw "Refusing temporary uninstall while scanstudio-app is running (PID $($process.Id))."
    }
    $runKey = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-RegistryValueExists -Path $runKey -Name 'ScanStudio') {
        throw "Refusing temporary uninstall because $runKey contains a ScanStudio value."
    }

    $productEntries = @(Get-OwnedTemporaryProductRegistryEntries -InstallRoot $Tree)
    if ($productEntries.Count -ne 1) {
        throw "Expected one owned ScanStudio product key before temporary uninstall, found $($productEntries.Count): $($productEntries.Path)"
    }
    if ($ExpectedProductRegistryPath -and
        $productEntries[0].Path -ine $ExpectedProductRegistryPath) {
        throw "Temporary ScanStudio product key moved from '$ExpectedProductRegistryPath' to '$($productEntries[0].Path)'; refusing uninstall."
    }

    $registrations = @(
        foreach ($registrationPath in @(
            'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScanStudio',
            'Registry::HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\ScanStudio'
        )) {
            if (Test-Path -LiteralPath $registrationPath) {
                $properties = Get-ItemProperty -LiteralPath $registrationPath -ErrorAction Stop
                [pscustomobject]@{
                    Path = $registrationPath
                    DisplayName = [string]$properties.DisplayName
                    InstallLocation = [string]$properties.InstallLocation
                    UninstallString = [string]$properties.UninstallString
                }
            }
        }
    )
    if ($registrations.Count -ne 1) {
        throw "Expected one current-user ScanStudio uninstall registration, found $($registrations.Count): $($registrations.Path)"
    }
    $registration = $registrations[0]
    if ($registration.DisplayName -ne 'ScanStudio' -or
        -not (Test-SameFileSystemPath -Left $registration.InstallLocation -Right $Tree) -or
        -not (Test-SameFileSystemPath -Left $registration.UninstallString -Right $Uninstaller.FullName)) {
        throw "Temporary ScanStudio uninstall registration no longer names the exact owned install; refusing uninstall: $($registration.Path)"
    }
}

function Invoke-TemporaryUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$Tree,
        [AllowEmptyString()][string]$ExpectedProductRegistryPath = ''
    )

    $uninstallers = @(
        Get-ChildItem -LiteralPath $Tree -Recurse -File |
            Where-Object { $_.Name -match '^uninstall.*\.exe$' }
    )
    if ($uninstallers.Count -ne 1) {
        throw "Expected exactly one temporary uninstaller under $Tree, found $($uninstallers.Count): $uninstallers"
    }
    Assert-TemporaryUninstallOwnership `
        -Tree $Tree `
        -Uninstaller $uninstallers[0] `
        -ExpectedProductRegistryPath $ExpectedProductRegistryPath
    $uninstallerProcess = Start-Process `
        -FilePath $uninstallers[0].FullName `
        -ArgumentList '/S' `
        -Wait `
        -PassThru
    if ($uninstallerProcess.ExitCode -ne 0) {
        throw "NSIS silent uninstall exited $($uninstallerProcess.ExitCode)"
    }
}

function Get-OwnedTemporaryProductRegistryEntries {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    return @(
        Get-ScanStudioProductRegistryEntries |
            Where-Object {
                Test-SameFileSystemPath -Left $_.InstallLocation -Right $InstallRoot
            }
    )
}

function Remove-OwnedTemporaryProductRegistryKey {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowEmptyString()][string]$ExpectedPath = ''
    )

    $matches = @(Get-OwnedTemporaryProductRegistryEntries -InstallRoot $InstallRoot)
    if ($matches.Count -eq 0) {
        return
    }
    if ($matches.Count -ne 1) {
        throw "Expected one temporary ScanStudio product registry key for $InstallRoot, found $($matches.Count): $($matches.Path)"
    }
    $registryPath = $matches[0].Path
    if ($ExpectedPath -and $registryPath -ine $ExpectedPath) {
        throw "Temporary ScanStudio product registry key moved from '$ExpectedPath' to '$registryPath'; refusing cleanup."
    }

    $registryKey = $null
    try {
        $registryKey = Get-Item -LiteralPath $registryPath -ErrorAction Stop
        $actualInstallLocation = [string]$registryKey.GetValue('')
        $valueNames = @($registryKey.GetValueNames())
    }
    finally {
        if ($null -ne $registryKey) {
            $registryKey.Close()
        }
    }
    if (-not (Test-SameFileSystemPath -Left $actualInstallLocation -Right $InstallRoot)) {
        throw "Temporary ScanStudio product key no longer names the owned install root; refusing cleanup: $registryPath"
    }
    $unexpectedValues = @($valueNames | Where-Object { $_ -notin @('', 'Installer Language') })
    $subkeys = @(Get-ChildItem -LiteralPath $registryPath -ErrorAction SilentlyContinue)
    if ($unexpectedValues.Count -gt 0 -or $subkeys.Count -gt 0) {
        throw "Temporary ScanStudio product key contains unexpected state; refusing cleanup: $registryPath"
    }

    Remove-Item -LiteralPath $registryPath -Force
    if (Test-Path -LiteralPath $registryPath) {
        throw "Temporary ScanStudio product registry key survived cleanup: $registryPath"
    }
}

function Assert-TemporaryInstallUserStateRemoved {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $leftovers = [Collections.Generic.List[string]]::new()
    $cleanupPaths = @(
        $InstallRoot,
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScanStudio',
        'Registry::HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\ScanStudio'
    )
    $programs = [Environment]::GetFolderPath('Programs')
    if ($programs) {
        $cleanupPaths += (Join-Path $programs 'ScanStudio.lnk')
        $cleanupPaths += (Join-Path $programs 'ScanStudio Hardware Session.lnk')
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) {
        $cleanupPaths += (Join-Path $desktop 'ScanStudio.lnk')
    }
    foreach ($path in $cleanupPaths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $leftovers.Add($path)
        }
    }
    $runKey = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-RegistryValueExists -Path $runKey -Name 'ScanStudio') {
        $leftovers.Add("$runKey [value ScanStudio]")
    }
    foreach ($productEntry in @(Get-ScanStudioProductRegistryEntries)) {
        $leftovers.Add($productEntry.Path)
    }
    foreach ($process in @(Get-Process -Name 'scanstudio-app' -ErrorAction SilentlyContinue)) {
        $leftovers.Add("running scanstudio-app process PID $($process.Id)")
    }
    if ($leftovers.Count -gt 0) {
        throw "Temporary NSIS verification left current-user state behind:$([Environment]::NewLine)$($leftovers -join [Environment]::NewLine)"
    }
}

function Assert-HardwareSessionLauncherSyntax {
    param([Parameter(Mandatory = $true)][string]$Root)

    $launcher = Join-Path $Root 'Start-ScanStudio-Hardware-Session.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Hardware-session launcher is missing: $launcher"
    }
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $launcher,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "Hardware-session launcher PowerShell parse failed: $messages"
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
Assert-HardwareSessionLauncherSyntax -Root $stagingRoot
Invoke-HardwareSessionLauncherBlackBox -Root $PSScriptRoot

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
$portableCandidate = Join-Path $temporaryRoot 'verified-portable.zip'
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
$temporaryInstallRemoved = $false
$installerMayHaveModifiedUserState = $false
$temporaryUserStateRemoved = $false
$hardwareShortcutPath = $null
$temporaryProductRegistryPath = ''

try {
    # The build above is intentionally long. Repeat the clean-account gate at
    # the last possible point so state created during compilation is never
    # handed to the real NSIS installer.
    Assert-NoExistingScanStudioInstall
    $installerMayHaveModifiedUserState = $true
    $installerProcess = Start-Process -FilePath $installers[0].FullName -ArgumentList @('/S', "/D=$installRoot") -Wait -PassThru
    if ($installerProcess.ExitCode -ne 0) {
        throw "NSIS silent install exited $($installerProcess.ExitCode)"
    }
    if (-not (Test-Path $installRoot -PathType Container)) {
        throw "NSIS installer did not create the requested install directory: $installRoot"
    }
    $temporaryProductEntries = @(Get-OwnedTemporaryProductRegistryEntries -InstallRoot $installRoot)
    if ($temporaryProductEntries.Count -ne 1) {
        throw "Expected one temporary ScanStudio product registry key for $installRoot, found $($temporaryProductEntries.Count): $($temporaryProductEntries.Path)"
    }
    $temporaryProductRegistryPath = $temporaryProductEntries[0].Path

    $installedBundleRoot = Find-BundleRoot -Tree $installRoot
    Invoke-BundleVerifier -Root $installedBundleRoot
    Assert-HardwareSessionLauncherSyntax -Root $installedBundleRoot
    Assert-MainExecutable -Tree $installRoot
    $installedMainExecutable = Assert-HardwareSessionLauncherLayout -Tree $installRoot
    $hardwareShortcutPath = Assert-HardwareSessionShortcut -MainExecutable $installedMainExecutable
    Invoke-HardwareSessionLauncherBlackBox -Root $installedMainExecutable.Directory.FullName
    Invoke-EngineSmoke -Tree $installRoot

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $installRoot,
        $portableCandidate,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    [System.IO.Compression.ZipFile]::ExtractToDirectory($portableCandidate, $portableExtract)
    $portableBundleRoot = Find-BundleRoot -Tree $portableExtract
    Invoke-BundleVerifier -Root $portableBundleRoot
    Assert-HardwareSessionLauncherSyntax -Root $portableBundleRoot
    Assert-MainExecutable -Tree $portableExtract
    $portableMainExecutable = Assert-HardwareSessionLauncherLayout -Tree $portableExtract
    Invoke-HardwareSessionLauncherBlackBox -Root $portableMainExecutable.Directory.FullName
    Invoke-EngineSmoke -Tree $portableExtract

    Invoke-TemporaryUninstall `
        -Tree $installRoot `
        -ExpectedProductRegistryPath $temporaryProductRegistryPath
    $temporaryInstallRemoved = $true
    Remove-OwnedTemporaryProductRegistryKey `
        -InstallRoot $installRoot `
        -ExpectedPath $temporaryProductRegistryPath
    if ($hardwareShortcutPath -and (Test-Path -LiteralPath $hardwareShortcutPath)) {
        throw "Temporary uninstall left the hardware-session shortcut behind: $hardwareShortcutPath"
    }
    Assert-TemporaryInstallUserStateRemoved -InstallRoot $installRoot
    $temporaryUserStateRemoved = $true

    # Release-named artifacts appear only after installed/portable verification
    # and the destructive NSIS round trip have both completed cleanly. Each
    # destination uses create-new semantics, and a partial pair is rolled back.
    Publish-VerifiedOutputs `
        -InstallerSource $installers[0].FullName `
        -PortableSource $portableCandidate
}
finally {
    if ($installerMayHaveModifiedUserState -and
        -not $temporaryInstallRemoved -and
        (Test-Path -LiteralPath $installRoot)) {
        try {
            Invoke-TemporaryUninstall `
                -Tree $installRoot `
                -ExpectedProductRegistryPath $temporaryProductRegistryPath
            $temporaryInstallRemoved = $true
        }
        catch {
            Write-Warning "Could not run temporary package uninstaller during cleanup: $($_.Exception.Message)"
        }
    }
    if ($temporaryInstallRemoved -and -not $temporaryUserStateRemoved) {
        try {
            Remove-OwnedTemporaryProductRegistryKey `
                -InstallRoot $installRoot `
                -ExpectedPath $temporaryProductRegistryPath
            Assert-TemporaryInstallUserStateRemoved -InstallRoot $installRoot
            $temporaryUserStateRemoved = $true
        }
        catch {
            Write-Warning "Temporary package user-state cleanup was incomplete: $($_.Exception.Message)"
        }
    }
    if ((-not $installerMayHaveModifiedUserState -or $temporaryUserStateRemoved) -and
        (Test-Path $temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    elseif (Test-Path $temporaryRoot) {
        Write-Warning "Preserving the temporary install tree because user-state cleanup could not be proven: $temporaryRoot"
    }
}

Get-FileHash -Algorithm SHA256 -Path $installerOutput, $portableOutput |
    Select-Object Hash, Path |
    Format-Table -AutoSize
