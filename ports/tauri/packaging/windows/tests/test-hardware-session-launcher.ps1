[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherRoot
)

# Windows PowerShell 5.1 black-box coverage for the hardware-session launcher.
# Both executables are local test doubles; this suite never opens WSL or talks
# to scanner hardware.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$LauncherRoot = (Resolve-Path -LiteralPath $LauncherRoot).Path
$sourceLauncher = Join-Path $LauncherRoot 'Start-ScanStudio-Hardware-Session.ps1'
$sourceHelper = Join-Path $LauncherRoot 'scanstudio-hardware-session-latch.sh'
foreach ($sourceFile in @($sourceLauncher, $sourceHelper)) {
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Launcher input is missing: $sourceFile"
    }
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell 5.1 is missing: $windowsPowerShell"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'ScanStudio launcher black box with spaces ' + [guid]::NewGuid().ToString('N')
)
$launcherPackage = Join-Path $testRoot 'launcher package with spaces'
$launcher = Join-Path $launcherPackage 'Start-ScanStudio-Hardware-Session.ps1'
$fakeBin = Join-Path $testRoot 'fake binaries with spaces'
$stateRoot = Join-Path $testRoot 'state'
$fakeWsl = Join-Path $fakeBin 'wsl.exe'
$fakeApp = Join-Path $fakeBin 'scanstudio-app.exe'
$fakeEngine = Join-Path $fakeBin 'scanstudio-engine-test.exe'
$fakeRuntime = Join-Path $fakeBin 'fake-runtime.exe'
$runningProcesses = [Collections.Generic.List[System.Diagnostics.Process]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
    Write-Host "PASS  $Message"
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "ASSERTION FAILED: $Message (expected '$Expected', got '$Actual')"
    }
    Write-Host "PASS  $Message"
}

function Quote-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Contains('"')) {
        throw 'A black-box test path unexpectedly contains a double quote.'
    }
    return '"' + $Value + '"'
}

function Reset-FakeState {
    if (Test-Path -LiteralPath $stateRoot) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}

function Wait-ForFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutMilliseconds = 15000
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out waiting for test evidence: $Path"
}

function Wait-ForProcessExit {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$TimeoutMilliseconds = 15000
    )
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        try { $Process.Kill() } catch { }
        throw "Timed out waiting for PID $($Process.Id)"
    }
}

function Set-StartInfoTestEnvironment {
    param([Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo)

    $StartInfo.EnvironmentVariables['SCANSTUDIO_LAUNCHER_TEST_MODE'] = '1'
    $StartInfo.EnvironmentVariables['SCANSTUDIO_FAKE_ROOT'] = $stateRoot
}

function New-LauncherProcess {
    param([string]$Executable = $fakeApp)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $windowsPowerShell
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy Bypass',
        '-File ' + (Quote-ProcessArgument $launcher),
        '-MediaName black-box-media',
        '-ScanStudioExe ' + (Quote-ProcessArgument $Executable),
        '-TestWslExe ' + (Quote-ProcessArgument $fakeWsl)
    ) -join ' '
    Set-StartInfoTestEnvironment -StartInfo $startInfo

    # Prove that caller pollution cannot redirect or pre-arm the helper/app.
    $startInfo.EnvironmentVariables['SCANSTUDIO_HW_MOTION'] = 'caller-pollution'
    $startInfo.EnvironmentVariables['SCANSTUDIO_STATE_DIR'] = 'C:\unsafe-state'
    $startInfo.EnvironmentVariables['SCANSTUDIO_BRIDGE_BASE_DIR'] = 'C:\unsafe-bridge'
    $startInfo.EnvironmentVariables['HOME'] = 'C:\caller-home-is-not-forwarded'
    $startInfo.EnvironmentVariables['WSLENV'] = @(
        'KeepOne',
        'home/p',
        'SCANSTUDIO_STATE_DIR/p',
        'keepTwo/u',
        'ScAnStUdIo_Hw_MoTiOn',
        'SCANSTUDIO_BRIDGE_BASE_DIR/l'
    ) -join ':'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Windows did not start the launcher test process.'
    }
    $runningProcesses.Add($process)
    return $process
}

