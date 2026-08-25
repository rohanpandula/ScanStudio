[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherRoot
)

# Windows PowerShell 5.1 black-box coverage for the hardware-session launcher.
# WSL is always a local test double. Source-layout checks use fixture app and
# engine executables; installed and portable checks additionally launch the
# real packaged app and engine sidecar. No case opens WSL or talks to scanner
# hardware.
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

if (-not ('ScanStudio.LauncherTestProcess' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ScanStudio
{
    public static class LauncherTestProcess
    {
        private const uint TH32CS_SNAPPROCESS = 0x00000002;
        private const uint WAIT_OBJECT_0 = 0x00000000;
        private const uint WAIT_TIMEOUT = 0x00000102;
        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint GetProcessId(IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public static bool IsAlive(IntPtr process)
        {
            uint result = WaitForSingleObject(process, 0);
            if (result == WAIT_TIMEOUT) return true;
            if (result == WAIT_OBJECT_0) return false;
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
        }

        public static int GetParentProcessId(IntPtr process)
        {
            if (!IsAlive(process))
            {
                throw new InvalidOperationException(
                    "Cannot query parentage for an exited retained process handle."
                );
            }
            uint processId = GetProcessId(process);
            if (processId == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetProcessId failed");
            }

            IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot == INVALID_HANDLE_VALUE)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateToolhelp32Snapshot failed"
                );
            }

            try
            {
                PROCESSENTRY32 entry = new PROCESSENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                if (!Process32First(snapshot, ref entry))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Process32First failed"
                    );
                }
                do
                {
                    if (entry.th32ProcessID == processId)
                    {
                        if (!IsAlive(process))
                        {
                            throw new InvalidOperationException(
                                "The retained process exited during the parentage query."
                            );
                        }
                        return checked((int)entry.th32ParentProcessID);
                    }
                }
                while (Process32Next(snapshot, ref entry));
            }
            finally
            {
                CloseHandle(snapshot);
            }

            throw new InvalidOperationException(
                "The retained process handle was absent from the native process snapshot."
            );
        }
    }
}
'@
}

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
    param(
        [string]$Executable = $fakeApp,
        [string]$LauncherPath = $launcher,
        [switch]$CleanParentEnvironment,
        [switch]$IsolateDesktopProfile
    )

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
        '-File ' + (Quote-ProcessArgument $LauncherPath),
        '-MediaName black-box-media',
        '-ScanStudioExe ' + (Quote-ProcessArgument $Executable),
        '-TestWslExe ' + (Quote-ProcessArgument $fakeWsl)
    ) -join ' '
    Set-StartInfoTestEnvironment -StartInfo $startInfo

    if ($IsolateDesktopProfile) {
        $profileRoot = Join-Path $testRoot 'isolated desktop profile'
        $localAppData = Join-Path $profileRoot 'AppData\Local'
        $roamingAppData = Join-Path $profileRoot 'AppData\Roaming'
        $profileTemp = Join-Path $profileRoot 'Temp'
        foreach ($directory in @($localAppData, $roamingAppData, $profileTemp)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $localAppData
        $startInfo.EnvironmentVariables['APPDATA'] = $roamingAppData
        $startInfo.EnvironmentVariables['USERPROFILE'] = $profileRoot
        $startInfo.EnvironmentVariables['HOME'] = $profileRoot
        $startInfo.EnvironmentVariables['TEMP'] = $profileTemp
        $startInfo.EnvironmentVariables['TMP'] = $profileTemp
        $existingPath = $startInfo.EnvironmentVariables['PATH']
        $startInfo.EnvironmentVariables['PATH'] = if ($existingPath) {
            $fakeBin + [IO.Path]::PathSeparator + $existingPath
        }
        else {
            $fakeBin
        }
    }

    if ($CleanParentEnvironment) {
        foreach ($variableName in @(
            'SCANSTUDIO_HW_MOTION',
            'SCANSTUDIO_STATE_DIR',
            'SCANSTUDIO_BRIDGE_BASE_DIR',
            'WSLENV'
        )) {
            $startInfo.EnvironmentVariables.Remove($variableName)
        }
    }
    else {
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
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Windows did not start the launcher test process.'
    }
    $runningProcesses.Add($process)
    return $process
}

