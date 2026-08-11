<#
.SYNOPSIS
    Starts one owner-attended ScanStudio hardware session.

.DESCRIPTION
    This launcher owns both Windows/WSL motion gates for exactly one child
    ScanStudio process. It asks for an explicit media name, atomically creates
    a token-owned WSL latch, gives SCANSTUDIO_HW_MOTION=1 only to the child,
    waits for that exact process, and removes only the latch it still owns.

    A normal Start-menu or Explorer launch remains unarmed. This script does
    not require elevation and does not write persistent environment settings.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$MediaName = '',

    [Parameter()]
    [string]$ScanStudioExe = '',

    [Parameter()]
    [switch]$Guardian,

    [Parameter()]
    [int]$OwnerProcessId = 0,

    [Parameter()]
    [long]$OwnerStartTimeUtcFileTime = 0,

    [Parameter()]
    [string]$GuardianSessionToken = '',

    [Parameter()]
    [string]$GuardianMediaNameBase64 = '',

    [Parameter()]
    [string]$GuardianReadyEventName = '',

    # Internal black-box-test seam. Production callers cannot redirect WSL
    # unless the isolated Windows test process explicitly opts in.
    [Parameter()]
    [string]$TestWslExe = '',

    [Parameter()]
    [string]$GuardianWslExe = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$DistroName = 'Ubuntu-24.04'
$LatchHelperName = 'scanstudio-hardware-session-latch.sh'
$MainExecutableName = 'scanstudio-app.exe'
$UnsafeProcessOverrideVariables = @(
    'SCANSTUDIO_HW_MOTION',
    'SCANSTUDIO_STATE_DIR',
    'SCANSTUDIO_BRIDGE_BASE_DIR'
)
$UnsafeWslenvVariables = @(
    'SCANSTUDIO_HW_MOTION',
    'SCANSTUDIO_STATE_DIR',
    'SCANSTUDIO_BRIDGE_BASE_DIR',
    'HOME'
)

function Get-SanitizedWslenv {
    param([AllowNull()][string]$Value)

    if (-not $Value) {
        return ''
    }
    $safeEntries = @(
        foreach ($entry in ($Value -split ':')) {
            if (-not $entry) {
                continue
            }
            $variableName = ($entry -split '/', 2)[0]
            $isUnsafe = @($UnsafeWslenvVariables | Where-Object {
                $_ -ieq $variableName
            }).Count -gt 0
            if (-not $isUnsafe) {
                $entry
            }
        }
    )
    return ($safeEntries -join ':')
}

function Clear-UnsafeProcessEnvironment {
    foreach ($variableName in $UnsafeProcessOverrideVariables) {
        [Environment]::SetEnvironmentVariable(
            $variableName,
            $null,
            [EnvironmentVariableTarget]::Process
        )
    }
    $currentWslenv = [Environment]::GetEnvironmentVariable(
        'WSLENV',
        [EnvironmentVariableTarget]::Process
    )
    $safeWslenv = Get-SanitizedWslenv -Value $currentWslenv
    $processWslenv = if ($safeWslenv) { $safeWslenv } else { $null }
    [Environment]::SetEnvironmentVariable(
        'WSLENV',
        $processWslenv,
        [EnvironmentVariableTarget]::Process
    )
}

function Set-SafeStartInfoEnvironment {
    param([Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo)

    foreach ($variableName in $UnsafeProcessOverrideVariables) {
        $StartInfo.EnvironmentVariables.Remove($variableName)
    }
    $safeWslenv = Get-SanitizedWslenv -Value $StartInfo.EnvironmentVariables['WSLENV']
    if ($safeWslenv) {
        $StartInfo.EnvironmentVariables['WSLENV'] = $safeWslenv
    }
    else {
        $StartInfo.EnvironmentVariables.Remove('WSLENV')
    }
}

function Write-SessionError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("ScanStudio hardware session: $Message")
}

function Test-MediaName {
    param([Parameter(Mandatory = $true)][string]$Value)

    $trimmed = $Value.Trim()
    if (-not $trimmed) {
        throw 'A non-blank media name is required.'
    }
    foreach ($character in $trimmed.ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw 'The media name cannot contain control characters or line breaks.'
        }
    }
    $byteCount = [Text.Encoding]::UTF8.GetByteCount($trimmed)
    if ($byteCount -gt 2048) {
        throw "The media name is too long ($byteCount UTF-8 bytes; maximum 2048)."
    }
    return $trimmed
}

function Resolve-WslExecutable {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if ($env:SCANSTUDIO_LAUNCHER_TEST_MODE -cne '1') {
            throw 'The alternate WSL executable is available only to the isolated launcher test.'
        }
        if (-not [IO.Path]::IsPathRooted($RequestedPath) -or
            [IO.Path]::GetFileName($RequestedPath) -ine 'wsl.exe' -or
            -not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw 'The isolated launcher test requires an absolute existing path named wsl.exe.'
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $systemWslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $systemWslExe -PathType Leaf)) {
        throw 'WSL is not installed at the expected Windows system location.'
    }
    return $systemWslExe
}