function New-DirectFakeProcess {
    param([string]$Executable = $fakeApp)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    Set-StartInfoTestEnvironment -StartInfo $startInfo
    $startInfo.EnvironmentVariables.Remove('SCANSTUDIO_HW_MOTION')

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Windows did not start the direct fake app.'
    }
    $runningProcesses.Add($process)
    return $process
}

function Signal-FakeAppExit {
    Set-Content -LiteralPath (Join-Path $stateRoot 'app-exit.signal') -Value 'exit' -Encoding ascii
}

function Complete-Launcher {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
        [switch]$SignalApp
    )

    if ($SignalApp) {
        Signal-FakeAppExit
    }
    Wait-ForProcessExit -Process $Process
    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    if ($Process.ExitCode -ne $ExpectedExitCode) {
        throw "Launcher exited $($Process.ExitCode), expected $ExpectedExitCode.`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
    }
    Write-Host "PASS  launcher propagated exit code $ExpectedExitCode"
}

function Read-KeyValueFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $values = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $separator = $line.IndexOf('=')
        if ($separator -ge 0) {
            $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
        }
    }
    return $values
}

function Decode-Base64Text {
    param([string]$Value)
    if (-not $Value) { return '' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Read-WslCalls {
    $calls = @()
    foreach ($line in (Get-Content -LiteralPath (Join-Path $stateRoot 'wsl-calls.log'))) {
        $parts = $line -split '\|'
        $argumentCount = [int]$parts[1]
        $arguments = @()
        for ($index = 0; $index -lt $argumentCount; $index++) {
            $arguments += (Decode-Base64Text -Value $parts[2 + $index])
        }
        $calls += [pscustomobject]@{
            Arguments = $arguments
            Wslenv = (Decode-Base64Text -Value $parts[2 + $argumentCount])
            Motion = (Decode-Base64Text -Value $parts[3 + $argumentCount])
            State = (Decode-Base64Text -Value $parts[4 + $argumentCount])
            BridgeBase = (Decode-Base64Text -Value $parts[5 + $argumentCount])
        }
    }
    return $calls
}

function Wait-ForReleaseCompletionCount {
    param(
        [Parameter(Mandatory = $true)][int]$Count,
        [int]$TimeoutMilliseconds = 15000
    )
    $path = Join-Path $stateRoot 'release-completions.log'
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and
                @((Get-Content -LiteralPath $path)).Count -ge $Count) {
                return
            }
        }
        catch { }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out waiting for $Count fake WSL release completion(s)."
}

function Wait-ForProcessIdAbsent {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutMilliseconds = 10000
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $candidate = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $candidate) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Process $ProcessId survived beyond the expected job shutdown."
}