function New-DirectFakeProcess {
    param(
        [string]$Executable = $fakeApp,
        [string]$Arguments = ''
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = $Arguments
    Set-StartInfoTestEnvironment -StartInfo $startInfo
    $startInfo.EnvironmentVariables.Remove('SCANSTUDIO_HW_MOTION')

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Windows did not start the direct fake process.'
    }
    $runningProcesses.Add($process)
    return $process
}

function Signal-FakeAppExit {
    Set-Content -LiteralPath (Join-Path $stateRoot 'app-exit.signal') -Value 'exit' -Encoding ascii
}

function Signal-FakeEngineExit {
    Set-Content -LiteralPath (Join-Path $stateRoot 'engine-exit.signal') -Value 'exit' -Encoding ascii
}

function Signal-ControlExit {
    Set-Content -LiteralPath (Join-Path $stateRoot 'control-exit.signal') -Value 'exit' -Encoding ascii
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

function ConvertTo-ComparableWindowsPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\?\')) {
        $fullPath = $fullPath.Substring(4)
    }
    return $fullPath.TrimEnd('\')
}

function Assert-ExpectedProcessImage {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutable,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $expectedPath = ConvertTo-ComparableWindowsPath -Path (
        (Resolve-Path -LiteralPath $ExpectedExecutable).Path
    )
    $actualPath = ConvertTo-ComparableWindowsPath -Path $Process.MainModule.FileName
    Assert-True (
        [string]::Equals($expectedPath, $actualPath, [StringComparison]::OrdinalIgnoreCase)
    ) $Message
}

function Open-ProcessHandleFromEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutable
    )

    Wait-ForFile -Path $EvidencePath
    $recordedProcessId = 0
    if (-not [int]::TryParse(
        (Get-Content -LiteralPath $EvidencePath -Raw).Trim(),
        [ref]$recordedProcessId
    )) {
        throw "Fixture wrote an invalid process id: $EvidencePath"
    }
    $process = [System.Diagnostics.Process]::GetProcessById($recordedProcessId)
    [void]$process.Handle
    Assert-ExpectedProcessImage `
        -Process $process `
        -ExpectedExecutable $ExpectedExecutable `
        -Message "fixture evidence resolves to the expected executable: $ExpectedExecutable"
    Assert-True (
        [ScanStudio.LauncherTestProcess]::IsAlive($process.Handle)
    ) "fixture process handle is alive: $ExpectedExecutable"
    $runningProcesses.Add($process)
    return $process
}

function Wait-ForExactChildProcessHandle {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Parent,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutable,
        [int]$TimeoutMilliseconds = 30000
    )

    $expectedName = [IO.Path]::GetFileNameWithoutExtension($ExpectedExecutable)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        foreach ($candidate in @(
            Get-Process -Name $expectedName -ErrorAction SilentlyContinue
        )) {
            try {
                [void]$candidate.Handle
                if (-not [ScanStudio.LauncherTestProcess]::IsAlive($candidate.Handle)) {
                    $candidate.Dispose()
                    continue
                }
                $parentProcessId = [ScanStudio.LauncherTestProcess]::GetParentProcessId(
                    $candidate.Handle
                )
                if ($parentProcessId -ne $Parent.Id) {
                    $candidate.Dispose()
                    continue
                }
                Assert-ExpectedProcessImage `
                    -Process $candidate `
                    -ExpectedExecutable $ExpectedExecutable `
                    -Message "native child handle resolves to the packaged executable: $ExpectedExecutable"
                $runningProcesses.Add($candidate)
                return $candidate
            }
            catch {
                try { $candidate.Dispose() } catch { }
            }
        }
        if (-not [ScanStudio.LauncherTestProcess]::IsAlive($Parent.Handle)) {
            throw "Parent process exited before starting expected child: $ExpectedExecutable"
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out waiting for exact child process: $ExpectedExecutable"
}