function Resolve-ScanStudioExecutable {
    param([string]$RequestedPath)

    $candidates = [Collections.Generic.List[string]]::new()
    if ($RequestedPath) {
        $candidates.Add($RequestedPath)
    }
    else {
        $candidates.Add((Join-Path $PSScriptRoot $MainExecutableName))
        $parentDirectory = Split-Path -Parent $PSScriptRoot
        if ($parentDirectory) {
            $candidates.Add((Join-Path $parentDirectory $MainExecutableName))
        }
        if ($env:LOCALAPPDATA) {
            $candidates.Add((Join-Path $env:LOCALAPPDATA "ScanStudio\$MainExecutableName"))
        }
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if ([IO.Path]::GetFileName($resolved) -ine $MainExecutableName) {
            throw "Refusing to launch anything except $MainExecutableName`: $resolved"
        }
        return $resolved
    }

    throw "Could not find $MainExecutableName next to this launcher or in the per-user install."
}

function Assert-NoExistingScanStudioProcesses {
    $runningApps = @(Get-Process -Name 'scanstudio-app' -ErrorAction SilentlyContinue)
    if ($runningApps.Count -gt 0) {
        $processIds = ($runningApps | ForEach-Object { $_.Id }) -join ', '
        throw "ScanStudio is already running (PID $processIds). Fully quit it before arming a hardware session."
    }
    $runningEngines = @(Get-Process -Name 'scanstudio-engine*' -ErrorAction SilentlyContinue)
    if ($runningEngines.Count -gt 0) {
        $processIds = ($runningEngines | ForEach-Object { $_.Id }) -join ', '
        throw "A surviving ScanStudio engine is running (PID $processIds). Resolve it before arming a hardware session."
    }
}

function Convert-HelperPathToWsl {
    param(
        [Parameter(Mandatory = $true)][string]$WslExe,
        [Parameter(Mandatory = $true)][string]$WindowsPath
    )

    $pathOutput = @(
        & $WslExe -d $DistroName -e /usr/bin/wslpath -a -u $WindowsPath
    )
    $pathExitCode = $LASTEXITCODE
    if ($pathExitCode -ne 0) {
        throw "Ubuntu-24.04 could not translate the launcher helper path (wslpath exit $pathExitCode)."
    }
    $nonBlankLines = @($pathOutput | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ })
    if ($nonBlankLines.Count -ne 1 -or -not $nonBlankLines[0].StartsWith('/')) {
        throw "Ubuntu-24.04 returned an invalid helper path: $($nonBlankLines -join ' | ')"
    }
    return $nonBlankLines[0]
}

function Invoke-LatchHelper {
    param(
        [Parameter(Mandatory = $true)][string]$WslExe,
        [Parameter(Mandatory = $true)][string]$HelperWslPath,
        [Parameter(Mandatory = $true)][ValidateSet('check-orphans', 'acquire', 'release', 'verify')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$SessionToken,
        [Parameter(Mandatory = $true)][string]$MediaNameBase64
    )

    & $WslExe -d $DistroName -e /bin/sh $HelperWslPath $Operation $SessionToken $MediaNameBase64 |
        Out-Host
    return [int]$LASTEXITCODE
}

function Initialize-KillOnCloseJob {
    if (-not ('ScanStudio.HardwareSessionJob' -as [type])) {
        Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ScanStudio
{
    public static class HardwareSessionJob
    {
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public static IntPtr CreateAndAssignCurrentProcess()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");
            }

            try
            {
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits =
                    new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(limits, buffer, false);
                    if (!SetInformationJobObject(
                        job,
                        JobObjectExtendedLimitInformation,
                        buffer,
                        (uint)size
                    ))
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "SetInformationJobObject failed"
                        );
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }

                // The launcher joins the job before it creates the GUI. Every
                // later Windows descendant therefore inherits membership; no
                // post-Start assignment race exists.
                if (!AssignProcessToJobObject(job, GetCurrentProcess()))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "AssignProcessToJobObject failed"
                    );
                }
                return job;
            }
            catch
            {
                CloseHandle(job);
                throw;
            }
        }
    }
}
'@
    }

    return [ScanStudio.HardwareSessionJob]::CreateAndAssignCurrentProcess()
}