New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
New-Item -ItemType Directory -Path $launcherPackage -Force | Out-Null
Copy-Item -LiteralPath $sourceLauncher -Destination $launcher
Copy-Item -LiteralPath $sourceHelper -Destination (Join-Path $launcherPackage 'scanstudio-hardware-session-latch.sh')
$fakeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class Program
{
    private static string Root
    {
        get
        {
            string value = Environment.GetEnvironmentVariable("SCANSTUDIO_FAKE_ROOT");
            if (String.IsNullOrEmpty(value)) throw new Exception("SCANSTUDIO_FAKE_ROOT is missing");
            return value;
        }
    }

    private static string At(string name) { return Path.Combine(Root, name); }
    private static string Env(string name)
    {
        string value = Environment.GetEnvironmentVariable(name);
        return value ?? "";
    }
    private static string B64(string value)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? ""));
    }
    private static int ExitSetting(string name, int fallback)
    {
        string path = At(name);
        int parsed;
        if (File.Exists(path) && Int32.TryParse(File.ReadAllText(path).Trim(), out parsed)) return parsed;
        return fallback;
    }
    private static void Append(string path, string value)
    {
        for (int attempt = 0; attempt < 100; attempt++)
        {
            try
            {
                using (FileStream stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read))
                using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false)))
                {
                    writer.WriteLine(value);
                    return;
                }
            }
            catch (IOException) { Thread.Sleep(10); }
        }
        throw new IOException("Could not append fake-runtime evidence");
    }

    private static int RunWsl(string[] args)
    {
        StringBuilder record = new StringBuilder();
        record.Append("W|").Append(args.Length);
        foreach (string argument in args) record.Append('|').Append(B64(argument));
        record.Append('|').Append(B64(Env("WSLENV")));
        record.Append('|').Append(B64(Env("SCANSTUDIO_HW_MOTION")));
        record.Append('|').Append(B64(Env("SCANSTUDIO_STATE_DIR")));
        record.Append('|').Append(B64(Env("SCANSTUDIO_BRIDGE_BASE_DIR")));
        Append(At("wsl-calls.log"), record.ToString());

        if (args.Length >= 4 && args[3] == "/usr/bin/wslpath")
        {
            Console.WriteLine("/mnt/fake/scanstudio-hardware-session-latch.sh");
            return ExitSetting("wslpath-exit.txt", 0);
        }
        if (args.Length < 8 || args[3] != "/bin/sh") return 64;

        string operation = args[5];
        string owner = args[6] + "\n" + args[7];
        string latch = At("fake-latch.txt");
        if (operation == "check-orphans")
        {
            string countPath = At("orphan-count.txt");
            int count = 0;
            if (File.Exists(countPath)) Int32.TryParse(File.ReadAllText(countPath).Trim(), out count);
            count++;
            File.WriteAllText(countPath, count.ToString(), Encoding.ASCII);
            return count == 2
                ? ExitSetting("orphan-second-exit.txt", ExitSetting("orphan-exit.txt", 0))
                : ExitSetting("orphan-exit.txt", 0);
        }
        if (operation == "acquire")
        {
            int configured = ExitSetting("acquire-exit.txt", 0);
            if (configured != 0) return configured;
            File.WriteAllText(latch, owner, new UTF8Encoding(false));
            File.WriteAllText(At("acquired.txt"), owner, new UTF8Encoding(false));
            return 0;
        }
        if (operation == "verify")
        {
            return File.Exists(latch) && File.ReadAllText(latch) == owner ? 0 : 74;
        }
        if (operation == "release")
        {
            while (File.Exists(At("block-release")) && !File.Exists(At("allow-release")))
                Thread.Sleep(25);
            int result = ExitSetting("release-exit.txt", 0);
            if (result == 0 && File.Exists(latch))
            {
                if (File.ReadAllText(latch) == owner) File.Delete(latch);
                else result = 74;
            }
            File.WriteAllText(At("release-attempt.txt"), owner + "\n" + result, new UTF8Encoding(false));
            Append(At("release-completions.log"), B64(owner) + "|" + result.ToString());
            return result;
        }
        return 64;
    }

    private static int RunApp()
    {
        StringBuilder environment = new StringBuilder();
        environment.AppendLine("MOTION=" + Env("SCANSTUDIO_HW_MOTION"));
        environment.AppendLine("WSLENV=" + Env("WSLENV"));
        environment.AppendLine("STATE=" + Env("SCANSTUDIO_STATE_DIR"));
        environment.AppendLine("BRIDGE_BASE=" + Env("SCANSTUDIO_BRIDGE_BASE_DIR"));
        environment.AppendLine("HOME=" + Env("HOME"));
        File.WriteAllText(At("app-environment.txt"), environment.ToString(), new UTF8Encoding(false));
        File.WriteAllText(At("app-started.txt"), Process.GetCurrentProcess().Id.ToString(), Encoding.ASCII);
        while (!File.Exists(At("app-exit.signal"))) Thread.Sleep(25);
        File.WriteAllText(At("app-stopped.txt"), DateTime.UtcNow.Ticks.ToString(), Encoding.ASCII);
        return ExitSetting("app-exit-code.txt", 0);
    }

    public static int Main(string[] args)
    {
        string executable = Path.GetFileName(Process.GetCurrentProcess().MainModule.FileName);
        return String.Equals(executable, "wsl.exe", StringComparison.OrdinalIgnoreCase)
            ? RunWsl(args)
            : RunApp();
    }
}
'@