function Wait-ForExactProcessExit {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$TimeoutMilliseconds = 15000
    )

    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        try { $Process.Kill() } catch { }
        throw "Exact process handle survived beyond the expected job shutdown: $Message"
    }
    Assert-True (
        -not [ScanStudio.LauncherTestProcess]::IsAlive($Process.Handle)
    ) $Message
}

New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
New-Item -ItemType Directory -Path $launcherPackage -Force | Out-Null
Copy-Item -LiteralPath $sourceLauncher -Destination $launcher
Copy-Item -LiteralPath $sourceHelper -Destination (Join-Path $launcherPackage 'scanstudio-hardware-session-latch.sh')
$fakeSource = @'
using System;
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

    private static int RunControl()
    {
        File.WriteAllText(
            At("control-started.txt"),
            Process.GetCurrentProcess().Id.ToString(),
            Encoding.ASCII
        );
        while (!File.Exists(At("control-exit.signal"))) Thread.Sleep(25);
        File.WriteAllText(
            At("control-stopped.txt"),
            DateTime.UtcNow.Ticks.ToString(),
            Encoding.ASCII
        );
        return 0;
    }

    private static int RunEngine(string[] args)
    {
        if (args.Length == 1 && args[0] == "--non-member-control")
        {
            return RunControl();
        }
        if (args.Length != 0 &&
            (args.Length != 2 || args[0] != "--fixture-child"))
        {
            return 64;
        }

        string claimedParent = args.Length == 2 ? args[1] : "";
        File.WriteAllText(At("engine-parent.txt"), claimedParent, Encoding.ASCII);
        File.WriteAllText(
            At("engine-started.txt"),
            Process.GetCurrentProcess().Id.ToString(),
            Encoding.ASCII
        );
        while (!File.Exists(At("engine-exit.signal"))) Thread.Sleep(25);
        File.WriteAllText(
            At("engine-stopped.txt"),
            DateTime.UtcNow.Ticks.ToString(),
            Encoding.ASCII
        );
        return ExitSetting("engine-exit-code.txt", 0);
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

        int appProcessId = Process.GetCurrentProcess().Id;
        string executable = Process.GetCurrentProcess().MainModule.FileName;
        string enginePath = Path.Combine(
            Path.GetDirectoryName(executable),
            "scanstudio-engine-test.exe"
        );
        ProcessStartInfo engineInfo = new ProcessStartInfo();
        engineInfo.FileName = enginePath;
        engineInfo.UseShellExecute = false;
        engineInfo.CreateNoWindow = true;
        engineInfo.Arguments = "--fixture-child " + appProcessId.ToString();

        using (Process engine = new Process())
        {
            engine.StartInfo = engineInfo;
            if (!engine.Start()) throw new Exception("Could not start fixture engine");
            File.WriteAllText(At("app-engine-id.txt"), engine.Id.ToString(), Encoding.ASCII);

            DateTime engineDeadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < engineDeadline)
            {
                if (engine.HasExited)
                    throw new Exception("Fixture engine exited before reporting ready");
                string engineEvidence = At("engine-started.txt");
                if (File.Exists(engineEvidence) &&
                    File.ReadAllText(engineEvidence).Trim() == engine.Id.ToString())
                {
                    break;
                }
                Thread.Sleep(25);
            }
            if (!File.Exists(At("engine-started.txt")) ||
                File.ReadAllText(At("engine-started.txt")).Trim() != engine.Id.ToString())
            {
                throw new Exception("Fixture engine did not report ready");
            }

            File.WriteAllText(At("app-started.txt"), appProcessId.ToString(), Encoding.ASCII);
            while (!File.Exists(At("app-exit.signal")))
            {
                if (engine.HasExited)
                {
                    File.WriteAllText(
                        At("engine-exited-early.txt"),
                        engine.ExitCode.ToString(),
                        Encoding.ASCII
                    );
                    return 86;
                }
                Thread.Sleep(25);
            }

            File.WriteAllText(At("engine-exit.signal"), "exit", Encoding.ASCII);
            if (!engine.WaitForExit(5000))
            {
                engine.Kill();
                engine.WaitForExit();
                return 87;
            }
            if (engine.ExitCode != 0) return 88;
        }

        File.WriteAllText(At("app-stopped.txt"), DateTime.UtcNow.Ticks.ToString(), Encoding.ASCII);
        return ExitSetting("app-exit-code.txt", 0);
    }

    public static int Main(string[] args)
    {
        string executable = Path.GetFileName(Process.GetCurrentProcess().MainModule.FileName);
        if (String.Equals(executable, "wsl.exe", StringComparison.OrdinalIgnoreCase))
            return RunWsl(args);
        if (executable.StartsWith("scanstudio-engine", StringComparison.OrdinalIgnoreCase))
            return RunEngine(args);
        return RunApp();
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
    Wait-ForFile -Path (Join-Path $stateRoot 'engine-started.txt')
    $engineRefusal = New-LauncherProcess
    Complete-Launcher -Process $engineRefusal -ExpectedExitCode 1
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'wsl-calls.log'))) 'existing engine is refused before invoking WSL or acquiring a latch'
    Signal-FakeEngineExit
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

    # Forced owner death closes the job and must kill both fixture descendants.
    # Retained OS handles make every liveness assertion identity-safe even if a
    # process id is reused. A same-image engine started by this test process is
    # deliberately outside the launcher job and must survive.
    Reset-FakeState
    Set-Content -LiteralPath (Join-Path $stateRoot 'block-release') -Value 'block' -Encoding ascii
    $forcedLauncher = New-LauncherProcess -CleanParentEnvironment
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    Wait-ForFile -Path (Join-Path $stateRoot 'engine-started.txt')
    Wait-ForFile -Path (Join-Path $stateRoot 'acquired.txt')
    $forcedApp = Open-ProcessHandleFromEvidence `
        -EvidencePath (Join-Path $stateRoot 'app-started.txt') `
        -ExpectedExecutable $fakeApp
    $forcedEngine = Open-ProcessHandleFromEvidence `
        -EvidencePath (Join-Path $stateRoot 'engine-started.txt') `
        -ExpectedExecutable $fakeEngine
    $fixtureEngineId = [int](
        Get-Content -LiteralPath (Join-Path $stateRoot 'app-engine-id.txt') -Raw
    )
    Assert-Equal $forcedEngine.Id $fixtureEngineId 'fixture app retains the exact engine process it started'
    Assert-Equal $forcedLauncher.Id (
        [ScanStudio.LauncherTestProcess]::GetParentProcessId($forcedApp.Handle)
    ) 'native process ancestry proves launcher -> fixture app'
    Assert-Equal $forcedApp.Id (
        [ScanStudio.LauncherTestProcess]::GetParentProcessId($forcedEngine.Handle)
    ) 'native process ancestry proves fixture app -> fixture engine'
    $cleanChildEnvironment = Read-KeyValueFile -Path (Join-Path $stateRoot 'app-environment.txt')
    Assert-Equal '1' $cleanChildEnvironment['MOTION'] 'clean-parent child receives only explicit motion authorization'
    Assert-Equal '' $cleanChildEnvironment['STATE'] 'clean-parent child has no state override'
    Assert-Equal '' $cleanChildEnvironment['BRIDGE_BASE'] 'clean-parent child has no bridge-base override'
    Assert-Equal '' $cleanChildEnvironment['WSLENV'] 'clean-parent child has no synthetic WSLENV entries'

    $fixtureControl = New-DirectFakeProcess `
        -Executable $fakeEngine `
        -Arguments '--non-member-control'
    Wait-ForFile -Path (Join-Path $stateRoot 'control-started.txt')
    [void]$fixtureControl.Handle
    $fixtureControlId = [int](
        Get-Content -LiteralPath (Join-Path $stateRoot 'control-started.txt') -Raw
    )
    Assert-Equal $fixtureControl.Id $fixtureControlId 'same-image non-member control reports its retained process handle'
    Assert-ExpectedProcessImage `
        -Process $fixtureControl `
        -ExpectedExecutable $fakeEngine `
        -Message 'same-image non-member control uses the fixture engine executable'
    Assert-Equal ([System.Diagnostics.Process]::GetCurrentProcess().Id) (
        [ScanStudio.LauncherTestProcess]::GetParentProcessId($fixtureControl.Handle)
    ) 'native process ancestry proves the fixture control is outside the launcher tree'
    Assert-True (
        [ScanStudio.LauncherTestProcess]::IsAlive($forcedApp.Handle) -and
        [ScanStudio.LauncherTestProcess]::IsAlive($forcedEngine.Handle) -and
        [ScanStudio.LauncherTestProcess]::IsAlive($fixtureControl.Handle)
    ) 'fixture app, engine descendant, and non-member control are alive before launcher death'

    $forcedLauncher.Kill()
    Wait-ForProcessExit -Process $forcedLauncher
    Wait-ForExactProcessExit `
        -Process $forcedApp `
        -Message 'kill-on-close job terminates the exact fixture app handle'
    Wait-ForExactProcessExit `
        -Process $forcedEngine `
        -Message 'kill-on-close job terminates the exact fixture engine descendant handle'
    Assert-True (
        [ScanStudio.LauncherTestProcess]::IsAlive($fixtureControl.Handle)
    ) 'same-image non-member control survives fixture launcher death'
    Signal-ControlExit
    Wait-ForProcessExit -Process $fixtureControl

    Set-Content -LiteralPath (Join-Path $stateRoot 'allow-release') -Value 'allow' -Encoding ascii
    Wait-ForFile -Path (Join-Path $stateRoot 'release-attempt.txt')
    Wait-ForReleaseCompletionCount -Count 1
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'fake-latch.txt'))) 'guardian removes the matching owned latch after forced launcher death'

    # Installed and portable invocations pass a root containing the actual
    # packaged app and engine. Exercise that real app -> sidecar chain under
    # the packaged launcher, while keeping profile state and WSL calls inside
    # this test's private directory. The source-only invocation has no package.
    $packagedApp = Join-Path $LauncherRoot 'scanstudio-app.exe'
    if (Test-Path -LiteralPath $packagedApp -PathType Leaf) {
        $packagedEngines = @(
            Get-ChildItem -LiteralPath $LauncherRoot -Recurse -File |
                Where-Object { $_.Name -like 'scanstudio-engine*.exe' }
        )
        Assert-Equal 1 $packagedEngines.Count 'packaged launcher root contains one engine sidecar'
        $packagedEngine = $packagedEngines[0].FullName

        Reset-FakeState
        Set-Content -LiteralPath (Join-Path $stateRoot 'block-release') -Value 'block' -Encoding ascii
        $packagedLauncher = New-LauncherProcess `
            -Executable $packagedApp `
            -LauncherPath $sourceLauncher `
            -CleanParentEnvironment `
            -IsolateDesktopProfile
        Wait-ForFile -Path (Join-Path $stateRoot 'acquired.txt')
        [void]$packagedLauncher.Handle
        $packagedAppProcess = Wait-ForExactChildProcessHandle `
            -Parent $packagedLauncher `
            -ExpectedExecutable $packagedApp
        $packagedEngineProcess = Wait-ForExactChildProcessHandle `
            -Parent $packagedAppProcess `
            -ExpectedExecutable $packagedEngine
        Assert-True (
            [ScanStudio.LauncherTestProcess]::IsAlive($packagedAppProcess.Handle) -and
            [ScanStudio.LauncherTestProcess]::IsAlive($packagedEngineProcess.Handle)
        ) 'packaged app and exact engine sidecar handles are alive before launcher death'
        Assert-Equal $packagedLauncher.Id (
            [ScanStudio.LauncherTestProcess]::GetParentProcessId($packagedAppProcess.Handle)
        ) 'native process ancestry proves packaged launcher -> app'
        Assert-Equal $packagedAppProcess.Id (
            [ScanStudio.LauncherTestProcess]::GetParentProcessId($packagedEngineProcess.Handle)
        ) 'native process ancestry proves packaged app -> engine sidecar'

        $packagedControlRoot = Join-Path $fakeBin 'packaged non-member control'
        New-Item -ItemType Directory -Path $packagedControlRoot -Force | Out-Null
        $packagedControlExecutable = Join-Path `
            $packagedControlRoot `
            ([IO.Path]::GetFileName($packagedEngine))
        Copy-Item -LiteralPath $fakeRuntime -Destination $packagedControlExecutable
        $packagedControl = New-DirectFakeProcess `
            -Executable $packagedControlExecutable `
            -Arguments '--non-member-control'
        Wait-ForFile -Path (Join-Path $stateRoot 'control-started.txt')
        [void]$packagedControl.Handle
        Assert-ExpectedProcessImage `
            -Process $packagedControl `
            -ExpectedExecutable $packagedControlExecutable `
            -Message 'packaged same-name non-member control retains its exact executable handle'
        Assert-Equal $packagedEngineProcess.ProcessName $packagedControl.ProcessName 'packaged non-member control uses the exact engine process name'
        Assert-Equal ([System.Diagnostics.Process]::GetCurrentProcess().Id) (
            [ScanStudio.LauncherTestProcess]::GetParentProcessId($packagedControl.Handle)
        ) 'native process ancestry proves the packaged control is outside the launcher tree'

        $packagedLauncher.Kill()
        Wait-ForProcessExit -Process $packagedLauncher
        Wait-ForExactProcessExit `
            -Process $packagedAppProcess `
            -Message 'kill-on-close job terminates the exact packaged app handle'
        Wait-ForExactProcessExit `
            -Process $packagedEngineProcess `
            -Message 'kill-on-close job terminates the exact packaged engine descendant handle'
        Assert-True (
            [ScanStudio.LauncherTestProcess]::IsAlive($packagedControl.Handle)
        ) 'same-name non-member control survives packaged launcher death'
        Signal-ControlExit
        Wait-ForProcessExit -Process $packagedControl

        Set-Content -LiteralPath (Join-Path $stateRoot 'allow-release') -Value 'allow' -Encoding ascii
        Wait-ForFile -Path (Join-Path $stateRoot 'release-attempt.txt')
        Wait-ForReleaseCompletionCount -Count 1
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'fake-latch.txt'))) 'guardian removes the packaged session latch after forced launcher death'
    }
    else {
        Write-Host 'SKIP  packaged app -> engine runtime proof (source launcher root has no packaged app)'
    }

    # The same forced-death path never removes content replaced by another
    # owner before the guardian's ownership check.
    Reset-FakeState
    Set-Content -LiteralPath (Join-Path $stateRoot 'block-release') -Value 'block' -Encoding ascii
    $foreignLauncher = New-LauncherProcess
    Wait-ForFile -Path (Join-Path $stateRoot 'app-started.txt')
    Wait-ForFile -Path (Join-Path $stateRoot 'engine-started.txt')
    Wait-ForFile -Path (Join-Path $stateRoot 'acquired.txt')
    $foreignApp = Open-ProcessHandleFromEvidence `
        -EvidencePath (Join-Path $stateRoot 'app-started.txt') `
        -ExpectedExecutable $fakeApp
    $foreignEngine = Open-ProcessHandleFromEvidence `
        -EvidencePath (Join-Path $stateRoot 'engine-started.txt') `
        -ExpectedExecutable $fakeEngine
    $foreignLauncher.Kill()
    Wait-ForProcessExit -Process $foreignLauncher
    Wait-ForExactProcessExit `
        -Process $foreignApp `
        -Message 'foreign-latch case terminates the exact fixture app handle'
    Wait-ForExactProcessExit `
        -Process $foreignEngine `
        -Message 'foreign-latch case terminates the exact fixture engine handle'

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