function Start-CleanupGuardian {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellExe,
        [Parameter(Mandatory = $true)][int]$ParentProcessId,
        [Parameter(Mandatory = $true)][long]$ParentStartTimeUtcFileTime,
        [Parameter(Mandatory = $true)][string]$SessionToken,
        [Parameter(Mandatory = $true)][string]$MediaNameBase64,
        [Parameter(Mandatory = $true)][string]$ReadyEventName,
        [string]$TestWslExe = ''
    )

    if (-not $PSCommandPath) {
        throw 'The lifecycle guardian requires this launcher to run from its packaged file.'
    }
    $guardianInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $guardianInfo.FileName = $PowerShellExe
    $guardianInfo.UseShellExecute = $false
    $guardianInfo.CreateNoWindow = $true
    $guardianInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $guardianArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy Bypass',
        "-File `"$PSCommandPath`"",
        '-Guardian',
        "-OwnerProcessId $ParentProcessId",
        "-OwnerStartTimeUtcFileTime $ParentStartTimeUtcFileTime",
        "-GuardianSessionToken $SessionToken",
        "-GuardianMediaNameBase64 $MediaNameBase64",
        "-GuardianReadyEventName $ReadyEventName"
    )
    if ($TestWslExe) {
        $guardianArguments += "-GuardianWslExe `"$TestWslExe`""
    }
    $guardianInfo.Arguments = $guardianArguments -join ' '
    Set-SafeStartInfoEnvironment -StartInfo $guardianInfo

    $guardianProcess = [System.Diagnostics.Process]::new()
    $guardianProcess.StartInfo = $guardianInfo
    if (-not $guardianProcess.Start()) {
        throw 'Windows did not start the detached hardware-session cleanup guardian.'
    }
    $guardianProcess.Dispose()
}