try {
    Add-Type -TypeDefinition $fakeSource -Language CSharp -OutputAssembly $fakeRuntime -OutputType ConsoleApplication
    Copy-Item -LiteralPath $fakeRuntime -Destination $fakeWsl
    Copy-Item -LiteralPath $fakeRuntime -Destination $fakeApp
    Copy-Item -LiteralPath $fakeRuntime -Destination $fakeEngine

    # A direct Start-menu/Explorer-equivalent launch remains unarmed.
    Reset-FakeState
    $directApp = New-DirectFakeProcess
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    $directEnvironment = Read-KeyValueFile -Path (Join-Path $stateRoot 'app-environment.txt')
    Assert-Equal '' $directEnvironment['MOTION'] 'direct app launch is unarmed'
    Signal-FakeAppExit
    Wait-ForProcessExit -Process $directApp

    # The guardian must verify the exact owner before it signals readiness. A
    # mismatched process start time cannot let the main launcher acquire a
    # latch under supervision that has already failed.
    Reset-FakeState
    $guardianToken = [guid]::NewGuid().ToString('N')
    $guardianReadyEventName = "Local\ScanStudioHardwareGuardian-$guardianToken"
    $guardianReadyEvent = [Threading.EventWaitHandle]::new(
        $false,
        [Threading.EventResetMode]::ManualReset,
        $guardianReadyEventName
    )
    try {
        $guardianOwner = [System.Diagnostics.Process]::GetCurrentProcess()
        $incorrectOwnerStartTime = $guardianOwner.StartTime.ToFileTimeUtc() + 1
        $guardianMediaNameBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes('black-box-media')
        )
        $guardianInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $guardianInfo.FileName = $windowsPowerShell
        $guardianInfo.UseShellExecute = $false
        $guardianInfo.CreateNoWindow = $true
        $guardianInfo.Arguments = @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy Bypass',
            '-File ' + (Quote-ProcessArgument $launcher),
            '-Guardian',
            '-OwnerProcessId ' + $guardianOwner.Id,
            '-OwnerStartTimeUtcFileTime ' + $incorrectOwnerStartTime,
            '-GuardianSessionToken ' + $guardianToken,
            '-GuardianMediaNameBase64 ' + $guardianMediaNameBase64,
            '-GuardianReadyEventName ' + (Quote-ProcessArgument $guardianReadyEventName),
            '-GuardianWslExe ' + (Quote-ProcessArgument $fakeWsl)
        ) -join ' '
        Set-StartInfoTestEnvironment -StartInfo $guardianInfo

        $mismatchedGuardian = [System.Diagnostics.Process]::new()
        $mismatchedGuardian.StartInfo = $guardianInfo
        Assert-True $mismatchedGuardian.Start() 'Windows starts the mismatched-owner guardian regression case'
        $runningProcesses.Add($mismatchedGuardian)
        Wait-ForProcessExit -Process $mismatchedGuardian
        Assert-Equal 74 $mismatchedGuardian.ExitCode 'guardian refuses a mismatched owner start time'
        Assert-True (-not $guardianReadyEvent.WaitOne(0)) 'guardian does not report ready for a mismatched owner'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'wsl-calls.log'))) 'mismatched-owner guardian exits before invoking WSL'
    }
    finally {
        $guardianReadyEvent.Dispose()
    }

    # Happy path, polluted parent, exact pinned WSL argv, and child ownership.
    Reset-FakeState
    $testParentMotion = [Environment]::GetEnvironmentVariable('SCANSTUDIO_HW_MOTION')
    $testParentWslenv = [Environment]::GetEnvironmentVariable('WSLENV')
    $launcherProcess = New-LauncherProcess
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    Assert-True (-not $launcherProcess.HasExited) 'launcher stays alive while its exact child is running'
    Assert-Equal $testParentMotion ([Environment]::GetEnvironmentVariable('SCANSTUDIO_HW_MOTION')) 'launcher does not mutate its parent motion environment'
    Assert-Equal $testParentWslenv ([Environment]::GetEnvironmentVariable('WSLENV')) 'launcher does not mutate its parent WSLENV'
    $childEnvironment = Read-KeyValueFile -Path (Join-Path $stateRoot 'app-environment.txt')
    Assert-Equal '1' $childEnvironment['MOTION'] 'only launcher child receives motion authorization'
    Assert-Equal '' $childEnvironment['STATE'] 'child cannot inherit a state-directory override'
    Assert-Equal '' $childEnvironment['BRIDGE_BASE'] 'child cannot inherit a bridge-base override'
    Assert-Equal 'KeepOne:keepTwo/u' $childEnvironment['WSLENV'] 'WSLENV keeps unrelated entries and strips every sensitive entry including HOME'
    Assert-Equal 'C:\caller-home-is-not-forwarded' $childEnvironment['HOME'] 'Windows HOME is not rewritten while its WSLENV entry is stripped'

    $wslCalls = @(Read-WslCalls)
    Assert-True ($wslCalls.Count -ge 4) 'fake WSL observed translation, orphan checks, and acquisition'
    foreach ($call in $wslCalls) {
        Assert-Equal '-d' $call.Arguments[0] 'WSL invocation uses an explicit distribution flag'
        Assert-Equal 'Ubuntu-24.04' $call.Arguments[1] 'WSL invocation pins Ubuntu-24.04'
        Assert-Equal '-e' $call.Arguments[2] 'WSL invocation uses direct exec rather than shell interpolation'
        Assert-Equal '' $call.Motion 'helper process is not motion-authorized'
        Assert-Equal '' $call.State 'helper process has no state-directory override'
        Assert-Equal '' $call.BridgeBase 'helper process has no bridge-base override'
        Assert-Equal 'KeepOne:keepTwo/u' $call.Wslenv 'helper receives sanitized WSLENV'
    }
    Complete-Launcher -Process $launcherProcess -ExpectedExitCode 0 -SignalApp
    Wait-ForFile -Path (Join-Path $stateRoot 'release-attempt.txt')
    Wait-ForReleaseCompletionCount -Count 2
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'fake-latch.txt'))) 'matching release removes the fake owned latch after child exit'

    # An already-running app blocks acquisition entirely.
    Reset-FakeState
    $existingApp = New-DirectFakeProcess
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    $refusedLauncher = New-LauncherProcess
    Complete-Launcher -Process $refusedLauncher -ExpectedExitCode 1
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'wsl-calls.log'))) 'existing app is refused before invoking WSL or acquiring a latch'
    Signal-FakeAppExit
    Wait-ForProcessExit -Process $existingApp

    # A surviving engine is also refused before any latch publication.
    Reset-FakeState
    $existingEngine = New-DirectFakeProcess -Executable $fakeEngine
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    $engineRefusal = New-LauncherProcess
    Complete-Launcher -Process $engineRefusal -ExpectedExitCode 1
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'wsl-calls.log'))) 'existing engine is refused before invoking WSL or acquiring a latch'
    Signal-FakeAppExit
    Wait-ForProcessExit -Process $existingEngine

    # Acquire failure never starts the app and preserves the helper exit code.
    Reset-FakeState
    Set-Content -LiteralPath (Join-Path $stateRoot 'acquire-exit.txt') -Value '73' -Encoding ascii
    $acquireFailure = New-LauncherProcess
    Complete-Launcher -Process $acquireFailure -ExpectedExitCode 73
    Wait-ForReleaseCompletionCount -Count 1
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'app-started.txt'))) 'acquire failure never starts the app'

    # A bridge appearing after acquisition blocks app start and releases the
    # newly acquired latch before returning the orphan failure.
    Reset-FakeState
    Set-Content -LiteralPath (Join-Path $stateRoot 'orphan-second-exit.txt') -Value '76' -Encoding ascii
    $postAcquireOrphan = New-LauncherProcess
    Complete-Launcher -Process $postAcquireOrphan -ExpectedExitCode 76
    Wait-ForReleaseCompletionCount -Count 2
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'app-started.txt'))) 'post-acquire orphan failure never starts the app'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'fake-latch.txt'))) 'post-acquire orphan failure releases its owned latch'

    # Start failure occurs after acquisition and still performs matching cleanup.
    Reset-FakeState
    $invalidApp = Join-Path $testRoot 'invalid app with spaces\scanstudio-app.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $invalidApp) -Force | Out-Null
    Set-Content -LiteralPath $invalidApp -Value 'not an executable' -Encoding ascii
    $startFailure = New-LauncherProcess -Executable $invalidApp
    Complete-Launcher -Process $startFailure -ExpectedExitCode 1
    Wait-ForFile -Path (Join-Path $stateRoot 'release-attempt.txt')
    Wait-ForReleaseCompletionCount -Count 2
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'fake-latch.txt'))) 'app-start failure releases its owned latch'

    # Nonzero child and release failures propagate to the launcher owner.
    Reset-FakeState
    Set-Content -LiteralPath (Join-Path $stateRoot 'app-exit-code.txt') -Value '7' -Encoding ascii
    $childFailure = New-LauncherProcess
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    Complete-Launcher -Process $childFailure -ExpectedExitCode 7 -SignalApp
    Wait-ForReleaseCompletionCount -Count 2

    Reset-FakeState
    Set-Content -LiteralPath (Join-Path $stateRoot 'release-exit.txt') -Value '74' -Encoding ascii
    $releaseFailure = New-LauncherProcess
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    Complete-Launcher -Process $releaseFailure -ExpectedExitCode 74 -SignalApp
    Wait-ForReleaseCompletionCount -Count 2

    # Forced owner death closes the job, kills the GUI, and leaves the detached
    # guardian to remove the matching owned latch.
    Reset-FakeState
    Set-Content -LiteralPath (Join-Path $stateRoot 'block-release') -Value 'block' -Encoding ascii
    $forcedLauncher = New-LauncherProcess
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    Wait-ForFile -Path (Join-Path $stateRoot 'acquired.txt')
    $forcedAppId = [int](Get-Content -LiteralPath (Join-Path $stateRoot 'app-started.txt') -Raw)
    $forcedLauncher.Kill()
    Wait-ForProcessExit -Process $forcedLauncher

    Wait-ForProcessIdAbsent -ProcessId $forcedAppId
    Assert-True $true 'kill-on-close job terminates the GUI when the launcher is force-killed'
    Set-Content -LiteralPath (Join-Path $stateRoot 'allow-release') -Value 'allow' -Encoding ascii
    Wait-ForFile -Path (Join-Path $stateRoot 'release-attempt.txt')
    Wait-ForReleaseCompletionCount -Count 1
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'fake-latch.txt'))) 'guardian removes the matching owned latch after forced launcher death'

    # The same forced-death path never removes content replaced by another
    # owner before the guardian's ownership check.
    Reset-FakeState
    Set-Content -LiteralPath (Join-Path $stateRoot 'block-release') -Value 'block' -Encoding ascii
    $foreignLauncher = New-LauncherProcess
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    Wait-ForFile -Path (Join-Path $stateRoot 'acquired.txt')
    $foreignAppId = [int](Get-Content -LiteralPath (Join-Path $stateRoot 'app-started.txt') -Raw)
    $foreignLauncher.Kill()
    Wait-ForProcessExit -Process $foreignLauncher
    Wait-ForProcessIdAbsent -ProcessId $foreignAppId

    Set-Content -LiteralPath (Join-Path $stateRoot 'fake-latch.txt') -Value 'foreign replacement' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $stateRoot 'allow-release') -Value 'allow' -Encoding ascii
    Wait-ForFile -Path (Join-Path $stateRoot 'release-attempt.txt')
    Wait-ForReleaseCompletionCount -Count 1
    Assert-True ((Get-Content -LiteralPath (Join-Path $stateRoot 'fake-latch.txt') -Raw).Contains('foreign replacement')) 'guardian leaves a foreign replacement latch untouched'

    Write-Host 'Windows hardware-session launcher black-box tests: all checks passed'
}
finally {
    foreach ($process in $runningProcesses) {
        try {
            if (-not $process.HasExited) { $process.Kill() }
        }
        catch { }
        try { $process.Dispose() } catch { }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