function Invoke-CleanupGuardianMode {
    if ($OwnerProcessId -le 0 -or $OwnerStartTimeUtcFileTime -le 0 -or
        $GuardianSessionToken -notmatch '^[0-9a-f]{32}$' -or
        -not $GuardianMediaNameBase64 -or
        $GuardianReadyEventName -notmatch '^Local\\ScanStudioHardwareGuardian-[0-9a-f]{32}$') {
        return 64
    }

    try {
        $ownerProcess = [System.Diagnostics.Process]::GetProcessById($OwnerProcessId)
        if ($ownerProcess.StartTime.ToFileTimeUtc() -ne $OwnerStartTimeUtcFileTime) {
            $ownerProcess.Dispose()
            return 74
        }
    }
    catch {
        # Do not report ready unless the guardian holds the exact owner's
        # process handle. The main launcher cannot acquire a latch before the
        # ready signal, so failing here leaves the session safely unarmed.
        return 74
    }

    try {
        $readyEvent = [Threading.EventWaitHandle]::OpenExisting($GuardianReadyEventName)
        [void]$readyEvent.Set()
        $readyEvent.Dispose()
    }
    catch {
        $ownerProcess.Dispose()
        return 74
    }

    try {
        $ownerProcess.WaitForExit()
    }
    catch {
        $ownerProcess.Dispose()
        return 74
    }
    $ownerProcess.Dispose()

    try {
        $wslExe = Resolve-WslExecutable -RequestedPath $GuardianWslExe
        $latchHelper = Join-Path $PSScriptRoot $LatchHelperName
        if (-not (Test-Path -LiteralPath $latchHelper -PathType Leaf)) {
            return 74
        }
        $helperWslPath = Convert-HelperPathToWsl -WslExe $wslExe -WindowsPath $latchHelper
        return Invoke-LatchHelper `
            -WslExe $wslExe `
            -HelperWslPath $helperWslPath `
            -Operation release `
            -SessionToken $GuardianSessionToken `
            -MediaNameBase64 $GuardianMediaNameBase64
    }
    catch {
        return 74
    }
}

Clear-UnsafeProcessEnvironment

if ($Guardian) {
    $guardianExitCode = Invoke-CleanupGuardianMode
    exit $guardianExitCode
}

$sessionExitCode = 0
$latchAcquired = $false
$wslExe = ''
$helperWslPath = ''
$sessionToken = ''
$mediaNameBase64 = ''
$jobHandle = [IntPtr]::Zero
$guardianReadyEvent = $null

try {
    if (-not $MediaName) {
        $MediaName = Read-Host 'Name the junk/test media currently loaded'
    }
    $MediaName = Test-MediaName -Value $MediaName

    Assert-NoExistingScanStudioProcesses

    $resolvedExecutable = Resolve-ScanStudioExecutable -RequestedPath $ScanStudioExe
    $latchHelper = Join-Path $PSScriptRoot $LatchHelperName
    if (-not (Test-Path -LiteralPath $latchHelper -PathType Leaf)) {
        throw "The packaged WSL latch helper is missing: $latchHelper"
    }

    $wslExe = Resolve-WslExecutable -RequestedPath $TestWslExe
    $helperWslPath = Convert-HelperPathToWsl -WslExe $wslExe -WindowsPath $latchHelper

    $sessionToken = [guid]::NewGuid().ToString('N')
    $mediaBytes = [Text.Encoding]::UTF8.GetBytes($MediaName)
    $mediaNameBase64 = [Convert]::ToBase64String($mediaBytes)

    $ownerProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $guardianReadyEventName = "Local\ScanStudioHardwareGuardian-$sessionToken"
    $guardianReadyEvent = [Threading.EventWaitHandle]::new(
        $false,
        [Threading.EventResetMode]::ManualReset,
        $guardianReadyEventName
    )
    Start-CleanupGuardian `
        -PowerShellExe (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ParentProcessId $ownerProcess.Id `
        -ParentStartTimeUtcFileTime ($ownerProcess.StartTime.ToFileTimeUtc()) `
        -SessionToken $sessionToken `
        -MediaNameBase64 $mediaNameBase64 `
        -ReadyEventName $guardianReadyEventName `
        -TestWslExe $TestWslExe
    if (-not $guardianReadyEvent.WaitOne(10000)) {
        throw 'The detached cleanup guardian did not report ready within 10 seconds.'
    }
    $jobHandle = Initialize-KillOnCloseJob
    if ($jobHandle -eq [IntPtr]::Zero) {
        throw 'Windows did not establish the hardware-session process job.'
    }

    $orphanExitCode = Invoke-LatchHelper `
        -WslExe $wslExe `
        -HelperWslPath $helperWslPath `
        -Operation check-orphans `
        -SessionToken $sessionToken `
        -MediaNameBase64 $mediaNameBase64
    if ($orphanExitCode -ne 0) {
        $sessionExitCode = $orphanExitCode
        throw "The WSL bridge orphan preflight failed (exit $orphanExitCode). No app was launched."
    }

    Write-Host "Arming one ScanStudio hardware session for media '$MediaName'..."
    $acquireExitCode = Invoke-LatchHelper `
        -WslExe $wslExe `
        -HelperWslPath $helperWslPath `
        -Operation acquire `
        -SessionToken $sessionToken `
        -MediaNameBase64 $mediaNameBase64
    if ($acquireExitCode -ne 0) {
        $sessionExitCode = $acquireExitCode
        throw "The WSL motion latch was not acquired (exit $acquireExitCode). No app was launched."
    }
    $latchAcquired = $true

    $orphanExitCode = Invoke-LatchHelper `
        -WslExe $wslExe `
        -HelperWslPath $helperWslPath `
        -Operation check-orphans `
        -SessionToken $sessionToken `
        -MediaNameBase64 $mediaNameBase64
    if ($orphanExitCode -ne 0) {
        $sessionExitCode = $orphanExitCode
        throw "A WSL bridge appeared while the latch was being acquired (exit $orphanExitCode). No app was launched."
    }

    # Reduce the launch-window race with an ordinary direct app/engine start.
    # ScanStudio itself remains the final authority for any future shared
    # single-instance policy.
    Assert-NoExistingScanStudioProcesses

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedExecutable
    $startInfo.WorkingDirectory = [IO.Path]::GetDirectoryName($resolvedExecutable)
    $startInfo.UseShellExecute = $false
    Set-SafeStartInfoEnvironment -StartInfo $startInfo
    $startInfo.EnvironmentVariables['SCANSTUDIO_HW_MOTION'] = '1'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Windows did not start $MainExecutableName."
    }

    Write-Host "ScanStudio hardware session started (PID $($process.Id))."
    Write-Host 'Keep this window open. The owned WSL latch will be removed when that app process exits.'
    $process.WaitForExit()
    $sessionExitCode = $process.ExitCode
    if ($sessionExitCode -ne 0) {
        Write-SessionError "$MainExecutableName exited with code $sessionExitCode."
    }
}
catch {
    Write-SessionError $_.Exception.Message
    if ($sessionExitCode -eq 0) {
        $sessionExitCode = 1
    }
}
finally {
    if ($latchAcquired) {
        try {
            Write-Host 'Disarming the owned WSL motion latch...'
            $releaseExitCode = Invoke-LatchHelper `
                -WslExe $wslExe `
                -HelperWslPath $helperWslPath `
                -Operation release `
                -SessionToken $sessionToken `
                -MediaNameBase64 $mediaNameBase64
            if ($releaseExitCode -ne 0) {
                Write-SessionError "The latch no longer matches this session and was left untouched (exit $releaseExitCode). Inspect Ubuntu-24.04 before any later hardware session."
                $sessionExitCode = $releaseExitCode
            }
            else {
                Write-Host 'Hardware session disarmed.'
            }
        }
        catch {
            Write-SessionError "Could not verify and remove the owned latch: $($_.Exception.Message)"
            $sessionExitCode = 74
        }
    }
    if ($null -ne $guardianReadyEvent) {
        $guardianReadyEvent.Dispose()
    }
}

exit $sessionExitCode
