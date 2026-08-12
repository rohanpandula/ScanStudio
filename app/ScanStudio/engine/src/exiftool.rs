//! ExifTool capability detection, target resolution, and argument-array
//! construction for META-03. Every function here is plain and
//! server-independent — no `server.rs`/NDJSON dependency, so Phase 6.1's
//! headless CLI can link this crate in-process and call
//! `detect_exiftool`/`build_exiftool_arguments` directly. This module never
//! mutates the archive file itself (`assert_no_archive_target` is the
//! structural guard that enforces this) and never shells out through
//! anything but `std::process::Command`'s argument-array form — no `sh -c`,
//! no string interpolation, anywhere in this file.

use std::ffi::{OsStr, OsString};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::domain::{
    EngineError, FilmProcess, MetadataOutputBindings, MetadataSet, PartialDate, ProjectFrame,
    ScanProject, ScanReceipt, WrittenFileBinding, WrittenOutputs,
};
use crate::protocol::ErrorCode;

// ---------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------

/// Result of probing for a usable ExifTool binary. `path`/`version` are
/// always present as explicit `null` when `available` is `false` (never
/// omitted), mirroring `protocol::ScannerStatus`'s own "always-present,
/// sometimes-null" convention for optional-but-meaningful fields.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ExifToolDetection {
    pub available: bool,
    pub path: Option<String>,
    pub version: Option<String>,
    #[serde(skip)]
    executable_binding: Option<ExecutableBinding>,
}

#[derive(Clone)]
struct ExecutableBinding {
    canonical_path: String,
    file: WrittenFileBinding,
    approved: Arc<ApprovedExecutable>,
}

#[cfg(unix)]
struct InterpreterBinding {
    canonical_path: PathBuf,
    file: WrittenFileBinding,
    shebang_argument: Option<OsString>,
    is_perl: bool,
    // The interpreter participates in the same approval as the script. Keep
    // its descriptor open for the lifetime of that approval and execute this
    // exact inode rather than reopening `canonical_path` at spawn time.
    held_file: File,
}

#[cfg(unix)]
impl PartialEq for InterpreterBinding {
    fn eq(&self, other: &Self) -> bool {
        self.canonical_path == other.canonical_path
            && self.file == other.file
            && self.shebang_argument == other.shebang_argument
            && self.is_perl == other.is_perl
    }
}

#[cfg(unix)]
impl Eq for InterpreterBinding {}

#[cfg(unix)]
impl std::fmt::Debug for InterpreterBinding {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("InterpreterBinding")
            .field("canonical_path", &self.canonical_path)
            .field("file", &self.file)
            .field("shebang_argument", &self.shebang_argument)
            .field("is_perl", &self.is_perl)
            .finish_non_exhaustive()
    }
}

#[derive(Debug)]
enum ApprovedLaunch {
    #[cfg(unix)]
    Script(InterpreterBinding),
    #[cfg(target_os = "linux")]
    NativeLinux,
    #[cfg(windows)]
    WindowsPath,
}

struct ApprovedExecutable {
    held_file: File,
    held_binding: WrittenFileBinding,
    #[cfg(unix)]
    launch_file: File,
    #[cfg(unix)]
    distribution: Option<ApprovedDistributionSnapshot>,
    launch: ApprovedLaunch,
}

#[cfg(unix)]
#[derive(Debug, Clone)]
struct DistributionSnapshotFile {
    relative_path: PathBuf,
    binding: WrittenFileBinding,
}

#[cfg(unix)]
struct ApprovedDistributionSnapshot {
    parent: File,
    name: OsString,
    path: PathBuf,
    directory: File,
    source_module_root: PathBuf,
    tree_digest: String,
    files: Vec<DistributionSnapshotFile>,
    directories: Vec<PathBuf>,
    launch_path: PathBuf,
}

#[cfg(unix)]
impl std::fmt::Debug for ApprovedDistributionSnapshot {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ApprovedDistributionSnapshot")
            .field("path", &self.path)
            .field("source_module_root", &self.source_module_root)
            .field("tree_digest", &self.tree_digest)
            .field("file_count", &self.files.len())
            .finish_non_exhaustive()
    }
}

impl PartialEq for ExecutableBinding {
    fn eq(&self, other: &Self) -> bool {
        self.canonical_path == other.canonical_path && self.file == other.file
    }
}

impl Eq for ExecutableBinding {}

impl std::fmt::Debug for ExecutableBinding {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ExecutableBinding")
            .field("canonical_path", &self.canonical_path)
            .field("file", &self.file)
            .field("launch", &self.approved.launch)
            .finish_non_exhaustive()
    }
}

fn absent_detection() -> ExifToolDetection {
    ExifToolDetection {
        available: false,
        path: None,
        version: None,
        executable_binding: None,
    }
}

/// Overrides every other candidate when set to a non-empty (trimmed)
/// value — mirrors `server.rs`'s own `SCANSTUDIO_BRIDGE_CMD` convention
/// (unset AND set-but-empty both mean "not configured").
const EXIFTOOL_PATH_ENV_VAR: &str = "SCANSTUDIO_EXIFTOOL_PATH";
const EXIFTOOL_DETECT_TIMEOUT: Duration = Duration::from_secs(2);
const EXIFTOOL_APPLY_TIMEOUT: Duration = Duration::from_secs(30);
const EXIFTOOL_OUTPUT_LIMIT: usize = 1024 * 1024;
const MAX_METADATA_TARGET_BYTES: u64 = 1024 * 1024 * 1024;
const METADATA_HASH_TIMEOUT: Duration = Duration::from_secs(30);
// Low half: active bounded hash workers. High half: workers whose callers
// timed out and which are still draining. A single CAS word closes the old
// check-then-start race without unnecessarily serializing ordinary hashes.
static METADATA_HASH_STATE: AtomicUsize = AtomicUsize::new(0);
const METADATA_HASH_STALL_UNIT: usize = 1_usize << (usize::BITS / 2);

/// Captured result from a bounded ExifTool invocation. Output is never
/// allowed to exceed `EXIFTOOL_OUTPUT_LIMIT` across stdout and stderr.
#[derive(Debug)]
pub struct BoundedCommandOutput {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

fn append_committed_warning(output: &mut BoundedCommandOutput, warning: &str) {
    if !output.stderr.is_empty() && !output.stderr.ends_with(b"\n") {
        output.stderr.push(b'\n');
    }
    output.stderr.extend_from_slice(b"ScanStudio warning: ");
    output.stderr.extend_from_slice(warning.as_bytes());
    output.stderr.push(b'\n');
}

#[cfg(test)]
static EXIFTOOL_ENV_INJECTION_HOOK: std::sync::Mutex<Option<(PathBuf, Vec<(OsString, OsString)>)>> =
    std::sync::Mutex::new(None);

#[cfg(test)]
fn set_exiftool_env_injection_hook(path: PathBuf, values: Vec<(OsString, OsString)>) {
    *EXIFTOOL_ENV_INJECTION_HOOK.lock().unwrap() = Some((path, values));
}

fn subprocess_error(message: impl Into<String>) -> EngineError {
    EngineError::new(ErrorCode::Internal, message).with_recoverable(true)
}

fn configure_process_launch(command: &mut Command) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        // Keep the primary thread dormant until it has been assigned to the
        // kill-on-close Job Object. This closes the spawn/assign escape race.
        command.creation_flags(windows_job::CREATE_SUSPENDED);
    }
}

#[cfg(windows)]
mod windows_job {
    use std::ffi::c_void;
    use std::mem::{offset_of, size_of};
    use std::os::windows::io::AsRawHandle as _;
    use std::ptr;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::{subprocess_error, Child, EngineError};

    type Handle = *mut c_void;

    pub(super) const CREATE_SUSPENDED: u32 = 0x0000_0004;
    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: i32 = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;
    const TH32CS_SNAPTHREAD: u32 = 0x0000_0004;
    const THREAD_SUSPEND_RESUME: u32 = 0x0000_0002;
    const ERROR_NO_MORE_FILES: i32 = 18;
    const ERROR_BAD_LENGTH: i32 = 24;
    const INVALID_SUSPEND_COUNT: u32 = u32::MAX;
    const THREAD_DISCOVERY_TIMEOUT: Duration = Duration::from_secs(1);
    const MAX_THREAD_SNAPSHOT_ATTEMPTS: usize = 8;
    const MAX_THREAD_SNAPSHOT_ENTRIES: usize = 131_072;

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectBasicLimitInformation {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    }

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectExtendedLimitInformation {
        basic_limit_information: JobObjectBasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    }

    #[repr(C)]
    #[derive(Default)]
    struct ThreadEntry32 {
        size: u32,
        usage_count: u32,
        thread_id: u32,
        owner_process_id: u32,
        base_priority: i32,
        priority_delta: i32,
        flags: u32,
    }

    // These are the Win32 ABI layouts from winnt.h/tlhelp32.h. Keeping the
    // checks beside the direct FFI makes an accidental field/order/type drift
    // a Windows compile failure instead of a runtime containment failure.
    const _: () = assert!(size_of::<ThreadEntry32>() == 28);
    const _: () = assert!(offset_of!(ThreadEntry32, owner_process_id) == 12);
    #[cfg(target_pointer_width = "64")]
    const _: () = assert!(size_of::<JobObjectBasicLimitInformation>() == 64);
    #[cfg(target_pointer_width = "64")]
    const _: () = assert!(size_of::<JobObjectExtendedLimitInformation>() == 144);

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(job_attributes: *const c_void, name: *const u16) -> Handle;
        fn SetInformationJobObject(
            job: Handle,
            information_class: i32,
            information: *const c_void,
            information_length: u32,
        ) -> i32;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
        fn TerminateJobObject(job: Handle, exit_code: u32) -> i32;
        fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) -> Handle;
        fn Thread32First(snapshot: Handle, entry: *mut ThreadEntry32) -> i32;
        fn Thread32Next(snapshot: Handle, entry: *mut ThreadEntry32) -> i32;
        fn OpenThread(access: u32, inherit_handle: i32, thread_id: u32) -> Handle;
        fn ResumeThread(thread: Handle) -> u32;
        fn CloseHandle(object: Handle) -> i32;
    }

    struct OwnedHandle(Handle);

    impl OwnedHandle {
        fn raw(&self) -> Handle {
            self.0
        }
    }

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }

    fn discover_suspended_primary_thread(process_id: u32) -> Result<OwnedHandle, EngineError> {
        let deadline = Instant::now() + THREAD_DISCOVERY_TIMEOUT;
        let required_entry_size = offset_of!(ThreadEntry32, owner_process_id) + size_of::<u32>();

        for attempt in 0..MAX_THREAD_SNAPSHOT_ATTEMPTS {
            if Instant::now() >= deadline {
                break;
            }

            let snapshot_raw = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
            if snapshot_raw as isize == -1 {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() == Some(ERROR_BAD_LENGTH)
                    && attempt + 1 < MAX_THREAD_SNAPSHOT_ATTEMPTS
                {
                    thread::yield_now();
                    continue;
                }
                return Err(subprocess_error(format!(
                    "failed to snapshot threads for suspended ExifTool: {error}"
                )));
            }
            let snapshot = OwnedHandle(snapshot_raw);
            let mut entry = ThreadEntry32 {
                size: size_of::<ThreadEntry32>() as u32,
                ..ThreadEntry32::default()
            };
            if unsafe { Thread32First(snapshot.raw(), &raw mut entry) } == 0 {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() == Some(ERROR_NO_MORE_FILES)
                    && attempt + 1 < MAX_THREAD_SNAPSHOT_ATTEMPTS
                {
                    thread::yield_now();
                    continue;
                }
                return Err(subprocess_error(format!(
                    "failed to enumerate threads for suspended ExifTool: {error}"
                )));
            }

            let mut matching_thread = None;
            let mut examined = 0_usize;
            loop {
                examined += 1;
                if examined > MAX_THREAD_SNAPSHOT_ENTRIES || Instant::now() >= deadline {
                    return Err(subprocess_error(
                        "thread discovery for suspended ExifTool exceeded its fixed bound",
                    ));
                }
                if (entry.size as usize) < required_entry_size {
                    return Err(subprocess_error(
                        "Windows returned a truncated thread snapshot entry",
                    ));
                }
                if entry.owner_process_id == process_id {
                    if entry.thread_id == 0 || matching_thread.replace(entry.thread_id).is_some() {
                        return Err(subprocess_error(
                            "suspended ExifTool did not have exactly one primary thread",
                        ));
                    }
                }

                // Toolhelp may reduce `size`; restore the full buffer size for
                // every subsequent call as required by the THREADENTRY32 API.
                entry.size = size_of::<ThreadEntry32>() as u32;
                if unsafe { Thread32Next(snapshot.raw(), &raw mut entry) } == 0 {
                    let error = std::io::Error::last_os_error();
                    if error.raw_os_error() != Some(ERROR_NO_MORE_FILES) {
                        return Err(subprocess_error(format!(
                            "failed while enumerating suspended ExifTool threads: {error}"
                        )));
                    }
                    break;
                }
            }

            if let Some(thread_id) = matching_thread {
                let thread_handle = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, thread_id) };
                if thread_handle.is_null() {
                    return Err(subprocess_error(format!(
                        "failed to open suspended ExifTool primary thread: {}",
                        std::io::Error::last_os_error()
                    )));
                }
                return Ok(OwnedHandle(thread_handle));
            }

            if attempt + 1 < MAX_THREAD_SNAPSHOT_ATTEMPTS {
                thread::yield_now();
            }
        }

        Err(subprocess_error(
            "could not locate suspended ExifTool primary thread within the fixed bound",
        ))
    }

    /// Owns a Windows Job Object that kills every assigned process when the
    /// handle closes. The object is created before ExifTool is spawned in a
    /// suspended state, then the child is assigned and resumed before any
    /// output reader starts.
    pub(super) struct Job {
        handle: Handle,
    }

    impl Job {
        pub(super) fn new() -> Result<Self, EngineError> {
            let handle = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
            if handle.is_null() {
                return Err(subprocess_error(format!(
                    "failed to create ExifTool Windows Job Object: {}",
                    std::io::Error::last_os_error()
                )));
            }

            let mut limits = JobObjectExtendedLimitInformation::default();
            limits.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let configured = unsafe {
                SetInformationJobObject(
                    handle,
                    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                    (&raw const limits).cast(),
                    size_of::<JobObjectExtendedLimitInformation>() as u32,
                )
            };
            if configured == 0 {
                let error = std::io::Error::last_os_error();
                unsafe {
                    let _ = CloseHandle(handle);
                }
                return Err(subprocess_error(format!(
                    "failed to configure ExifTool Windows Job Object: {error}"
                )));
            }

            Ok(Self { handle })
        }

        pub(super) fn assign(&self, child: &Child) -> Result<(), EngineError> {
            let assigned = unsafe { AssignProcessToJobObject(self.handle, child.as_raw_handle()) };
            if assigned == 0 {
                return Err(subprocess_error(format!(
                    "failed to assign ExifTool to its Windows Job Object: {}",
                    std::io::Error::last_os_error()
                )));
            }
            Ok(())
        }

        pub(super) fn resume_primary_thread(&self, child: &Child) -> Result<(), EngineError> {
            let thread = discover_suspended_primary_thread(child.id())?;
            let previous_suspend_count = unsafe { ResumeThread(thread.raw()) };
            if previous_suspend_count == INVALID_SUSPEND_COUNT {
                return Err(subprocess_error(format!(
                    "failed to resume contained ExifTool primary thread: {}",
                    std::io::Error::last_os_error()
                )));
            }
            if previous_suspend_count != 1 {
                return Err(subprocess_error(format!(
                    "contained ExifTool primary thread had unexpected suspend count {previous_suspend_count}"
                )));
            }
            Ok(())
        }

        pub(super) fn terminate(&self) {
            // Termination is asynchronous from the caller's perspective; the
            // common runner performs the same fixed one-second child wait and
            // output-drain bound used by the Unix process-group path.
            unsafe {
                let _ = TerminateJobObject(self.handle, 1);
            }
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is the final fail-closed
            // containment boundary for descendants that outlive ExifTool.
            unsafe {
                let _ = CloseHandle(self.handle);
            }
        }
    }
}

struct ProcessContainment {
    #[cfg(windows)]
    job: windows_job::Job,
}

impl ProcessContainment {
    fn new() -> Result<Self, EngineError> {
        #[cfg(windows)]
        {
            return Ok(Self {
                job: windows_job::Job::new()?,
            });
        }
        #[cfg(not(windows))]
        {
            Ok(Self {})
        }
    }

    fn activate(&self, child: &Child) -> Result<(), EngineError> {
        #[cfg(windows)]
        {
            self.job.assign(child)?;
            self.job.resume_primary_thread(child)?;
        }
        #[cfg(not(windows))]
        {
            let _ = child;
        }
        Ok(())
    }

    fn terminate(&self, child: &mut Child) {
        #[cfg(unix)]
        unsafe {
            // The child is the leader of the process group configured above.
            // Kill the whole group so descendants retaining stdout/stderr
            // cannot keep the bounded reader threads alive after a deadline.
            let _ = libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
        #[cfg(windows)]
        self.job.terminate();
        // Keep the direct-child wait bounded even if process-tree termination
        // itself fails. Dropping the Windows Job remains a final kill boundary.
        let _ = child.kill();
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if child.try_wait().ok().flatten().is_some() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}

fn terminate_process_group(child: &mut Child, containment: &ProcessContainment) {
    containment.terminate(child);
}

fn read_pipe_bounded<R: Read>(
    mut reader: R,
    total: Arc<AtomicUsize>,
    overflowed: Arc<AtomicBool>,
    limit: usize,
) -> Result<Vec<u8>, std::io::Error> {
    let mut captured = Vec::new();
    let mut chunk = [0_u8; 16 * 1024];
    loop {
        let count = reader.read(&mut chunk)?;
        if count == 0 {
            return Ok(captured);
        }
        let prior = total.fetch_add(count, Ordering::AcqRel);
        let remaining = limit.saturating_sub(prior);
        captured.extend_from_slice(&chunk[..count.min(remaining)]);
        if count > remaining {
            overflowed.store(true, Ordering::Release);
        }
    }
}

type PipeReadResult = Result<Vec<u8>, std::io::Error>;

fn collect_reader_results(
    stdout_rx: &mpsc::Receiver<PipeReadResult>,
    stderr_rx: &mpsc::Receiver<PipeReadResult>,
    stdout: &mut Option<PipeReadResult>,
    stderr: &mut Option<PipeReadResult>,
    grace: Duration,
) -> bool {
    let deadline = Instant::now() + grace;
    loop {
        if stdout.is_none() {
            match stdout_rx.try_recv() {
                Ok(result) => *stdout = Some(result),
                Err(mpsc::TryRecvError::Disconnected) => {
                    *stdout = Some(Err(std::io::Error::other(
                        "ExifTool stdout reader stopped without a result",
                    )))
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        if stderr.is_none() {
            match stderr_rx.try_recv() {
                Ok(result) => *stderr = Some(result),
                Err(mpsc::TryRecvError::Disconnected) => {
                    *stderr = Some(Err(std::io::Error::other(
                        "ExifTool stderr reader stopped without a result",
                    )))
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        if stdout.is_some() && stderr.is_some() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(5));
    }
}

fn run_bounded_command_inner(
    executable: &ExecutableBinding,
    arguments: &[String],
    timeout: Duration,
    output_limit: usize,
    sanitize_exiftool_environment: bool,
) -> Result<BoundedCommandOutput, EngineError> {
    // Windows configures its fail-closed Job Object before spawning a
    // suspended process; activation happens only after assignment succeeds.
    let containment = ProcessContainment::new()?;
    #[cfg(unix)]
    let mut command = {
        use std::os::fd::AsRawFd as _;
        use std::os::unix::process::CommandExt as _;

        const CHILD_EXECUTABLE_FD: libc::c_int = 198;
        let descriptor_path = format!("/dev/fd/{CHILD_EXECUTABLE_FD}");
        let mut command = match &executable.approved.launch {
            ApprovedLaunch::Script(interpreter) => {
                // Interpreter paths are separately bound and restricted to
                // root-owned, non-writable, non-symlink components. The
                // approved ExifTool script itself is still executed only from
                // the exact inherited descriptor below.
                let mut command = Command::new(&interpreter.canonical_path);
                if let Some(argument) = &interpreter.shebang_argument {
                    command.arg(argument);
                }
                if interpreter.is_perl {
                    // Perl's normal script launch would set `$0` to
                    // `/dev/fd/198`, breaking ExifTool's adjacent-resource
                    // discovery. `do` compiles the held script only after `$0`
                    // is restored to the approved canonical display path.
                    command
                        .arg("-e")
                        .arg("$0=shift @ARGV; my $f=shift @ARGV; my $r=do $f; if (!defined $r) { die(($@ ne q{}) ? $@ : $!); }")
                        .arg(
                            executable
                                .approved
                                .distribution
                                .as_ref()
                                .map(|snapshot| snapshot.launch_path.as_path())
                                .unwrap_or_else(|| Path::new(&executable.canonical_path)),
                        )
                        .arg(&descriptor_path);
                } else {
                    command.arg(&descriptor_path);
                }
                command
            }
            #[cfg(target_os = "linux")]
            ApprovedLaunch::NativeLinux => {
                Command::new(format!("/proc/self/fd/{CHILD_EXECUTABLE_FD}"))
            }
            #[cfg(windows)]
            ApprovedLaunch::WindowsPath => unreachable!(),
        };
        let approved = Arc::clone(&executable.approved);
        let approved_fd = approved.launch_file.as_raw_fd();
        unsafe {
            command.pre_exec(move || {
                // Duplicate through descriptors above the fixed child slots.
                // Besides retaining CLOEXEC until the final dup2, this avoids
                // clobbering a source if the parent happened to allocate one
                // of the fixed descriptor numbers already.
                unsafe fn inherit_exact_fd(
                    source: libc::c_int,
                    destination: libc::c_int,
                ) -> std::io::Result<()> {
                    let temporary = libc::fcntl(source, libc::F_DUPFD_CLOEXEC, 199);
                    if temporary < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    if libc::dup2(temporary, destination) < 0 {
                        let error = std::io::Error::last_os_error();
                        libc::close(temporary);
                        return Err(error);
                    }
                    libc::close(temporary);
                    if libc::lseek(destination, 0, libc::SEEK_SET) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                }
                inherit_exact_fd(approved_fd, CHILD_EXECUTABLE_FD)?;
                Ok(())
            });
        }
        command
    };
    #[cfg(windows)]
    let mut command = match &executable.approved.launch {
        ApprovedLaunch::WindowsPath => Command::new(&executable.canonical_path),
    };
    #[cfg(not(any(unix, windows)))]
    return Err(subprocess_error(
        "exact-descriptor ExifTool execution is unsupported on this platform",
    ));
    #[cfg(test)]
    if sanitize_exiftool_environment {
        let mut hook = EXIFTOOL_ENV_INJECTION_HOOK.lock().unwrap();
        let matches = hook
            .as_ref()
            .is_some_and(|(path, _)| path == Path::new(&executable.canonical_path));
        if matches {
            let (_, values) = hook.take().expect("matching environment hook is present");
            // Inject before the production sanitizer so tests can prove that
            // even explicitly inherited attacker values are removed.
            command.envs(values);
        }
    }
    if sanitize_exiftool_environment {
        command.env_clear();
        command.env("LANG", "C");
        command.env("LC_ALL", "C");
        command.env("TZ", "UTC");
        #[cfg(unix)]
        if let Some(distribution) = &executable.approved.distribution {
            command.env("HOME", &distribution.path);
            command.env("TMPDIR", &distribution.path);
            command.current_dir(&distribution.path);
        }
    }
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_process_launch(&mut command);
    let mut child = command.spawn().map_err(|error| {
        subprocess_error(format!(
            "failed to spawn approved ExifTool '{}': {error}",
            executable.canonical_path
        ))
    })?;
    if let Err(error) = containment.activate(&child) {
        containment.terminate(&mut child);
        return Err(error);
    }
    let stdout = child
        .stdout
        .take()
        .expect("piped ExifTool stdout must be present");
    let stderr = child
        .stderr
        .take()
        .expect("piped ExifTool stderr must be present");
    let total = Arc::new(AtomicUsize::new(0));
    let overflowed = Arc::new(AtomicBool::new(false));

    let stdout_total = Arc::clone(&total);
    let stdout_overflowed = Arc::clone(&overflowed);
    let (stdout_tx, stdout_rx) = mpsc::sync_channel(1);
    let _stdout_reader = thread::spawn(move || {
        let _ = stdout_tx.send(read_pipe_bounded(
            stdout,
            stdout_total,
            stdout_overflowed,
            output_limit,
        ));
    });
    let stderr_total = Arc::clone(&total);
    let stderr_overflowed = Arc::clone(&overflowed);
    let (stderr_tx, stderr_rx) = mpsc::sync_channel(1);
    let _stderr_reader = thread::spawn(move || {
        let _ = stderr_tx.send(read_pipe_bounded(
            stderr,
            stderr_total,
            stderr_overflowed,
            output_limit,
        ));
    });

    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let status = loop {
        if overflowed.load(Ordering::Acquire) {
            terminate_process_group(&mut child, &containment);
            break None;
        }
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                timed_out = true;
                terminate_process_group(&mut child, &containment);
                break None;
            }
            Err(error) => {
                terminate_process_group(&mut child, &containment);
                return Err(subprocess_error(format!(
                    "failed while waiting for ExifTool: {error}"
                )));
            }
        }
    };

    // A normal process whose pipes close promptly needs no containment
    // signal. If the direct child exited while a descendant retained either
    // pipe, the short grace expires and only then is its Unix process group or
    // Windows Job terminated. This avoids signaling a recycled Unix PGID after
    // a normal exit while keeping reader completion bounded on both platforms.
    let mut stdout_result = None;
    let mut stderr_result = None;
    if status.is_some()
        && !timed_out
        && !overflowed.load(Ordering::Acquire)
        && !collect_reader_results(
            &stdout_rx,
            &stderr_rx,
            &mut stdout_result,
            &mut stderr_result,
            Duration::from_millis(100),
        )
    {
        terminate_process_group(&mut child, &containment);
    }
    if !collect_reader_results(
        &stdout_rx,
        &stderr_rx,
        &mut stdout_result,
        &mut stderr_result,
        Duration::from_secs(1),
    ) {
        return Err(subprocess_error(
            "ExifTool output pipes did not close after bounded process-tree termination",
        ));
    }
    let stdout = stdout_result
        .expect("reader collection requires stdout")
        .map_err(|error| subprocess_error(format!("failed reading ExifTool stdout: {error}")))?;
    let stderr = stderr_result
        .expect("reader collection requires stderr")
        .map_err(|error| subprocess_error(format!("failed reading ExifTool stderr: {error}")))?;

    if timed_out {
        return Err(subprocess_error(format!(
            "ExifTool exceeded its {} second deadline and was terminated",
            timeout.as_secs_f64()
        )));
    }
    if overflowed.load(Ordering::Acquire) {
        return Err(subprocess_error(format!(
            "ExifTool emitted more than {output_limit} bytes and was terminated"
        )));
    }
    Ok(BoundedCommandOutput {
        status: status.expect("a non-timeout, non-overflow command has an exit status"),
        stdout,
        stderr,
    })
}

fn run_bounded_command(
    executable: &ExecutableBinding,
    arguments: &[String],
    timeout: Duration,
    output_limit: usize,
) -> Result<BoundedCommandOutput, EngineError> {
    run_bounded_command_inner(executable, arguments, timeout, output_limit, false)
}

fn run_bounded_exiftool_command(
    executable: &ExecutableBinding,
    arguments: &[String],
    timeout: Duration,
    output_limit: usize,
) -> Result<BoundedCommandOutput, EngineError> {
    let mut configured = Vec::with_capacity(arguments.len() + 2);
    // ExifTool processes -config only before any other option. An explicit
    // empty filename disables every default ~/.ExifTool_config lookup.
    configured.push("-config".to_string());
    configured.push(String::new());
    configured.extend_from_slice(arguments);
    run_bounded_command_inner(executable, &configured, timeout, output_limit, true)
}

/// Runs the write-capable invocation behind a fixed deadline, a combined
/// stdout/stderr memory cap, and process-group termination.
pub fn execute_exiftool(
    detection: &ExifToolDetection,
    arguments: &[String],
) -> Result<BoundedCommandOutput, EngineError> {
    let executable = verify_executable_binding(detection)?;
    run_bounded_exiftool_command(
        executable,
        arguments,
        EXIFTOOL_APPLY_TIMEOUT,
        EXIFTOOL_OUTPUT_LIMIT,
    )
}

/// Detects whether ExifTool is installed and usable. Tries, in order:
/// `SCANSTUDIO_EXIFTOOL_PATH` (if set to a non-empty value, that exact path
/// only — no fallback if it fails), then the bare `"exiftool"` name resolved
/// by the child process's `PATH`. The first candidate that spawns
/// `<candidate> -ver` successfully (exit 0, stdout captured as the version
/// string) wins.
///
/// Every candidate is probed read-only (`-ver` only, never a write-capable
/// invocation). Total failure — ExifTool genuinely absent, or every
/// candidate unusable — degrades to `ExifToolDetection { available: false,
/// .. }`; this function never panics and never returns an `Err`, matching
/// META-03's "detection degrades gracefully" requirement.
pub fn detect_exiftool() -> ExifToolDetection {
    if let Ok(env_path) = std::env::var(EXIFTOOL_PATH_ENV_VAR) {
        if !env_path.trim().is_empty() {
            return probe_candidate(&env_path).unwrap_or_else(absent_detection);
        }
    }
    probe_candidate("exiftool").unwrap_or_else(absent_detection)
}

/// Spawns `<candidate> -ver` and returns `Some(..available: true..)` on a
/// clean exit; `None` on any spawn failure or non-zero exit. Never panics.
fn probe_candidate(candidate: &str) -> Option<ExifToolDetection> {
    let executable = resolve_executable(candidate)?;
    let binding = bind_executable(&executable).ok()?;
    let executable = binding.canonical_path.clone();
    let output = run_bounded_exiftool_command(
        &binding,
        &["-ver".to_string()],
        EXIFTOOL_DETECT_TIMEOUT,
        EXIFTOOL_OUTPUT_LIMIT,
    )
    .ok()?;
    if !output.status.success() {
        return None;
    }
    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Some(ExifToolDetection {
        available: true,
        path: Some(executable),
        version: Some(version),
        executable_binding: Some(binding),
    })
}

fn resolve_executable(candidate: &str) -> Option<PathBuf> {
    let candidate_path = Path::new(candidate);
    if candidate_path.is_absolute() || candidate_path.components().count() > 1 {
        return std::fs::canonicalize(candidate_path).ok();
    }
    let path = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path) {
        let executable = directory.join(candidate);
        if let Ok(canonical) = std::fs::canonicalize(&executable) {
            if canonical.is_file() {
                return Some(canonical);
            }
        }
        #[cfg(windows)]
        for extension in ["exe"] {
            if let Ok(canonical) = std::fs::canonicalize(executable.with_extension(extension)) {
                if canonical.is_file() {
                    return Some(canonical);
                }
            }
        }
    }
    None
}

fn bind_executable(path: &Path) -> Result<ExecutableBinding, EngineError> {
    let canonical = std::fs::canonicalize(path).map_err(|error| {
        subprocess_error(format!(
            "cannot resolve ExifTool executable {}: {error}",
            path.display()
        ))
    })?;
    #[cfg(windows)]
    if !canonical
        .extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
    {
        return Err(subprocess_error(
            "Windows ExifTool approval accepts only a native .exe image; command scripts and delegated interpreters are refused",
        ));
    }
    canonical
        .parent()
        .ok_or_else(|| subprocess_error("ExifTool executable has no containing directory"))?;
    let file_name = canonical
        .file_name()
        .ok_or_else(|| subprocess_error("ExifTool executable has no file name"))?;
    let mut held_file = open_executable_nofollow(&canonical).map_err(|error| {
        subprocess_error(format!("cannot hold ExifTool executable identity: {error}"))
    })?;
    ensure_supported_metadata_filesystem(&held_file).map_err(|error| {
        subprocess_error(format!(
            "ExifTool executable filesystem cannot provide stable identity authority: {error}"
        ))
    })?;
    let file = binding_from_open_file(
        &mut held_file,
        file_name
            .to_str()
            .ok_or_else(|| subprocess_error("ExifTool executable name is not UTF-8"))?,
    )
    .map_err(|error| {
        subprocess_error(format!("cannot bind ExifTool executable identity: {error}"))
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        if std::fs::metadata(&canonical)
            .map(|metadata| metadata.permissions().mode() & 0o111 == 0)
            .unwrap_or(true)
        {
            return Err(subprocess_error("resolved ExifTool file is not executable"));
        }
    }
    #[cfg(unix)]
    let launch = bind_unix_launch(&mut held_file)?;
    #[cfg(unix)]
    let (launch_file, distribution) = match &launch {
        ApprovedLaunch::Script(interpreter) if interpreter.is_perl => {
            let snapshot = ApprovedDistributionSnapshot::create(&canonical, &mut held_file, &file)?;
            let launch_file = snapshot.open_launch()?;
            (launch_file, Some(snapshot))
        }
        ApprovedLaunch::Script(_) => {
            #[cfg(not(test))]
            return Err(subprocess_error(
                "ExifTool script launchers must use the separately bound Perl interpreter",
            ));
            #[cfg(test)]
            {
                let launch_file = held_file.try_clone().map_err(|error| {
                    subprocess_error(format!(
                        "cannot retain approved test launch descriptor: {error}"
                    ))
                })?;
                (launch_file, None)
            }
        }
        #[cfg(target_os = "linux")]
        ApprovedLaunch::NativeLinux => {
            let launch_file = held_file.try_clone().map_err(|error| {
                subprocess_error(format!(
                    "cannot retain approved ExifTool launch descriptor: {error}"
                ))
            })?;
            (launch_file, None)
        }
    };
    #[cfg(unix)]
    let approved = ApprovedExecutable {
        launch,
        held_binding: file.clone(),
        launch_file,
        distribution,
        held_file,
    };
    #[cfg(windows)]
    let approved = ApprovedExecutable {
        launch: ApprovedLaunch::WindowsPath,
        held_binding: file.clone(),
        held_file,
    };
    #[cfg(not(any(unix, windows)))]
    return Err(subprocess_error(
        "approved ExifTool snapshots are unsupported on this platform",
    ));
    Ok(ExecutableBinding {
        canonical_path: canonical.display().to_string(),
        file,
        approved: Arc::new(approved),
    })
}

#[cfg(unix)]
fn bind_unix_launch(source: &mut File) -> Result<ApprovedLaunch, EngineError> {
    source.seek(SeekFrom::Start(0)).map_err(|error| {
        subprocess_error(format!("cannot rewind approved ExifTool source: {error}"))
    })?;
    let mut prefix = [0_u8; 4096];
    let count = source.read(&mut prefix).map_err(|error| {
        subprocess_error(format!("cannot inspect approved ExifTool header: {error}"))
    })?;
    source.seek(SeekFrom::Start(0)).map_err(|error| {
        subprocess_error(format!(
            "cannot rewind approved ExifTool descriptor: {error}"
        ))
    })?;
    if prefix[..count].starts_with(b"#!") {
        let line_end = prefix[..count]
            .iter()
            .position(|byte| *byte == b'\n')
            .unwrap_or(count);
        let line = std::str::from_utf8(&prefix[2..line_end])
            .map_err(|_| subprocess_error("ExifTool shebang is not valid UTF-8"))?;
        let mut fields = line.trim().split_ascii_whitespace();
        let interpreter = fields
            .next()
            .ok_or_else(|| subprocess_error("ExifTool shebang has no interpreter"))?;
        let shebang_argument = fields.next().map(OsString::from);
        if fields.next().is_some() {
            return Err(subprocess_error(
                "ExifTool shebang has more than one interpreter argument",
            ));
        }
        return Ok(ApprovedLaunch::Script(bind_secure_interpreter(
            Path::new(interpreter),
            shebang_argument,
        )?));
    }
    #[cfg(target_os = "linux")]
    return Ok(ApprovedLaunch::NativeLinux);
    #[cfg(not(target_os = "linux"))]
    Err(subprocess_error(
        "this platform can execute only held script descriptors for ExifTool",
    ))
}

#[cfg(unix)]
fn bind_secure_interpreter(
    path: &Path,
    shebang_argument: Option<OsString>,
) -> Result<InterpreterBinding, EngineError> {
    use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

    if !path.is_absolute() {
        return Err(subprocess_error(
            "ExifTool shebang interpreter must be an absolute path",
        ));
    }
    let canonical = std::fs::canonicalize(path).map_err(|error| {
        subprocess_error(format!("cannot resolve ExifTool interpreter: {error}"))
    })?;
    let mut current = PathBuf::from("/");
    for component in canonical.components() {
        match component {
            Component::RootDir => continue,
            Component::Normal(component) => current.push(component),
            _ => {
                return Err(subprocess_error(
                    "ExifTool interpreter path contains a non-normal component",
                ))
            }
        }
        let metadata = std::fs::symlink_metadata(&current).map_err(|error| {
            subprocess_error(format!("cannot inspect ExifTool interpreter path: {error}"))
        })?;
        if metadata.file_type().is_symlink()
            || metadata.uid() != 0
            || metadata.permissions().mode() & 0o022 != 0
        {
            return Err(subprocess_error(format!(
                "ExifTool interpreter path is not rooted in root-owned, non-writable components: {}",
                current.display()
            )));
        }
    }
    let name = canonical
        .file_name()
        .ok_or_else(|| subprocess_error("ExifTool interpreter has no file name"))?;
    if name == OsStr::new("env") {
        return Err(subprocess_error(
            "ExifTool shebang may not delegate interpreter selection through env",
        ));
    }
    let mut held = open_executable_nofollow(&canonical)
        .map_err(|error| subprocess_error(format!("cannot hold ExifTool interpreter: {error}")))?;
    let file = binding_from_open_file(
        &mut held,
        name.to_str()
            .ok_or_else(|| subprocess_error("ExifTool interpreter name is not UTF-8"))?,
    )?;
    let is_perl = name.to_string_lossy().starts_with("perl");
    Ok(InterpreterBinding {
        canonical_path: canonical,
        file,
        shebang_argument,
        is_perl,
        held_file: held,
    })
}

#[cfg(unix)]
const MAX_EXIFTOOL_DISTRIBUTION_FILES: usize = 4096;
#[cfg(unix)]
const MAX_EXIFTOOL_DISTRIBUTION_BYTES: u64 = 256 * 1024 * 1024;
#[cfg(unix)]
const MAX_EXIFTOOL_DISTRIBUTION_DEPTH: usize = 64;

#[cfg(unix)]
fn read_approved_script(source: &mut File, expected_len: u64) -> Result<Vec<u8>, EngineError> {
    if expected_len > 16 * 1024 * 1024 {
        return Err(subprocess_error(
            "ExifTool launcher exceeds the fixed script size bound",
        ));
    }
    source.seek(SeekFrom::Start(0)).map_err(|error| {
        subprocess_error(format!("cannot rewind approved ExifTool launcher: {error}"))
    })?;
    let mut bytes = Vec::new();
    source
        .take(expected_len.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| {
            subprocess_error(format!("cannot read approved ExifTool launcher: {error}"))
        })?;
    if bytes.len() as u64 != expected_len {
        return Err(subprocess_error(
            "approved ExifTool launcher changed length while being snapshotted",
        ));
    }
    Ok(bytes)
}

#[cfg(unix)]
fn module_root_contains_exiftool(path: &Path) -> bool {
    let Ok(root) = metadata_publish_sys::open_directory(path) else {
        return false;
    };
    let Ok(image) = metadata_publish_sys::open_child_directory(&root, OsStr::new("Image")) else {
        return false;
    };
    metadata_publish_sys::open_regular(&image, OsStr::new("ExifTool.pm")).is_ok()
}

#[cfg(unix)]
fn discover_exiftool_module_root(executable: &Path, script: &str) -> Result<PathBuf, EngineError> {
    if !script.contains("Image::ExifTool") {
        return Err(subprocess_error(
            "approved Perl launcher does not identify an ExifTool module distribution",
        ));
    }
    let mut candidates = Vec::new();
    // Homebrew patches absolute `unshift @INC, "..."` roots into the
    // launcher. Consider literal absolute quoted paths first because these
    // override a normal adjacent `lib` directory at runtime.
    for line in script.lines().filter(|line| line.contains("@INC")) {
        let mut remainder = line;
        while let Some(start) = remainder.find('"') {
            remainder = &remainder[start + 1..];
            let Some(end) = remainder.find('"') else {
                break;
            };
            let value = &remainder[..end];
            if value.starts_with('/') && !value.contains('$') {
                candidates.push(PathBuf::from(value));
            }
            remainder = &remainder[end + 1..];
        }
    }
    let parent = executable
        .parent()
        .ok_or_else(|| subprocess_error("ExifTool launcher has no distribution directory"))?;
    candidates.push(parent.join("lib"));
    if let Some(package) = parent.parent() {
        candidates.push(package.join("lib"));
        candidates.push(package.join("libexec/lib/perl5"));
    }

    let mut seen = std::collections::HashSet::new();
    for candidate in candidates {
        let Ok(canonical) = std::fs::canonicalize(&candidate) else {
            continue;
        };
        if seen.insert(canonical.clone()) && module_root_contains_exiftool(&canonical) {
            return Ok(canonical);
        }
    }
    Err(subprocess_error(
        "ExifTool Perl module/resource tree could not be anchored; refusing a launcher-only approval",
    ))
}

#[cfg(unix)]
fn module_root_launcher_literals(script: &str, canonical_root: &Path) -> Vec<String> {
    let mut literals = vec![canonical_root.to_string_lossy().into_owned()];
    for line in script.lines().filter(|line| line.contains("@INC")) {
        let mut remainder = line;
        while let Some(start) = remainder.find('"') {
            remainder = &remainder[start + 1..];
            let Some(end) = remainder.find('"') else {
                break;
            };
            let value = &remainder[..end];
            if value.starts_with('/')
                && !value.contains('$')
                && std::fs::canonicalize(value).is_ok_and(|candidate| candidate == canonical_root)
            {
                literals.push(value.to_string());
            }
            remainder = &remainder[end + 1..];
        }
    }
    literals.sort_by_key(|value| std::cmp::Reverse(value.len()));
    literals.dedup();
    literals
}

#[cfg(unix)]
fn copy_exiftool_distribution_tree(
    source: &File,
    destination: &File,
    relative_prefix: &Path,
    files: &mut Vec<DistributionSnapshotFile>,
    directories: &mut Vec<PathBuf>,
    total_bytes: &mut u64,
    depth: usize,
) -> Result<(), EngineError> {
    if depth > MAX_EXIFTOOL_DISTRIBUTION_DEPTH {
        return Err(subprocess_error(
            "ExifTool distribution exceeds the fixed directory depth bound",
        ));
    }
    let mut names = metadata_publish_sys::read_directory_names(source).map_err(|error| {
        subprocess_error(format!(
            "cannot enumerate held ExifTool distribution: {error}"
        ))
    })?;
    names.sort();
    for name in &names {
        let name_text = name
            .to_str()
            .ok_or_else(|| subprocess_error("ExifTool distribution contains a non-UTF-8 entry"))?;
        if name_text.is_empty()
            || Path::new(&name).components().count() != 1
            || !matches!(
                Path::new(&name).components().next(),
                Some(Component::Normal(_))
            )
        {
            return Err(subprocess_error(
                "ExifTool distribution contains an unsafe entry name",
            ));
        }
        let relative = relative_prefix.join(name);
        if let Ok(source_directory) = metadata_publish_sys::open_child_directory(source, name) {
            let destination_directory = metadata_publish_sys::create_directory(destination, name)
                .map_err(|error| {
                subprocess_error(format!(
                    "cannot create private ExifTool distribution directory: {error}"
                ))
            })?;
            directories.push(relative.clone());
            copy_exiftool_distribution_tree(
                &source_directory,
                &destination_directory,
                &relative,
                files,
                directories,
                total_bytes,
                depth + 1,
            )?;
            metadata_publish_sys::sync_directory(&destination_directory).map_err(|error| {
                subprocess_error(format!(
                    "cannot sync private ExifTool distribution directory: {error}"
                ))
            })?;
            continue;
        }

        let mut source_file =
            metadata_publish_sys::open_regular(source, name).map_err(|error| {
                subprocess_error(format!(
                    "ExifTool distribution entry is linked, replaced, or unreadable: {error}"
                ))
            })?;
        let relative_text = relative
            .to_str()
            .ok_or_else(|| subprocess_error("ExifTool distribution relative path is not UTF-8"))?;
        let source_binding = binding_from_open_file(&mut source_file, relative_text)?;
        *total_bytes = total_bytes
            .checked_add(source_binding.byte_length)
            .ok_or_else(|| subprocess_error("ExifTool distribution size overflow"))?;
        if *total_bytes > MAX_EXIFTOOL_DISTRIBUTION_BYTES
            || files.len() >= MAX_EXIFTOOL_DISTRIBUTION_FILES
        {
            return Err(subprocess_error(
                "ExifTool distribution exceeds its fixed file-count or byte bound",
            ));
        }
        source_file.seek(SeekFrom::Start(0)).map_err(|error| {
            subprocess_error(format!("cannot rewind held ExifTool module: {error}"))
        })?;
        let mut destination_file = metadata_publish_sys::create_new_regular(destination, name)
            .map_err(|error| {
                subprocess_error(format!("cannot create private ExifTool module: {error}"))
            })?;
        copy_exact_bounded(
            &mut source_file,
            &mut destination_file,
            source_binding.byte_length,
        )
        .map_err(|error| subprocess_error(format!("cannot snapshot ExifTool module: {error}")))?;
        destination_file.sync_all().map_err(|error| {
            subprocess_error(format!("cannot sync private ExifTool module: {error}"))
        })?;
        let snapshot_binding = binding_from_open_file(&mut destination_file, relative_text)?;
        if snapshot_binding.sha256 != source_binding.sha256
            || snapshot_binding.byte_length != source_binding.byte_length
        {
            return Err(subprocess_error(
                "private ExifTool module differs from its held source bytes",
            ));
        }
        files.push(DistributionSnapshotFile {
            relative_path: relative,
            binding: snapshot_binding,
        });
    }
    let mut names_after = metadata_publish_sys::read_directory_names(source).map_err(|error| {
        subprocess_error(format!(
            "cannot re-enumerate held ExifTool distribution: {error}"
        ))
    })?;
    names_after.sort();
    if names_after != names {
        return Err(subprocess_error(
            "ExifTool distribution namespace changed while it was being snapshotted",
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn distribution_tree_digest(files: &[DistributionSnapshotFile]) -> String {
    let mut ordered = files
        .iter()
        .filter(|file| file.relative_path.starts_with("lib"))
        .collect::<Vec<_>>();
    ordered.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    let mut hasher = Sha256::new();
    hasher.update(b"scanstudio-exiftool-distribution-v1\0");
    for file in ordered {
        let path = file.relative_path.to_string_lossy();
        hasher.update((path.len() as u64).to_be_bytes());
        hasher.update(path.as_bytes());
        hasher.update(file.binding.byte_length.to_be_bytes());
        hasher.update(file.binding.sha256.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

#[cfg(unix)]
fn collect_distribution_snapshot_namespace(
    directory: &File,
    prefix: &Path,
    files: &mut std::collections::BTreeSet<PathBuf>,
    directories: &mut std::collections::BTreeSet<PathBuf>,
    depth: usize,
) -> Result<(), EngineError> {
    if depth > MAX_EXIFTOOL_DISTRIBUTION_DEPTH {
        return Err(subprocess_error(
            "private ExifTool runtime exceeds the approved directory depth",
        ));
    }
    let names = metadata_publish_sys::read_directory_names(directory).map_err(|error| {
        subprocess_error(format!(
            "cannot enumerate private ExifTool runtime during verification: {error}"
        ))
    })?;
    for name in names {
        if Path::new(&name).components().count() != 1
            || !matches!(
                Path::new(&name).components().next(),
                Some(Component::Normal(_))
            )
        {
            return Err(subprocess_error(
                "private ExifTool runtime contains an unsafe entry name",
            ));
        }
        let relative = prefix.join(&name);
        match metadata_publish_sys::open_child_directory(directory, &name) {
            Ok(child) => {
                if !directories.insert(relative.clone()) {
                    return Err(subprocess_error(
                        "private ExifTool runtime contains a duplicate directory entry",
                    ));
                }
                collect_distribution_snapshot_namespace(
                    &child,
                    &relative,
                    files,
                    directories,
                    depth + 1,
                )?;
            }
            Err(_) => {
                metadata_publish_sys::open_regular(directory, &name).map_err(|error| {
                    subprocess_error(format!(
                        "private ExifTool runtime contains an unreadable or linked entry: {error}"
                    ))
                })?;
                if !files.insert(relative) {
                    return Err(subprocess_error(
                        "private ExifTool runtime contains a duplicate file entry",
                    ));
                }
            }
        }
    }
    Ok(())
}

#[cfg(unix)]
impl ApprovedDistributionSnapshot {
    fn create(
        executable: &Path,
        source: &mut File,
        source_binding: &WrittenFileBinding,
    ) -> Result<Self, EngineError> {
        let source_bytes = read_approved_script(source, source_binding.byte_length)?;
        let source_text = std::str::from_utf8(&source_bytes)
            .map_err(|_| subprocess_error("ExifTool Perl launcher is not valid UTF-8"))?;
        let source_module_root = discover_exiftool_module_root(executable, source_text)?;
        let source_modules =
            metadata_publish_sys::open_directory(&source_module_root).map_err(|error| {
                subprocess_error(format!("cannot anchor ExifTool module tree: {error}"))
            })?;

        let parent_path = std::fs::canonicalize(std::env::temp_dir()).map_err(|error| {
            subprocess_error(format!(
                "cannot resolve private ExifTool snapshot root: {error}"
            ))
        })?;
        let parent = metadata_publish_sys::open_directory(&parent_path).map_err(|error| {
            subprocess_error(format!(
                "cannot anchor private ExifTool snapshot root: {error}"
            ))
        })?;
        for _ in 0..32 {
            let name = OsString::from(format!(
                "scanstudio-exiftool-runtime-{}",
                random_metadata_token()?
            ));
            let path = parent_path.join(&name);
            let directory = match metadata_publish_sys::create_private_directory(&parent, &name) {
                Ok(directory) => directory,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(subprocess_error(format!(
                        "cannot create private ExifTool runtime: {error}"
                    )))
                }
            };
            verify_private_directory_permissions(&directory)?;
            let lib = metadata_publish_sys::create_directory(&directory, OsStr::new("lib"))
                .map_err(|error| {
                    subprocess_error(format!("cannot create private ExifTool lib root: {error}"))
                })?;
            let mut files = Vec::new();
            let mut directories = vec![PathBuf::from("lib")];
            let mut total_bytes = 0_u64;
            let build = (|| {
                copy_exiftool_distribution_tree(
                    &source_modules,
                    &lib,
                    Path::new("lib"),
                    &mut files,
                    &mut directories,
                    &mut total_bytes,
                    0,
                )?;
                metadata_publish_sys::sync_directory(&lib).map_err(|error| {
                    subprocess_error(format!("cannot sync private ExifTool lib root: {error}"))
                })?;

                let snapshot_lib = path.join("lib");
                source_module_root
                    .to_str()
                    .ok_or_else(|| subprocess_error("ExifTool module root is not valid UTF-8"))?;
                let snapshot_lib_text = snapshot_lib.to_str().ok_or_else(|| {
                    subprocess_error("private ExifTool module root is not valid UTF-8")
                })?;
                let source_literals =
                    module_root_launcher_literals(source_text, &source_module_root);
                let mut transformed = source_text.to_string();
                for literal in &source_literals {
                    transformed = transformed.replace(literal, snapshot_lib_text);
                }
                if source_literals
                    .iter()
                    .any(|literal| source_text.contains(literal) && transformed.contains(literal))
                {
                    return Err(subprocess_error(
                        "could not redirect every absolute ExifTool module root into the private snapshot",
                    ));
                }
                let mut launch =
                    metadata_publish_sys::create_new_regular(&directory, OsStr::new("exiftool"))
                        .map_err(|error| {
                            subprocess_error(format!(
                                "cannot create private ExifTool launcher: {error}"
                            ))
                        })?;
                launch.write_all(transformed.as_bytes()).map_err(|error| {
                    subprocess_error(format!("cannot write private ExifTool launcher: {error}"))
                })?;
                launch.sync_all().map_err(|error| {
                    subprocess_error(format!("cannot sync private ExifTool launcher: {error}"))
                })?;
                let launch_binding = binding_from_open_file(&mut launch, "exiftool")?;
                files.push(DistributionSnapshotFile {
                    relative_path: PathBuf::from("exiftool"),
                    binding: launch_binding,
                });
                metadata_publish_sys::sync_directory(&directory).map_err(|error| {
                    subprocess_error(format!("cannot sync private ExifTool runtime: {error}"))
                })?;
                metadata_publish_sys::sync_directory(&parent).map_err(|error| {
                    subprocess_error(format!(
                        "cannot sync private ExifTool runtime parent: {error}"
                    ))
                })?;
                Ok::<File, EngineError>(launch)
            })();
            match build {
                Ok(launch) => {
                    let snapshot = Self {
                        parent,
                        name,
                        path: path.clone(),
                        directory,
                        source_module_root,
                        tree_digest: distribution_tree_digest(&files),
                        files,
                        directories,
                        launch_path: path.join("exiftool"),
                    };
                    snapshot.verify()?;
                    drop(launch);
                    return Ok(snapshot);
                }
                Err(error) => {
                    drop((lib, directory));
                    let _ = std::fs::remove_dir_all(&path);
                    return Err(error);
                }
            }
        }
        Err(subprocess_error(
            "could not reserve a collision-isolated private ExifTool runtime",
        ))
    }

    fn verify(&self) -> Result<(), EngineError> {
        verify_child_directory_authority(
            &self.parent,
            &self.name,
            &self.directory,
            "private ExifTool runtime",
        )?;
        verify_private_directory_permissions(&self.directory)?;
        let mut observed_files = std::collections::BTreeSet::new();
        let mut observed_directories = std::collections::BTreeSet::new();
        collect_distribution_snapshot_namespace(
            &self.directory,
            Path::new(""),
            &mut observed_files,
            &mut observed_directories,
            0,
        )?;
        let expected_files = self
            .files
            .iter()
            .map(|file| file.relative_path.clone())
            .collect::<std::collections::BTreeSet<_>>();
        let expected_directories = self
            .directories
            .iter()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>();
        if observed_files != expected_files || observed_directories != expected_directories {
            return Err(subprocess_error(
                "private ExifTool runtime namespace changed after approval",
            ));
        }
        for file in &self.files {
            let mut opened = open_regular_beneath(&self.directory, &file.relative_path)?;
            let observed = binding_from_open_file(
                &mut opened,
                file.relative_path.to_str().ok_or_else(|| {
                    subprocess_error("private ExifTool snapshot path is not UTF-8")
                })?,
            )?;
            if observed != file.binding {
                return Err(subprocess_error(
                    "private ExifTool runtime changed after approval",
                ));
            }
        }
        Ok(())
    }

    fn open_launch(&self) -> Result<File, EngineError> {
        self.verify()?;
        open_regular_beneath(&self.directory, Path::new("exiftool"))
    }
}

#[cfg(unix)]
impl Drop for ApprovedDistributionSnapshot {
    fn drop(&mut self) {
        for file in self.files.iter().rev() {
            if let Ok(parent) = open_anchored_parent(&self.directory, &file.relative_path) {
                if let Some(leaf) = file.relative_path.file_name() {
                    let _ = metadata_publish_sys::unlink(&parent, leaf);
                }
            }
        }
        self.directories
            .sort_by_key(|path| std::cmp::Reverse(path.components().count()));
        for relative in &self.directories {
            if let Ok(parent) = open_anchored_parent(&self.directory, relative) {
                if let Some(leaf) = relative.file_name() {
                    let _ = metadata_publish_sys::remove_directory(&parent, leaf);
                }
            }
        }
        if verify_child_directory_authority(
            &self.parent,
            &self.name,
            &self.directory,
            "private ExifTool runtime cleanup",
        )
        .is_ok()
        {
            if let Ok(directory) = self.directory.try_clone() {
                drop(directory);
            }
            let _ = metadata_publish_sys::remove_directory(&self.parent, &self.name);
            let _ = metadata_publish_sys::sync_directory(&self.parent);
        }
    }
}

fn verify_executable_binding(
    detection: &ExifToolDetection,
) -> Result<&ExecutableBinding, EngineError> {
    let expected = detection
        .executable_binding
        .as_ref()
        .ok_or_else(|| subprocess_error("ExifTool detection has no executable identity binding"))?;
    let mut held = expected.approved.held_file.try_clone().map_err(|error| {
        subprocess_error(format!(
            "cannot duplicate approved ExifTool descriptor: {error}"
        ))
    })?;
    let current = binding_from_open_file(&mut held, &expected.approved.held_binding.relative_path)
        .map_err(|error| subprocess_error(format!("cannot revalidate ExifTool bytes: {error}")))?;
    if current != expected.approved.held_binding
        || current.sha256 != expected.file.sha256
        || current.byte_length != expected.file.byte_length
    {
        return Err(subprocess_error(
            "the held ExifTool executable changed after command approval; preview again",
        ));
    }
    #[cfg(unix)]
    {
        if let Some(distribution) = &expected.approved.distribution {
            distribution.verify()?;
        }
        let expected_launch = expected
            .approved
            .distribution
            .as_ref()
            .and_then(|distribution| {
                distribution
                    .files
                    .iter()
                    .find(|file| file.relative_path == Path::new("exiftool"))
            })
            .map(|file| &file.binding)
            .unwrap_or(&expected.approved.held_binding);
        let mut launch = expected.approved.launch_file.try_clone().map_err(|error| {
            subprocess_error(format!(
                "cannot duplicate private ExifTool launcher: {error}"
            ))
        })?;
        let current_launch = binding_from_open_file(&mut launch, &expected_launch.relative_path)?;
        if &current_launch != expected_launch {
            return Err(subprocess_error(
                "private ExifTool launcher changed after approval; preview again",
            ));
        }
    }
    #[cfg(unix)]
    match &expected.approved.launch {
        ApprovedLaunch::Script(interpreter) => {
            let mut held = interpreter.held_file.try_clone().map_err(|error| {
                subprocess_error(format!(
                    "cannot duplicate approved ExifTool interpreter descriptor: {error}"
                ))
            })?;
            let current = binding_from_open_file(&mut held, &interpreter.file.relative_path)
                .map_err(|error| {
                    subprocess_error(format!(
                        "cannot revalidate approved ExifTool interpreter: {error}"
                    ))
                })?;
            if current != interpreter.file {
                return Err(subprocess_error(
                    "ExifTool interpreter changed after command approval; preview again",
                ));
            }
        }
        #[cfg(target_os = "linux")]
        ApprovedLaunch::NativeLinux => {}
    }
    #[cfg(windows)]
    {
        let current = bind_executable(Path::new(&expected.canonical_path))?;
        if current.file != expected.file {
            return Err(subprocess_error(
                "ExifTool executable path changed after command approval; preview again",
            ));
        }
    }
    Ok(expected)
}

fn open_executable_nofollow(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt as _;
        const FILE_SHARE_READ: u32 = 0x0000_0001;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        // Sharing only reads prevents any cooperating or unprivileged writer
        // from replacing, deleting, or changing these bytes until the spawn
        // has opened the image section.
        options
            .share_mode(FILE_SHARE_READ)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    options.open(path)
}

// ---------------------------------------------------------------------
// Frame lookup, metadata resolution, target resolution
// ---------------------------------------------------------------------

/// Shared frame lookup: `InvalidParams` (mirroring `manifest::mutate_frame`'s
/// own error text) if no frame with this index exists in `project`.
fn find_frame(project: &ScanProject, frame_index: u32) -> Result<&ProjectFrame, EngineError> {
    project
        .frames
        .iter()
        .find(|f| f.index == frame_index)
        .ok_or_else(|| {
            EngineError::new(
                ErrorCode::InvalidParams,
                format!("frame index {frame_index} does not exist in this project"),
            )
        })
}

/// Resolves the metadata a write to `frame_index` should actually use: the
/// frame's own `metadata_override` if set, else the project's roll-wide
/// `roll_metadata` — the same override-then-roll-default resolution
/// `server.rs`'s other per-frame methods already apply.
pub fn resolve_effective_metadata(
    project: &ScanProject,
    frame_index: u32,
) -> Result<MetadataSet, EngineError> {
    let frame = find_frame(project, frame_index)?;
    Ok(frame
        .metadata_override
        .clone()
        .unwrap_or_else(|| project.roll_metadata.clone()))
}

fn target_refusal(message: impl Into<String>) -> EngineError {
    EngineError::new(ErrorCode::InvalidParams, message).with_recoverable(true)
}

#[cfg(unix)]
pub(crate) fn held_file_identity(
    _file: &File,
    metadata: &std::fs::Metadata,
) -> Option<(u64, u64, u64)> {
    use std::os::unix::fs::MetadataExt as _;
    Some((metadata.dev(), metadata.ino(), metadata.nlink()))
}

#[cfg(windows)]
pub(crate) fn held_file_identity(
    file: &File,
    _metadata: &std::fs::Metadata,
) -> Option<(u64, u64, u64)> {
    use std::os::windows::io::AsRawHandle as _;

    type Handle = *mut std::ffi::c_void;
    #[repr(C)]
    struct FileTime {
        low: u32,
        high: u32,
    }
    #[repr(C)]
    struct ByHandleFileInformation {
        file_attributes: u32,
        creation_time: FileTime,
        last_access_time: FileTime,
        last_write_time: FileTime,
        volume_serial_number: u32,
        file_size_high: u32,
        file_size_low: u32,
        number_of_links: u32,
        file_index_high: u32,
        file_index_low: u32,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetFileInformationByHandle(
            file: Handle,
            information: *mut ByHandleFileInformation,
        ) -> i32;
    }

    let mut information = std::mem::MaybeUninit::<ByHandleFileInformation>::uninit();
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), information.as_mut_ptr()) } == 0 {
        return None;
    }
    let information = unsafe { information.assume_init() };
    Some((
        u64::from(information.volume_serial_number),
        (u64::from(information.file_index_high) << 32) | u64::from(information.file_index_low),
        u64::from(information.number_of_links),
    ))
}

#[cfg(not(any(unix, windows)))]
pub(crate) fn held_file_identity(
    _file: &File,
    _metadata: &std::fs::Metadata,
) -> Option<(u64, u64, u64)> {
    None
}

#[cfg(windows)]
fn windows_metadata_filesystem_name_is_supported(name: &[u16]) -> bool {
    String::from_utf16_lossy(name)
        .trim_end_matches('\0')
        .eq_ignore_ascii_case("NTFS")
}

#[cfg(windows)]
pub(crate) fn ensure_supported_metadata_filesystem(file: &File) -> std::io::Result<()> {
    use std::os::windows::io::AsRawHandle as _;

    #[link(name = "kernel32")]
    extern "system" {
        fn GetVolumeInformationByHandleW(
            file: *mut std::ffi::c_void,
            volume_name: *mut u16,
            volume_name_size: u32,
            volume_serial_number: *mut u32,
            maximum_component_length: *mut u32,
            filesystem_flags: *mut u32,
            filesystem_name: *mut u16,
            filesystem_name_size: u32,
        ) -> i32;
    }

    let mut filesystem_name = [0_u16; 32];
    let result = unsafe {
        GetVolumeInformationByHandleW(
            file.as_raw_handle(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            filesystem_name.as_mut_ptr(),
            filesystem_name.len() as u32,
        )
    };
    if result == 0 {
        return Err(std::io::Error::last_os_error());
    }
    if !windows_metadata_filesystem_name_is_supported(&filesystem_name) {
        let name = String::from_utf16_lossy(&filesystem_name)
            .trim_end_matches('\0')
            .to_string();
        return Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            format!("metadata authority requires NTFS stable file identities; found {name}"),
        ));
    }
    Ok(())
}

#[cfg(not(windows))]
pub(crate) fn ensure_supported_metadata_filesystem(_file: &File) -> std::io::Result<()> {
    Ok(())
}

fn platform_identity(
    file: &File,
    metadata: &std::fs::Metadata,
) -> (Option<u64>, Option<u64>, Option<u64>) {
    match held_file_identity(file, metadata) {
        Some((volume, inode, links)) => (Some(volume), Some(inode), Some(links)),
        None => (None, None, None),
    }
}

#[cfg(windows)]
fn metadata_is_reparse_point(metadata: &std::fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt as _;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_reparse_point(_metadata: &std::fs::Metadata) -> bool {
    false
}

/// Hashes a held, already size-checked descriptor off the request thread.
/// A slow/network filesystem can block a regular-file `read` indefinitely;
/// the dispatcher therefore waits only a fixed deadline. At most one detached
/// timed-out reader may exist, preventing repeated requests from accumulating
/// unbounded stuck threads while that filesystem remains unresponsive.
fn hash_open_file_bounded(file: &mut File, expected_len: u64) -> Result<String, EngineError> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| target_refusal(format!("cannot rewind opened metadata file: {error}")))?;
    loop {
        let state = METADATA_HASH_STATE.load(Ordering::Acquire);
        if state >= METADATA_HASH_STALL_UNIT {
            return Err(target_refusal(
                "a bounded metadata hash timed out and is still draining; retry after it completes",
            ));
        }
        if state + 1 >= METADATA_HASH_STALL_UNIT {
            return Err(target_refusal(
                "too many concurrent metadata hash operations",
            ));
        }
        if METADATA_HASH_STATE
            .compare_exchange_weak(state, state + 1, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            break;
        }
    }
    let reader = match file.try_clone() {
        Ok(reader) => reader,
        Err(error) => {
            METADATA_HASH_STATE.fetch_sub(1, Ordering::AcqRel);
            return Err(target_refusal(format!(
                "cannot duplicate the held metadata descriptor: {error}"
            )));
        }
    };
    let (tx, rx) = mpsc::sync_channel(1);
    // 0 = caller is waiting, 1 = caller timed out, 2 = worker finished.
    let worker_state = Arc::new(AtomicUsize::new(0));
    let completion_state = Arc::clone(&worker_state);
    thread::spawn(move || {
        let result = (|| -> Result<String, String> {
            let mut reader = reader.take(expected_len.saturating_add(1));
            let mut hasher = Sha256::new();
            let mut total = 0_u64;
            let mut buffer = [0_u8; 128 * 1024];
            loop {
                let count = reader
                    .read(&mut buffer)
                    .map_err(|error| format!("cannot hash opened metadata file: {error}"))?;
                if count == 0 {
                    break;
                }
                total = total.saturating_add(count as u64);
                if total > expected_len {
                    return Err("metadata file grew while it was being hashed".to_string());
                }
                hasher.update(&buffer[..count]);
            }
            if total != expected_len {
                return Err(format!(
                    "metadata file length changed while hashing: expected {expected_len}, read {total}"
                ));
            }
            Ok(format!("{:x}", hasher.finalize()))
        })();
        let timed_out = completion_state.swap(2, Ordering::AcqRel) == 1;
        METADATA_HASH_STATE.fetch_sub(
            1 + if timed_out {
                METADATA_HASH_STALL_UNIT
            } else {
                0
            },
            Ordering::AcqRel,
        );
        let _ = tx.send(result);
    });
    match rx.recv_timeout(METADATA_HASH_TIMEOUT) {
        Ok(Ok(digest)) => Ok(digest),
        Ok(Err(message)) => Err(target_refusal(message)),
        Err(mpsc::RecvTimeoutError::Timeout) => {
            // Publish the stall before marking this worker timed out. A new
            // starter either linearizes before this increment (and is already
            // counted active) or observes the high-half stall count and fails.
            METADATA_HASH_STATE.fetch_add(METADATA_HASH_STALL_UNIT, Ordering::AcqRel);
            if worker_state
                .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
            {
                // The worker finished between recv_timeout and this marker;
                // it already removed its active count and needs no drain gate.
                METADATA_HASH_STATE.fetch_sub(METADATA_HASH_STALL_UNIT, Ordering::AcqRel);
            }
            Err(target_refusal(format!(
                "metadata file hashing exceeded its {} second deadline",
                METADATA_HASH_TIMEOUT.as_secs()
            )))
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => Err(target_refusal(
            "metadata file hasher stopped without returning a result",
        )),
    }
}

#[cfg(unix)]
pub(crate) mod metadata_publish_sys {
    use super::*;
    use std::ffi::CString;
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, IntoRawFd as _};
    use std::os::unix::ffi::{OsStrExt as _, OsStringExt as _};
    use std::os::unix::fs::OpenOptionsExt as _;

    fn component(value: &OsStr) -> io::Result<CString> {
        if value.as_bytes().contains(&b'/') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "metadata publication accepts one path component",
            ));
        }
        CString::new(value.as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path component contains NUL"))
    }

    pub fn open_directory(path: &Path) -> io::Result<File> {
        OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
    }

    pub fn open_child_directory(parent: &File, name: &OsStr) -> io::Result<File> {
        let name = component(name)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(unsafe { File::from_raw_fd(fd) })
        }
    }

    pub fn open_regular(parent: &File, name: &OsStr) -> io::Result<File> {
        let name = component(name)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(unsafe { File::from_raw_fd(fd) })
        }
    }

    pub fn create_new_regular(parent: &File, name: &OsStr) -> io::Result<File> {
        let name = component(name)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(unsafe { File::from_raw_fd(fd) })
        }
    }

    pub fn create_directory(parent: &File, name: &OsStr) -> io::Result<File> {
        let name_c = component(name)?;
        let result = unsafe { libc::mkdirat(parent.as_raw_fd(), name_c.as_ptr(), 0o700) };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        match open_child_directory(parent, name) {
            Ok(directory) => Ok(directory),
            Err(error) => {
                unsafe {
                    let _ = libc::unlinkat(parent.as_raw_fd(), name_c.as_ptr(), libc::AT_REMOVEDIR);
                }
                Err(error)
            }
        }
    }

    pub fn create_private_directory(parent: &File, name: &OsStr) -> io::Result<File> {
        create_directory(parent, name)
    }

    pub fn rename_replace(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        let from = component(from_name)?;
        let to = component(to_name)?;
        let result = unsafe {
            libc::renameat(
                from_directory.as_raw_fd(),
                from.as_ptr(),
                to_directory.as_raw_fd(),
                to.as_ptr(),
            )
        };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    #[cfg(target_os = "macos")]
    fn rename_with_flags(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
        flags: u32,
    ) -> io::Result<()> {
        use std::os::raw::{c_char, c_int, c_uint};
        unsafe extern "C" {
            fn renameatx_np(
                from_fd: c_int,
                from: *const c_char,
                to_fd: c_int,
                to: *const c_char,
                flags: c_uint,
            ) -> c_int;
        }
        let from = component(from_name)?;
        let to = component(to_name)?;
        let result = unsafe {
            renameatx_np(
                from_directory.as_raw_fd(),
                from.as_ptr(),
                to_directory.as_raw_fd(),
                to.as_ptr(),
                flags,
            )
        };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    #[cfg(target_os = "macos")]
    pub fn rename_exchange(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        const RENAME_SWAP: u32 = 0x0000_0002;
        const RENAME_NOFOLLOW_ANY: u32 = 0x0000_0010;
        rename_with_flags(
            from_directory,
            from_name,
            to_directory,
            to_name,
            RENAME_SWAP | RENAME_NOFOLLOW_ANY,
        )
    }

    #[cfg(target_os = "macos")]
    pub fn rename_exclusive(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        const RENAME_EXCL: u32 = 0x0000_0004;
        const RENAME_NOFOLLOW_ANY: u32 = 0x0000_0010;
        rename_with_flags(
            from_directory,
            from_name,
            to_directory,
            to_name,
            RENAME_EXCL | RENAME_NOFOLLOW_ANY,
        )
    }

    #[cfg(target_os = "linux")]
    fn rename_with_flags(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
        flags: libc::c_uint,
    ) -> io::Result<()> {
        let from = component(from_name)?;
        let to = component(to_name)?;
        let result = unsafe {
            libc::renameat2(
                from_directory.as_raw_fd(),
                from.as_ptr(),
                to_directory.as_raw_fd(),
                to.as_ptr(),
                flags,
            )
        };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    #[cfg(target_os = "linux")]
    pub fn rename_exchange(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        rename_with_flags(
            from_directory,
            from_name,
            to_directory,
            to_name,
            libc::RENAME_EXCHANGE,
        )
    }

    #[cfg(target_os = "linux")]
    pub fn rename_exclusive(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        rename_with_flags(
            from_directory,
            from_name,
            to_directory,
            to_name,
            libc::RENAME_NOREPLACE,
        )
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    pub fn rename_exchange(
        _from_directory: &File,
        _from_name: &OsStr,
        _to_directory: &File,
        _to_name: &OsStr,
    ) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "atomic metadata exchange is unsupported on this Unix platform",
        ))
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    pub fn rename_exclusive(
        _from_directory: &File,
        _from_name: &OsStr,
        _to_directory: &File,
        _to_name: &OsStr,
    ) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "create-only metadata publication is unsupported on this Unix platform",
        ))
    }

    pub fn unlink(parent: &File, name: &OsStr) -> io::Result<()> {
        let name = component(name)?;
        let result = unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    pub fn remove_directory(parent: &File, name: &OsStr) -> io::Result<()> {
        let name = component(name)?;
        let result =
            unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    unsafe fn errno_location() -> *mut libc::c_int {
        unsafe { libc::__error() }
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    unsafe fn errno_location() -> *mut libc::c_int {
        unsafe { libc::__errno_location() }
    }

    /// Enumerates the exact held directory rather than reopening its display
    /// pathname. `openat(".")` gives the stream an independent directory
    /// offset, so repeated recovery passes on a long-lived root capability do
    /// not inherit an earlier end-of-directory position.
    #[cfg(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "linux",
        target_os = "android"
    ))]
    pub fn read_directory_names(directory: &File) -> io::Result<Vec<OsString>> {
        let reopened = open_child_directory(directory, OsStr::new("."))?;
        let descriptor = reopened.into_raw_fd();
        let stream = unsafe { libc::fdopendir(descriptor) };
        if stream.is_null() {
            let error = io::Error::last_os_error();
            unsafe {
                libc::close(descriptor);
            }
            return Err(error);
        }

        let mut names = Vec::new();
        loop {
            let errno = unsafe { errno_location() };
            unsafe {
                *errno = 0;
            }
            let entry = unsafe { libc::readdir(stream) };
            if entry.is_null() {
                let read_error = unsafe { *errno };
                let close_result = unsafe { libc::closedir(stream) };
                if read_error != 0 {
                    return Err(io::Error::from_raw_os_error(read_error));
                }
                if close_result != 0 {
                    return Err(io::Error::last_os_error());
                }
                return Ok(names);
            }

            let bytes = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()).to_bytes() };
            if bytes != b"." && bytes != b".." {
                names.push(OsString::from_vec(bytes.to_vec()));
            }
        }
    }

    #[cfg(not(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "linux",
        target_os = "android"
    )))]
    pub fn read_directory_names(_directory: &File) -> io::Result<Vec<OsString>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "handle-relative metadata recovery enumeration is unsupported on this Unix platform",
        ))
    }

    pub fn sync_directory(directory: &File) -> io::Result<()> {
        directory.sync_all()
    }
}

#[cfg(windows)]
pub(crate) mod metadata_publish_sys {
    use super::*;
    use std::io;
    use std::mem::{offset_of, size_of};
    use std::os::windows::ffi::{OsStrExt as _, OsStringExt as _};
    use std::os::windows::fs::OpenOptionsExt as _;
    use std::os::windows::io::{AsRawHandle as _, FromRawHandle as _};

    type Handle = *mut std::ffi::c_void;
    const GENERIC_READ: u32 = 0x8000_0000;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const DELETE: u32 = 0x0001_0000;
    const SYNCHRONIZE: u32 = 0x0010_0000;
    const FILE_SHARE_READ: u32 = 0x0000_0001;
    const FILE_SHARE_WRITE: u32 = 0x0000_0002;
    const FILE_SHARE_DELETE: u32 = 0x0000_0004;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x0000_0080;
    const FILE_FLAG_WRITE_THROUGH: u32 = 0x8000_0000;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const OBJ_CASE_INSENSITIVE: u32 = 0x0000_0040;
    const FILE_DIRECTORY_FILE: u32 = 0x0000_0001;
    const FILE_WRITE_THROUGH: u32 = 0x0000_0002;
    const FILE_SYNCHRONOUS_IO_NONALERT: u32 = 0x0000_0020;
    const FILE_NON_DIRECTORY_FILE: u32 = 0x0000_0040;
    const FILE_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_OPEN: u32 = 0x0000_0001;
    const FILE_CREATE: u32 = 0x0000_0002;
    const FILE_NAMES_INFORMATION_CLASS: u32 = 12;
    const FILE_RENAME_INFO_EX_CLASS: u32 = 22;
    const FILE_DISPOSITION_INFO_EX_CLASS: u32 = 21;
    const FILE_DISPOSITION_FLAG_DELETE: u32 = 0x0000_0001;
    const FILE_DISPOSITION_FLAG_POSIX_SEMANTICS: u32 = 0x0000_0002;
    const FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE: u32 = 0x0000_0010;
    const TOKEN_QUERY: u32 = 0x0000_0008;
    const TOKEN_USER_CLASS: u32 = 1;
    const SECURITY_DESCRIPTOR_REVISION: u32 = 1;
    const ACL_REVISION: u32 = 2;
    const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
    const OBJECT_INHERIT_ACE: u8 = 0x01;
    const CONTAINER_INHERIT_ACE: u8 = 0x02;
    const FILE_ALL_ACCESS: u32 = 0x001f_01ff;
    const SE_DACL_PROTECTED: u16 = 0x1000;
    const SE_FILE_OBJECT: u32 = 1;
    const OWNER_SECURITY_INFORMATION: u32 = 0x0000_0001;
    const DACL_SECURITY_INFORMATION: u32 = 0x0000_0004;
    const ACL_SIZE_INFORMATION_CLASS: u32 = 2;

    #[repr(C)]
    struct FileRenameInfoEx {
        flags: u32,
        root_directory: Handle,
        file_name_length: u32,
        file_name: [u16; 1],
    }

    #[repr(C)]
    struct FileDispositionInfoEx {
        flags: u32,
    }

    #[repr(C)]
    struct UnicodeString {
        length: u16,
        maximum_length: u16,
        buffer: *mut u16,
    }

    #[repr(C)]
    struct ObjectAttributes {
        length: u32,
        root_directory: Handle,
        object_name: *mut UnicodeString,
        attributes: u32,
        security_descriptor: *mut std::ffi::c_void,
        security_quality_of_service: *mut std::ffi::c_void,
    }

    #[repr(C)]
    struct IoStatusBlock {
        status_or_pointer: isize,
        information: usize,
    }

    #[repr(C)]
    struct SidAndAttributes {
        sid: *mut std::ffi::c_void,
        attributes: u32,
    }

    #[repr(C)]
    struct TokenUser {
        user: SidAndAttributes,
    }

    #[repr(C)]
    struct Acl {
        revision: u8,
        sbz1: u8,
        size: u16,
        ace_count: u16,
        sbz2: u16,
    }

    #[repr(C)]
    struct AceHeader {
        ace_type: u8,
        ace_flags: u8,
        ace_size: u16,
    }

    #[repr(C)]
    struct AccessAllowedAce {
        header: AceHeader,
        mask: u32,
        sid_start: u32,
    }

    #[repr(C)]
    struct AclSizeInformation {
        ace_count: u32,
        bytes_in_use: u32,
        bytes_free: u32,
    }

    #[repr(C)]
    struct SecurityDescriptor {
        revision: u8,
        sbz1: u8,
        control: u16,
        owner: *mut std::ffi::c_void,
        group: *mut std::ffi::c_void,
        sacl: *mut Acl,
        dacl: *mut Acl,
    }

    const _: () = {
        assert!(size_of::<UnicodeString>() == if size_of::<usize>() == 8 { 16 } else { 8 });
        assert!(size_of::<ObjectAttributes>() == if size_of::<usize>() == 8 { 48 } else { 24 });
        assert!(size_of::<IoStatusBlock>() == if size_of::<usize>() == 8 { 16 } else { 8 });
    };

    #[link(name = "kernel32")]
    extern "system" {
        fn SetFileInformationByHandle(
            file: Handle,
            information_class: u32,
            information: *mut std::ffi::c_void,
            information_size: u32,
        ) -> i32;
        fn GetCurrentProcess() -> Handle;
        fn CloseHandle(handle: Handle) -> i32;
        fn LocalFree(memory: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
    }

    #[link(name = "advapi32")]
    extern "system" {
        fn OpenProcessToken(process: Handle, desired_access: u32, token: *mut Handle) -> i32;
        fn GetTokenInformation(
            token: Handle,
            information_class: u32,
            information: *mut std::ffi::c_void,
            information_length: u32,
            return_length: *mut u32,
        ) -> i32;
        fn GetLengthSid(sid: *mut std::ffi::c_void) -> u32;
        fn InitializeSecurityDescriptor(descriptor: *mut std::ffi::c_void, revision: u32) -> i32;
        fn InitializeAcl(acl: *mut Acl, length: u32, revision: u32) -> i32;
        fn AddAccessAllowedAceEx(
            acl: *mut Acl,
            revision: u32,
            flags: u32,
            access_mask: u32,
            sid: *mut std::ffi::c_void,
        ) -> i32;
        fn SetSecurityDescriptorOwner(
            descriptor: *mut std::ffi::c_void,
            owner: *mut std::ffi::c_void,
            owner_defaulted: i32,
        ) -> i32;
        fn SetSecurityDescriptorDacl(
            descriptor: *mut std::ffi::c_void,
            present: i32,
            dacl: *mut Acl,
            defaulted: i32,
        ) -> i32;
        fn SetSecurityDescriptorControl(
            descriptor: *mut std::ffi::c_void,
            control_bits_of_interest: u16,
            control_bits_to_set: u16,
        ) -> i32;
        fn GetSecurityInfo(
            handle: Handle,
            object_type: u32,
            security_information: u32,
            owner: *mut *mut std::ffi::c_void,
            group: *mut *mut std::ffi::c_void,
            dacl: *mut *mut Acl,
            sacl: *mut *mut Acl,
            descriptor: *mut *mut std::ffi::c_void,
        ) -> u32;
        fn GetAclInformation(
            acl: *mut Acl,
            information: *mut std::ffi::c_void,
            information_length: u32,
            information_class: u32,
        ) -> i32;
        fn GetAce(acl: *mut Acl, index: u32, ace: *mut *mut std::ffi::c_void) -> i32;
        fn EqualSid(left: *mut std::ffi::c_void, right: *mut std::ffi::c_void) -> i32;
        fn GetSecurityDescriptorControl(
            descriptor: *mut std::ffi::c_void,
            control: *mut u16,
            revision: *mut u32,
        ) -> i32;
    }

    #[link(name = "ntdll")]
    extern "system" {
        fn NtCreateFile(
            file: *mut Handle,
            desired_access: u32,
            object_attributes: *mut ObjectAttributes,
            io_status_block: *mut IoStatusBlock,
            allocation_size: *mut i64,
            file_attributes: u32,
            share_access: u32,
            create_disposition: u32,
            create_options: u32,
            ea_buffer: *mut std::ffi::c_void,
            ea_length: u32,
        ) -> i32;
        fn NtQueryDirectoryFile(
            file: Handle,
            event: Handle,
            apc_routine: *mut std::ffi::c_void,
            apc_context: *mut std::ffi::c_void,
            io_status_block: *mut IoStatusBlock,
            file_information: *mut std::ffi::c_void,
            length: u32,
            file_information_class: u32,
            return_single_entry: u8,
            file_name: *mut UnicodeString,
            restart_scan: u8,
        ) -> i32;
        fn RtlNtStatusToDosError(status: i32) -> u32;
    }

    fn component(name: &OsStr) -> io::Result<Vec<u16>> {
        let path = Path::new(name);
        if path.components().count() != 1
            || !matches!(path.components().next(), Some(Component::Normal(_)))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "metadata publication accepts one Windows path component",
            ));
        }
        let wide = name.encode_wide().collect::<Vec<_>>();
        if wide.is_empty() || wide.contains(&0) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "metadata publication component is empty or contains NUL",
            ));
        }
        Ok(wide)
    }

    fn open_path(path: &Path, directory: bool) -> io::Result<File> {
        let flags = FILE_FLAG_OPEN_REPARSE_POINT
            | FILE_FLAG_WRITE_THROUGH
            | if directory {
                FILE_FLAG_BACKUP_SEMANTICS
            } else {
                0
            };
        let file = OpenOptions::new()
            .access_mode(GENERIC_READ | if directory { GENERIC_WRITE } else { DELETE })
            .share_mode(
                FILE_SHARE_READ | FILE_SHARE_WRITE | if directory { 0 } else { FILE_SHARE_DELETE },
            )
            .custom_flags(flags)
            .open(path)?;
        let metadata = file.metadata()?;
        if metadata_is_reparse_point(&metadata)
            || (directory && !metadata.is_dir())
            || (!directory && !metadata.is_file())
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "refusing a reparse point or wrong-kind Windows metadata entry",
            ));
        }
        ensure_supported_metadata_filesystem(&file)?;
        Ok(file)
    }

    fn with_current_user_sid<T>(
        operation: impl FnOnce(*mut std::ffi::c_void) -> io::Result<T>,
    ) -> io::Result<T> {
        let mut token: Handle = std::ptr::null_mut();
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw mut token) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let result = (|| {
            let mut required = 0_u32;
            unsafe {
                GetTokenInformation(
                    token,
                    TOKEN_USER_CLASS,
                    std::ptr::null_mut(),
                    0,
                    &raw mut required,
                );
            }
            if required < size_of::<TokenUser>() as u32 {
                return Err(io::Error::last_os_error());
            }
            let words = (required as usize).div_ceil(size_of::<usize>());
            let mut storage = vec![0_usize; words];
            if unsafe {
                GetTokenInformation(
                    token,
                    TOKEN_USER_CLASS,
                    storage.as_mut_ptr().cast(),
                    required,
                    &raw mut required,
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            let token_user = storage.as_ptr().cast::<TokenUser>();
            let sid = unsafe { (*token_user).user.sid };
            if sid.is_null() || unsafe { GetLengthSid(sid) } == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Windows process token has no usable user SID",
                ));
            }
            operation(sid)
        })();
        unsafe {
            CloseHandle(token);
        }
        result
    }

    fn create_directory_with_owner_only_dacl(parent: &File, name: &OsStr) -> io::Result<File> {
        with_current_user_sid(|owner_sid| {
            let sid_length = unsafe { GetLengthSid(owner_sid) } as usize;
            let acl_length = size_of::<Acl>()
                .checked_add(size_of::<AccessAllowedAce>() - size_of::<u32>())
                .and_then(|length| length.checked_add(sid_length))
                .and_then(|length| u32::try_from(length).ok())
                .ok_or_else(|| io::Error::other("Windows private DACL size overflow"))?;
            let mut acl_storage = vec![0_usize; (acl_length as usize).div_ceil(size_of::<usize>())];
            let acl = acl_storage.as_mut_ptr().cast::<Acl>();
            if unsafe { InitializeAcl(acl, acl_length, ACL_REVISION) } == 0 {
                return Err(io::Error::last_os_error());
            }
            if unsafe {
                AddAccessAllowedAceEx(
                    acl,
                    ACL_REVISION,
                    u32::from(OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE),
                    FILE_ALL_ACCESS,
                    owner_sid,
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            let mut descriptor =
                unsafe { std::mem::MaybeUninit::<SecurityDescriptor>::zeroed().assume_init() };
            let descriptor_pointer = (&raw mut descriptor).cast::<std::ffi::c_void>();
            if unsafe {
                InitializeSecurityDescriptor(descriptor_pointer, SECURITY_DESCRIPTOR_REVISION)
            } == 0
                || unsafe { SetSecurityDescriptorOwner(descriptor_pointer, owner_sid, 0) } == 0
                || unsafe { SetSecurityDescriptorDacl(descriptor_pointer, 1, acl, 0) } == 0
                || unsafe {
                    SetSecurityDescriptorControl(
                        descriptor_pointer,
                        SE_DACL_PROTECTED,
                        SE_DACL_PROTECTED,
                    )
                } == 0
            {
                return Err(io::Error::last_os_error());
            }
            relative_file_with_security(
                parent,
                name,
                true,
                true,
                true,
                false,
                false,
                descriptor_pointer,
            )
        })
    }

    pub fn verify_private_directory_permissions(directory: &File) -> io::Result<()> {
        let mut owner = std::ptr::null_mut();
        let mut dacl = std::ptr::null_mut();
        let mut descriptor = std::ptr::null_mut();
        let status = unsafe {
            GetSecurityInfo(
                directory.as_raw_handle(),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                &raw mut owner,
                std::ptr::null_mut(),
                &raw mut dacl,
                std::ptr::null_mut(),
                &raw mut descriptor,
            )
        };
        if status != 0 {
            return Err(io::Error::from_raw_os_error(status as i32));
        }
        let result = (|| {
            if owner.is_null() || dacl.is_null() || descriptor.is_null() {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Windows private workspace has no explicit owner DACL",
                ));
            }
            with_current_user_sid(|current_user| {
                if unsafe { EqualSid(owner, current_user) } == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "Windows private workspace is not owned by the engine user",
                    ));
                }
                Ok(())
            })?;
            let mut control = 0_u16;
            let mut revision = 0_u32;
            if unsafe {
                GetSecurityDescriptorControl(descriptor, &raw mut control, &raw mut revision)
            } == 0
                || control & SE_DACL_PROTECTED == 0
            {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Windows private workspace DACL permits inherited access",
                ));
            }
            let mut information = AclSizeInformation {
                ace_count: 0,
                bytes_in_use: 0,
                bytes_free: 0,
            };
            if unsafe {
                GetAclInformation(
                    dacl,
                    (&raw mut information).cast(),
                    size_of::<AclSizeInformation>() as u32,
                    ACL_SIZE_INFORMATION_CLASS,
                )
            } == 0
                || information.ace_count != 1
            {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Windows private workspace DACL is not owner-only",
                ));
            }
            let mut raw_ace = std::ptr::null_mut();
            if unsafe { GetAce(dacl, 0, &raw mut raw_ace) } == 0 || raw_ace.is_null() {
                return Err(io::Error::last_os_error());
            }
            let ace = raw_ace.cast::<AccessAllowedAce>();
            let ace_sid =
                unsafe { std::ptr::addr_of_mut!((*ace).sid_start).cast::<std::ffi::c_void>() };
            let header = unsafe { &(*ace).header };
            if header.ace_type != ACCESS_ALLOWED_ACE_TYPE
                || header.ace_flags & (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE)
                    != OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE
                || unsafe { (*ace).mask } != FILE_ALL_ACCESS
                || unsafe { EqualSid(owner, ace_sid) } == 0
            {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Windows private workspace DACL grants access beyond its owner",
                ));
            }
            Ok(())
        })();
        unsafe {
            LocalFree(descriptor);
        }
        result
    }

    fn relative_file(
        parent: &File,
        name: &OsStr,
        directory: bool,
        create_new: bool,
        request_write: bool,
        request_delete: bool,
        share_delete: bool,
    ) -> io::Result<File> {
        relative_file_with_security(
            parent,
            name,
            directory,
            create_new,
            request_write,
            request_delete,
            share_delete,
            std::ptr::null_mut(),
        )
    }

    fn relative_file_with_security(
        parent: &File,
        name: &OsStr,
        directory: bool,
        create_new: bool,
        request_write: bool,
        request_delete: bool,
        share_delete: bool,
        security_descriptor: *mut std::ffi::c_void,
    ) -> io::Result<File> {
        let mut wide = component(name)?;
        let byte_length = wide
            .len()
            .checked_mul(size_of::<u16>())
            .and_then(|length| u16::try_from(length).ok())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Windows metadata component is too long",
                )
            })?;
        let mut unicode = UnicodeString {
            length: byte_length,
            maximum_length: byte_length,
            buffer: wide.as_mut_ptr(),
        };
        let mut attributes = ObjectAttributes {
            length: size_of::<ObjectAttributes>() as u32,
            root_directory: parent.as_raw_handle(),
            object_name: &raw mut unicode,
            attributes: OBJ_CASE_INSENSITIVE,
            security_descriptor,
            security_quality_of_service: std::ptr::null_mut(),
        };
        let mut status_block = IoStatusBlock {
            status_or_pointer: 0,
            information: 0,
        };
        let mut handle: Handle = std::ptr::null_mut();
        let desired_access = GENERIC_READ
            | SYNCHRONIZE
            | if request_delete { DELETE } else { 0 }
            | if directory || request_write {
                GENERIC_WRITE
            } else {
                0
            };
        let create_options = FILE_OPEN_REPARSE_POINT
            | FILE_WRITE_THROUGH
            | FILE_SYNCHRONOUS_IO_NONALERT
            | if directory {
                FILE_DIRECTORY_FILE
            } else {
                FILE_NON_DIRECTORY_FILE
            };
        let status = unsafe {
            NtCreateFile(
                &raw mut handle,
                desired_access,
                &raw mut attributes,
                &raw mut status_block,
                std::ptr::null_mut(),
                FILE_ATTRIBUTE_NORMAL,
                FILE_SHARE_READ
                    | FILE_SHARE_WRITE
                    | if !directory && share_delete {
                        FILE_SHARE_DELETE
                    } else {
                        0
                    },
                if create_new { FILE_CREATE } else { FILE_OPEN },
                create_options,
                std::ptr::null_mut(),
                0,
            )
        };
        if status < 0 {
            let windows_error = unsafe { RtlNtStatusToDosError(status) };
            return Err(io::Error::from_raw_os_error(windows_error as i32));
        }
        if handle.is_null() || handle as isize == -1 {
            return Err(io::Error::other(
                "NtCreateFile returned an invalid Windows metadata handle",
            ));
        }
        let file = unsafe { File::from_raw_handle(handle) };
        let metadata = file.metadata()?;
        if metadata_is_reparse_point(&metadata)
            || (directory && !metadata.is_dir())
            || (!directory && !metadata.is_file())
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "refusing a reparse point or wrong-kind Windows metadata entry",
            ));
        }
        ensure_supported_metadata_filesystem(&file)?;
        Ok(file)
    }

    pub fn open_directory(path: &Path) -> io::Result<File> {
        open_path(path, true)
    }

    pub fn open_child_directory(parent: &File, name: &OsStr) -> io::Result<File> {
        relative_file(parent, name, true, false, false, false, false)
    }

    pub fn open_regular(parent: &File, name: &OsStr) -> io::Result<File> {
        relative_file(parent, name, false, false, false, true, true)
    }

    pub fn open_manifest_lock(parent: &File, name: &OsStr) -> io::Result<File> {
        relative_file(parent, name, false, false, true, false, false)
    }

    fn rename_handle(
        source: &File,
        destination_directory: &File,
        destination_name: &OsStr,
        replace: bool,
    ) -> io::Result<()> {
        let name = component(destination_name)?;
        let header_size = offset_of!(FileRenameInfoEx, file_name);
        let byte_len = name.len().checked_mul(size_of::<u16>()).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Windows rename name is too long",
            )
        })?;
        let total = header_size.checked_add(byte_len).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Windows rename buffer overflow",
            )
        })?;
        let words = total.div_ceil(size_of::<usize>());
        let mut storage = vec![0_usize; words];
        let info = storage.as_mut_ptr().cast::<FileRenameInfoEx>();
        unsafe {
            (*info).flags = u32::from(replace);
            (*info).root_directory = destination_directory.as_raw_handle();
            (*info).file_name_length = byte_len as u32;
            std::ptr::copy_nonoverlapping(
                name.as_ptr().cast::<u8>(),
                (info.cast::<u8>()).add(header_size),
                byte_len,
            );
        }
        let result = unsafe {
            SetFileInformationByHandle(
                source.as_raw_handle(),
                FILE_RENAME_INFO_EX_CLASS,
                info.cast(),
                total as u32,
            )
        };
        if result == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    pub fn rename_exchange(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        let source = open_regular(from_directory, from_name)?;
        let target = open_regular(to_directory, to_name)?;
        let parking = from_name
            .to_str()
            .and_then(|name| name.strip_prefix(".swap-"))
            .map(OsString::from)
            .unwrap_or_else(|| windows_swap_name(from_name));
        match open_regular(from_directory, &parking) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "Windows metadata exchange parking entry already exists",
                ))
            }
        }
        rename_handle(&source, from_directory, &parking, false)?;
        if let Err(error) = rename_handle(&target, from_directory, from_name, false) {
            let _ = rename_handle(&source, from_directory, from_name, false);
            return Err(error);
        }
        if let Err(error) = rename_handle(&source, to_directory, to_name, false) {
            let restore_old = rename_handle(&target, to_directory, to_name, false);
            let restore_new = rename_handle(&source, from_directory, from_name, false);
            if restore_old.is_err() || restore_new.is_err() {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    format!(
                        "Windows metadata exchange failed and immediate restoration was incomplete: {error}"
                    ),
                ));
            }
            return Err(error);
        }
        Ok(())
    }

    pub fn rename_exclusive(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        match open_regular(to_directory, to_name) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "create-only Windows metadata target already exists",
                ))
            }
        }
        let source = open_regular(from_directory, from_name)?;
        rename_handle(&source, to_directory, to_name, false)
    }

    pub fn create_new_regular(parent: &File, name: &OsStr) -> io::Result<File> {
        relative_file(parent, name, false, true, true, true, true)
    }

    pub fn create_manifest_lock(parent: &File, name: &OsStr) -> io::Result<File> {
        relative_file(parent, name, false, true, true, false, false)
    }

    pub fn create_directory(parent: &File, name: &OsStr) -> io::Result<File> {
        relative_file(parent, name, true, true, true, false, false)
    }

    pub fn create_private_directory(parent: &File, name: &OsStr) -> io::Result<File> {
        create_directory_with_owner_only_dacl(parent, name)
    }

    pub fn rename_replace(
        from_directory: &File,
        from_name: &OsStr,
        to_directory: &File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        let source = open_regular(from_directory, from_name)?;
        rename_handle(&source, to_directory, to_name, true)
    }

    fn delete_handle(file: &File) -> io::Result<()> {
        let mut information = FileDispositionInfoEx {
            flags: FILE_DISPOSITION_FLAG_DELETE
                | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS
                | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE,
        };
        let result = unsafe {
            SetFileInformationByHandle(
                file.as_raw_handle(),
                FILE_DISPOSITION_INFO_EX_CLASS,
                (&raw mut information).cast(),
                size_of::<FileDispositionInfoEx>() as u32,
            )
        };
        if result == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    pub fn unlink(parent: &File, name: &OsStr) -> io::Result<()> {
        let file = open_regular(parent, name)?;
        delete_handle(&file)
    }

    pub fn remove_directory(parent: &File, name: &OsStr) -> io::Result<()> {
        let directory = relative_file(parent, name, true, false, false, true, false)?;
        delete_handle(&directory)
    }

    /// Enumerates names through the held directory handle. In particular,
    /// this never asks Win32 to resolve the display pathname again after the
    /// project root has been approved.
    pub fn read_directory_names(directory: &File) -> io::Result<Vec<OsString>> {
        const STATUS_NO_MORE_FILES: i32 = 0x8000_0006_u32 as i32;
        const BUFFER_BYTES: usize = 64 * 1024;
        const FILE_NAMES_HEADER_BYTES: usize = 12;

        let mut storage = vec![0_u64; BUFFER_BYTES / size_of::<u64>()];
        let mut names = Vec::new();
        let mut restart_scan = 1_u8;
        loop {
            let mut status_block = IoStatusBlock {
                status_or_pointer: 0,
                information: 0,
            };
            let status = unsafe {
                NtQueryDirectoryFile(
                    directory.as_raw_handle(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &raw mut status_block,
                    storage.as_mut_ptr().cast(),
                    BUFFER_BYTES as u32,
                    FILE_NAMES_INFORMATION_CLASS,
                    0,
                    std::ptr::null_mut(),
                    restart_scan,
                )
            };
            restart_scan = 0;
            if status == STATUS_NO_MORE_FILES {
                return Ok(names);
            }
            if status < 0 {
                let windows_error = unsafe { RtlNtStatusToDosError(status) };
                return Err(io::Error::from_raw_os_error(windows_error as i32));
            }
            let used = status_block.information.min(BUFFER_BYTES);
            if used == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "Windows directory enumeration returned no entries before end-of-directory",
                ));
            }
            let bytes = unsafe { std::slice::from_raw_parts(storage.as_ptr().cast::<u8>(), used) };
            let mut offset = 0_usize;
            loop {
                let header_end = offset.checked_add(FILE_NAMES_HEADER_BYTES).ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Windows directory entry overflow",
                    )
                })?;
                if header_end > bytes.len() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "truncated Windows directory entry header",
                    ));
                }
                let next =
                    u32::from_ne_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
                let name_bytes =
                    u32::from_ne_bytes(bytes[offset + 8..offset + 12].try_into().unwrap()) as usize;
                if name_bytes % size_of::<u16>() != 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Windows directory entry has an odd UTF-16 byte length",
                    ));
                }
                let name_end = header_end.checked_add(name_bytes).ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Windows directory name overflow",
                    )
                })?;
                if name_end > bytes.len() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "truncated Windows directory entry name",
                    ));
                }
                let words = bytes[header_end..name_end]
                    .chunks_exact(size_of::<u16>())
                    .map(|word| u16::from_ne_bytes([word[0], word[1]]))
                    .collect::<Vec<_>>();
                let name = OsString::from_wide(&words);
                if name != OsStr::new(".") && name != OsStr::new("..") {
                    names.push(name);
                }
                if next == 0 {
                    break;
                }
                if next < FILE_NAMES_HEADER_BYTES || next % size_of::<u32>() != 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "invalid Windows directory entry offset",
                    ));
                }
                offset = offset.checked_add(next).ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Windows directory offset overflow",
                    )
                })?;
                if offset >= bytes.len() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Windows directory entry offset leaves the returned buffer",
                    ));
                }
            }
        }
    }

    pub fn sync_directory(directory: &File) -> io::Result<()> {
        // File::sync_all maps to FlushFileBuffers on Windows. Directory
        // capabilities are opened with write access so this ordering barrier
        // is enforced instead of silently assuming a rename is durable.
        directory.sync_all()
    }
}

#[cfg(not(any(unix, windows)))]
pub(crate) mod metadata_publish_sys {
    use super::*;
    use std::io;

    fn unsupported() -> io::Error {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "metadata publication is unsupported",
        )
    }
    pub fn open_directory(_path: &Path) -> io::Result<File> {
        Err(unsupported())
    }
    pub fn open_child_directory(_parent: &File, _name: &OsStr) -> io::Result<File> {
        Err(unsupported())
    }
    pub fn open_regular(_parent: &File, _name: &OsStr) -> io::Result<File> {
        Err(unsupported())
    }
    pub fn create_new_regular(_parent: &File, _name: &OsStr) -> io::Result<File> {
        Err(unsupported())
    }
    pub fn create_directory(_parent: &File, _name: &OsStr) -> io::Result<File> {
        Err(unsupported())
    }
    pub fn create_private_directory(_parent: &File, _name: &OsStr) -> io::Result<File> {
        Err(unsupported())
    }
    pub fn rename_replace(_a: &File, _b: &OsStr, _c: &File, _d: &OsStr) -> io::Result<()> {
        Err(unsupported())
    }
    pub fn rename_exchange(_a: &File, _b: &OsStr, _c: &File, _d: &OsStr) -> io::Result<()> {
        Err(unsupported())
    }
    pub fn rename_exclusive(_a: &File, _b: &OsStr, _c: &File, _d: &OsStr) -> io::Result<()> {
        Err(unsupported())
    }
    pub fn unlink(_parent: &File, _name: &OsStr) -> io::Result<()> {
        Err(unsupported())
    }
    pub fn remove_directory(_parent: &File, _name: &OsStr) -> io::Result<()> {
        Err(unsupported())
    }
    pub fn read_directory_names(_directory: &File) -> io::Result<Vec<OsString>> {
        Err(unsupported())
    }
    pub fn sync_directory(_directory: &File) -> io::Result<()> {
        Err(unsupported())
    }
}

fn open_regular_nofollow(path: &Path) -> Result<File, EngineError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt as _;
        // FILE_FLAG_OPEN_REPARSE_POINT makes the handle describe the leaf
        // itself rather than following a raced junction/symlink.
        options.custom_flags(0x0020_0000);
    }
    options.open(path).map_err(|error| {
        target_refusal(format!(
            "refusing metadata target {}: no-follow open failed: {error}",
            path.display()
        ))
    })
}

fn validate_relative_path(value: &str) -> Result<PathBuf, EngineError> {
    let path = PathBuf::from(value);
    if value.is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(target_refusal(format!(
            "refusing unsafe metadata target relative path {value:?}"
        )));
    }
    Ok(path)
}

fn canonical_output_root(root: &Path) -> Result<PathBuf, EngineError> {
    let canonical = std::fs::canonicalize(root).map_err(|error| {
        target_refusal(format!(
            "cannot resolve the active project output root {}: {error}",
            root.display()
        ))
    })?;
    let metadata = std::fs::symlink_metadata(&canonical).map_err(|error| {
        target_refusal(format!(
            "cannot inspect the active project output root {}: {error}",
            canonical.display()
        ))
    })?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(target_refusal(format!(
            "the active project output root is not a real directory: {}",
            canonical.display()
        )));
    }
    Ok(canonical)
}

fn ensure_no_symlink_components(root: &Path, relative: &Path) -> Result<(), EngineError> {
    let mut current = root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(component) = component else {
            return Err(target_refusal(
                "metadata target contains a non-normal path component",
            ));
        };
        current.push(component);
        let metadata = std::fs::symlink_metadata(&current).map_err(|error| {
            target_refusal(format!(
                "cannot inspect metadata target component {}: {error}",
                current.display()
            ))
        })?;
        if metadata.file_type().is_symlink() || metadata_is_reparse_point(&metadata) {
            return Err(target_refusal(format!(
                "refusing linked or reparse-point metadata target component {}",
                current.display()
            )));
        }
    }
    Ok(())
}

fn ensure_safe_missing_leaf(root: &Path, relative: &Path) -> Result<PathBuf, EngineError> {
    let parent = relative.parent().unwrap_or_else(|| Path::new(""));
    if !parent.as_os_str().is_empty() {
        ensure_no_symlink_components(root, parent)?;
        let parent_metadata = std::fs::symlink_metadata(root.join(parent)).map_err(|error| {
            target_refusal(format!("cannot inspect metadata target parent: {error}"))
        })?;
        if !parent_metadata.is_dir() {
            return Err(target_refusal("metadata target parent is not a directory"));
        }
    }
    let candidate = root.join(relative);
    match std::fs::symlink_metadata(&candidate) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(candidate),
        Err(error) => Err(target_refusal(format!(
            "cannot inspect metadata sidecar target {}: {error}",
            candidate.display()
        ))),
        Ok(_) => Err(target_refusal(format!(
            "refusing an existing metadata sidecar without an engine file binding: {}",
            candidate.display()
        ))),
    }
}

fn snapshot_file(root: &Path, relative: &Path) -> Result<WrittenFileBinding, EngineError> {
    ensure_no_symlink_components(root, relative)?;
    let path = root.join(relative);
    let before = std::fs::symlink_metadata(&path).map_err(|error| {
        target_refusal(format!(
            "cannot inspect metadata target {}: {error}",
            path.display()
        ))
    })?;
    if before.file_type().is_symlink() || metadata_is_reparse_point(&before) || !before.is_file() {
        return Err(target_refusal(format!(
            "refusing non-regular metadata target {}",
            path.display()
        )));
    }
    if before.len() > MAX_METADATA_TARGET_BYTES {
        return Err(target_refusal(format!(
            "refusing metadata target larger than {MAX_METADATA_TARGET_BYTES} bytes: {}",
            path.display()
        )));
    }

    let mut file = open_regular_nofollow(&path)?;
    let opened = file.metadata().map_err(|error| {
        target_refusal(format!("cannot inspect opened metadata target: {error}"))
    })?;
    let (opened_volume, opened_file, opened_links) = platform_identity(&file, &opened);
    if opened_volume.is_none() || opened_file.is_none() || opened_links != Some(1) {
        return Err(target_refusal(format!(
            "refusing metadata target without a unique single-link filesystem identity: {}",
            path.display()
        )));
    }
    if !opened.is_file() || metadata_is_reparse_point(&opened) || opened.len() != before.len() {
        return Err(target_refusal(format!(
            "metadata target identity changed during no-follow open: {}",
            path.display()
        )));
    }

    let sha256 = hash_open_file_bounded(&mut file, before.len())?;
    let after = file
        .metadata()
        .map_err(|error| target_refusal(format!("cannot re-inspect metadata target: {error}")))?;
    let (after_volume, after_file, after_links) = platform_identity(&file, &after);
    let reopened = open_regular_nofollow(&path)?;
    let reopened_metadata = reopened.metadata().map_err(|error| {
        target_refusal(format!("cannot re-open bound metadata target: {error}"))
    })?;
    let reopened_identity = platform_identity(&reopened, &reopened_metadata);
    if (opened_volume, opened_file) != (after_volume, after_file)
        || opened.len() != after.len()
        || opened_links != after_links
        || reopened_identity != (after_volume, after_file, after_links)
        || reopened_metadata.len() != after.len()
        || metadata_is_reparse_point(&reopened_metadata)
    {
        return Err(target_refusal(format!(
            "metadata target changed while its identity was being bound: {}",
            path.display()
        )));
    }

    let relative_path = relative.to_str().ok_or_else(|| {
        target_refusal("metadata target path is not valid UTF-8 and cannot be bound safely")
    })?;
    Ok(WrittenFileBinding {
        relative_path: relative_path.to_string(),
        sha256,
        byte_length: after.len(),
        volume_id: after_volume,
        file_id: after_file,
    })
}

fn relative_written_path(root: &Path, written_path: &Path) -> Result<PathBuf, EngineError> {
    if !written_path.is_absolute() {
        return Err(target_refusal(format!(
            "metadata-capable output path is not absolute: {}",
            written_path.display()
        )));
    }
    let root_absolute = if root.is_absolute() {
        root.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|error| target_refusal(format!("cannot resolve current directory: {error}")))?
            .join(root)
    };
    let canonical_root = canonical_output_root(root)?;
    let relative = written_path
        .strip_prefix(&root_absolute)
        .or_else(|_| written_path.strip_prefix(&canonical_root))
        .map_err(|_| {
            target_refusal(format!(
                "metadata-capable output is outside the active project output root: {}",
                written_path.display()
            ))
        })?;
    let relative = validate_relative_path(
        relative
            .to_str()
            .ok_or_else(|| target_refusal("metadata output path is not valid UTF-8"))?,
    )?;
    ensure_no_symlink_components(&canonical_root, &relative)?;
    let canonical_target = std::fs::canonicalize(canonical_root.join(&relative))
        .map_err(|error| target_refusal(format!("cannot canonicalize metadata output: {error}")))?;
    if !canonical_target.starts_with(&canonical_root) {
        return Err(target_refusal(
            "metadata output escapes the active project output root",
        ));
    }
    Ok(relative)
}

fn bind_written_path(root: &Path, path: &Path) -> Result<WrittenFileBinding, EngineError> {
    let canonical_root = canonical_output_root(root)?;
    let relative = relative_written_path(root, path)?;
    snapshot_file(&canonical_root, &relative)
}

fn relative_publication_path_at(
    requested_root: &Path,
    canonical_root: &Path,
    written_path: &Path,
) -> Result<PathBuf, EngineError> {
    if !requested_root.is_absolute() || !canonical_root.is_absolute() || !written_path.is_absolute()
    {
        return Err(target_refusal(
            "held metadata publication roots and output path must be absolute",
        ));
    }
    let relative = written_path
        .strip_prefix(requested_root)
        .or_else(|_| written_path.strip_prefix(canonical_root))
        .map_err(|_| {
            target_refusal(format!(
                "metadata-capable output is outside the held project output root: {}",
                written_path.display()
            ))
        })?;
    validate_relative_path(
        relative
            .to_str()
            .ok_or_else(|| target_refusal("metadata output path is not valid UTF-8"))?,
    )
}

fn open_regular_beneath(root: &File, relative: &Path) -> Result<File, EngineError> {
    let components = relative
        .components()
        .map(|component| match component {
            Component::Normal(value) => Ok(value.to_os_string()),
            _ => Err(target_refusal(
                "metadata publication contains a non-normal relative component",
            )),
        })
        .collect::<Result<Vec<_>, _>>()?;
    let (leaf, parents) = components
        .split_last()
        .ok_or_else(|| target_refusal("metadata publication relative path has no file name"))?;
    let mut directory = root.try_clone().map_err(|error| {
        target_refusal(format!(
            "cannot retain held project root while binding metadata publication: {error}"
        ))
    })?;
    for component in parents {
        directory =
            metadata_publish_sys::open_child_directory(&directory, component).map_err(|error| {
                target_refusal(format!(
                    "cannot open held metadata publication parent component {:?}: {error}",
                    component
                ))
            })?;
    }
    metadata_publish_sys::open_regular(&directory, leaf).map_err(|error| {
        target_refusal(format!(
            "cannot open held metadata publication leaf {:?}: {error}",
            leaf
        ))
    })
}

/// Capability-rooted form of `bind_publication_proof`. The final pathname is
/// used only to derive a validated relative name beneath the already-held
/// project root; every filesystem lookup is handle-relative and the final
/// leaf must still be the renderer's exact unique inode before and after the
/// bounded hash.
fn bind_publication_proof_at(
    root: &File,
    requested_root: &Path,
    canonical_root: &Path,
    proof: &crate::render::PublishedFileProof,
) -> Result<WrittenFileBinding, EngineError> {
    let root_metadata = root.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot inspect held metadata project root: {error}"
        ))
    })?;
    if !root_metadata.is_dir() || metadata_is_reparse_point(&root_metadata) {
        return Err(target_refusal(
            "held metadata project root is not a normal directory",
        ));
    }
    let relative =
        relative_publication_path_at(requested_root, canonical_root, proof.final_path())?;
    let path = canonical_root.join(&relative);
    let mut held = proof.try_clone_file()?;
    let held_before = held.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot inspect held publication proof for {}: {error}",
            path.display()
        ))
    })?;
    let opened = open_regular_beneath(root, &relative)?;
    let opened_before = opened.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot inspect handle-relative metadata target {}: {error}",
            path.display()
        ))
    })?;
    let held_identity = platform_identity(&held, &held_before);
    if held_identity.0.is_none()
        || held_identity.1.is_none()
        || held_identity.2 != Some(1)
        || platform_identity(&opened, &opened_before) != held_identity
        || !held_before.is_file()
        || !opened_before.is_file()
        || metadata_is_reparse_point(&held_before)
        || metadata_is_reparse_point(&opened_before)
        || held_before.len() != opened_before.len()
    {
        return Err(target_refusal(format!(
            "refusing replaced, linked, or unverifiable published metadata target {}",
            path.display()
        )));
    }
    if held_before.len() > MAX_METADATA_TARGET_BYTES {
        return Err(target_refusal(format!(
            "refusing metadata target larger than {MAX_METADATA_TARGET_BYTES} bytes: {}",
            path.display()
        )));
    }

    let sha256 = hash_open_file_bounded(&mut held, held_before.len())?;
    let held_after = held.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot re-inspect held metadata publication {}: {error}",
            path.display()
        ))
    })?;
    let reopened = open_regular_beneath(root, &relative)?;
    let reopened_after = reopened.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot re-inspect handle-relative metadata target {}: {error}",
            path.display()
        ))
    })?;
    if platform_identity(&held, &held_after) != held_identity
        || platform_identity(&reopened, &reopened_after) != held_identity
        || held_after.len() != held_before.len()
        || reopened_after.len() != held_before.len()
        || metadata_is_reparse_point(&held_after)
        || metadata_is_reparse_point(&reopened_after)
    {
        return Err(target_refusal(format!(
            "published metadata target changed while its held identity was being bound: {}",
            path.display()
        )));
    }

    let relative_path = relative.to_str().ok_or_else(|| {
        target_refusal("metadata target path is not valid UTF-8 and cannot be bound safely")
    })?;
    Ok(WrittenFileBinding {
        relative_path: relative_path.to_string(),
        sha256,
        byte_length: held_after.len(),
        volume_id: held_identity.0,
        file_id: held_identity.1,
    })
}

/// Mints a receipt capability from the file descriptor retained by the
/// render/publish path.  Reopening a completed pathname and trusting whatever
/// happens to be there would ratify an attacker replacement; the reopened leaf
/// is used only to prove it still resolves to the exact held inode.
#[cfg(test)]
fn bind_publication_proof(
    root: &Path,
    proof: &crate::render::PublishedFileProof,
) -> Result<WrittenFileBinding, EngineError> {
    let canonical_root = canonical_output_root(root)?;
    let relative = relative_written_path(root, proof.final_path())?;
    ensure_no_symlink_components(&canonical_root, &relative)?;
    let path = canonical_root.join(&relative);

    let mut held = proof.try_clone_file()?;
    let held_before = held.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot inspect held publication proof for {}: {error}",
            path.display()
        ))
    })?;
    let linked_before = std::fs::symlink_metadata(&path).map_err(|error| {
        target_refusal(format!(
            "cannot inspect published metadata target {}: {error}",
            path.display()
        ))
    })?;
    let opened = open_regular_nofollow(&path)?;
    let opened_before = opened.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot inspect no-follow metadata target {}: {error}",
            path.display()
        ))
    })?;

    let held_identity = platform_identity(&held, &held_before);
    let opened_identity = platform_identity(&opened, &opened_before);
    if held_identity.0.is_none()
        || held_identity.1.is_none()
        || held_identity.2 != Some(1)
        || opened_identity != held_identity
        || !held_before.is_file()
        || !linked_before.is_file()
        || !opened_before.is_file()
        || linked_before.file_type().is_symlink()
        || metadata_is_reparse_point(&held_before)
        || metadata_is_reparse_point(&linked_before)
        || metadata_is_reparse_point(&opened_before)
        || held_before.len() != linked_before.len()
        || held_before.len() != opened_before.len()
    {
        return Err(target_refusal(format!(
            "refusing replaced, linked, or unverifiable published metadata target {}",
            path.display()
        )));
    }
    if held_before.len() > MAX_METADATA_TARGET_BYTES {
        return Err(target_refusal(format!(
            "refusing metadata target larger than {MAX_METADATA_TARGET_BYTES} bytes: {}",
            path.display()
        )));
    }

    let sha256 = hash_open_file_bounded(&mut held, held_before.len())?;

    let held_after = held.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot re-inspect held metadata publication {}: {error}",
            path.display()
        ))
    })?;
    let linked_after = std::fs::symlink_metadata(&path).map_err(|error| {
        target_refusal(format!(
            "cannot re-inspect published metadata target {}: {error}",
            path.display()
        ))
    })?;
    let reopened = open_regular_nofollow(&path)?;
    let reopened_after = reopened.metadata().map_err(|error| {
        target_refusal(format!(
            "cannot re-inspect no-follow metadata target {}: {error}",
            path.display()
        ))
    })?;
    if platform_identity(&held, &held_after) != held_identity
        || platform_identity(&reopened, &reopened_after) != held_identity
        || held_after.len() != held_before.len()
        || linked_after.len() != held_before.len()
        || reopened_after.len() != held_before.len()
        || linked_after.file_type().is_symlink()
        || metadata_is_reparse_point(&linked_after)
        || metadata_is_reparse_point(&reopened_after)
    {
        return Err(target_refusal(format!(
            "published metadata target changed while its held identity was being bound: {}",
            path.display()
        )));
    }

    let relative_path = relative.to_str().ok_or_else(|| {
        target_refusal("metadata target path is not valid UTF-8 and cannot be bound safely")
    })?;
    Ok(WrittenFileBinding {
        relative_path: relative_path.to_string(),
        sha256,
        byte_length: held_after.len(),
        volume_id: held_identity.0,
        file_id: held_identity.1,
    })
}

fn reject_publication_aliases(bindings: &MetadataOutputBindings) -> Result<(), EngineError> {
    let mut identities = std::collections::HashSet::new();
    for (role, binding) in [
        ("archive", bindings.archive.as_ref()),
        ("positive", bindings.positive.as_ref()),
        ("preview", bindings.preview.as_ref()),
    ] {
        let Some(binding) = binding else { continue };
        let identity = (binding.volume_id, binding.file_id);
        if !identities.insert(identity) {
            return Err(target_refusal(format!(
                "refusing metadata publication whose {role} aliases another output"
            )));
        }
    }
    Ok(())
}

/// Proof-aware receipt binder used by both scan backends.  Any failed proof
/// rejects the whole binding set so callers can surface a typed frame failure;
/// no partial or pathname-only capability is ever returned.
#[cfg(test)]
pub(crate) fn bind_metadata_output_publications(
    root: &Path,
    proofs: &crate::render::MetadataPublicationProofs,
) -> Result<MetadataOutputBindings, EngineError> {
    let bindings = MetadataOutputBindings {
        archive: proofs
            .archive
            .as_ref()
            .map(|proof| bind_publication_proof(root, proof))
            .transpose()?,
        archive_xmp: None,
        positive: proofs
            .positive
            .as_ref()
            .map(|proof| bind_publication_proof(root, proof))
            .transpose()?,
        preview: proofs
            .preview
            .as_ref()
            .map(|proof| bind_publication_proof(root, proof))
            .transpose()?,
    };
    reject_publication_aliases(&bindings)?;
    Ok(bindings)
}

/// Proof-aware receipt binder beneath a project directory capability captured
/// before capture. This is the production scan path: a later replacement of
/// either display spelling cannot redirect or re-authorize publication.
pub(crate) fn bind_metadata_output_publications_at(
    root: &File,
    requested_root: &Path,
    canonical_root: &Path,
    proofs: &crate::render::MetadataPublicationProofs,
) -> Result<MetadataOutputBindings, EngineError> {
    let bind = |proof: &crate::render::PublishedFileProof| {
        bind_publication_proof_at(root, requested_root, canonical_root, proof)
    };
    let bindings = MetadataOutputBindings {
        archive: proofs.archive.as_ref().map(bind).transpose()?,
        archive_xmp: None,
        positive: proofs.positive.as_ref().map(bind).transpose()?,
        preview: proofs.preview.as_ref().map(bind).transpose()?,
    };
    reject_publication_aliases(&bindings)?;
    Ok(bindings)
}

/// Mints the relative-path/hash/file-identity capabilities stored beside a
/// completed scan receipt. If any nominated file is outside the project
/// output root, linked, or unstable, no partially trusted binding set is
/// returned.
pub fn bind_metadata_outputs(
    root: &Path,
    archive: Option<&Path>,
    archive_xmp: Option<&Path>,
    positive: Option<&Path>,
    preview: Option<&Path>,
) -> Result<MetadataOutputBindings, EngineError> {
    Ok(MetadataOutputBindings {
        archive: archive
            .map(|path| bind_written_path(root, path))
            .transpose()?,
        archive_xmp: archive_xmp
            .map(|path| bind_written_path(root, path))
            .transpose()?,
        positive: positive
            .map(|path| bind_written_path(root, path))
            .transpose()?,
        preview: preview
            .map(|path| bind_written_path(root, path))
            .transpose()?,
    })
}

fn verify_binding(root: &Path, binding: &WrittenFileBinding) -> Result<PathBuf, EngineError> {
    if binding.sha256.len() != 64
        || !binding
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(target_refusal(
            "metadata target binding contains an invalid SHA-256",
        ));
    }
    if binding.byte_length > MAX_METADATA_TARGET_BYTES
        || binding.volume_id.is_none()
        || binding.file_id.is_none()
    {
        return Err(target_refusal(
            "metadata target binding lacks a bounded, stable filesystem identity",
        ));
    }
    let relative = validate_relative_path(&binding.relative_path)?;
    let path = root.join(&relative);
    let metadata = std::fs::symlink_metadata(&path).map_err(|error| {
        target_refusal(format!(
            "cannot inspect metadata target {}: {error}",
            path.display()
        ))
    })?;
    if metadata.len() != binding.byte_length {
        return Err(target_refusal(format!(
            "refusing replaced or resized metadata target {}",
            path.display()
        )));
    }
    let current = snapshot_file(root, &relative)?;
    if current.sha256 != binding.sha256
        || current.byte_length != binding.byte_length
        || current.volume_id != binding.volume_id
        || current.file_id != binding.file_id
    {
        return Err(target_refusal(format!(
            "refusing replaced or modified metadata target {}",
            root.join(&relative).display()
        )));
    }
    Ok(root.join(relative))
}

fn bindings_alias(left: &WrittenFileBinding, right: &WrittenFileBinding) -> bool {
    left.volume_id.is_some()
        && left.file_id.is_some()
        && left.volume_id == right.volume_id
        && left.file_id == right.file_id
}

fn ensure_legacy_path_matches(legacy_path: &str, trusted_path: &Path) -> Result<(), EngineError> {
    let canonical_legacy = std::fs::canonicalize(legacy_path).map_err(|error| {
        target_refusal(format!(
            "cannot resolve recorded output path {legacy_path:?}: {error}"
        ))
    })?;
    let canonical_trusted = std::fs::canonicalize(trusted_path).map_err(|error| {
        target_refusal(format!("cannot resolve trusted metadata target: {error}"))
    })?;
    if canonical_legacy != canonical_trusted {
        return Err(target_refusal(
            "recorded output path does not match its engine-authored relative binding",
        ));
    }
    Ok(())
}

fn require_binding_consistency(
    label: &str,
    legacy: Option<&String>,
    binding: Option<&WrittenFileBinding>,
) -> Result<(), EngineError> {
    if legacy.is_some() != binding.is_some() {
        return Err(target_refusal(format!(
            "metadata target {label} is missing its engine-authored file binding"
        )));
    }
    Ok(())
}

fn verified_output_paths(
    root: &Path,
    outputs: &WrittenOutputs,
) -> Result<
    (
        Option<PathBuf>,
        Option<PathBuf>,
        Option<PathBuf>,
        Option<PathBuf>,
    ),
    EngineError,
> {
    let canonical_root = canonical_output_root(root)?;
    let bindings = outputs.metadata_bindings.as_ref().ok_or_else(|| {
        target_refusal(
            "this receipt predates secure metadata target bindings; rescan the frame before applying metadata",
        )
    })?;
    require_binding_consistency(
        "archive",
        outputs.archive_path.as_ref(),
        bindings.archive.as_ref(),
    )?;
    require_binding_consistency(
        "positive",
        outputs.positive_path.as_ref(),
        bindings.positive.as_ref(),
    )?;
    require_binding_consistency(
        "preview",
        outputs.preview_path.as_ref(),
        bindings.preview.as_ref(),
    )?;

    let archive = bindings
        .archive
        .as_ref()
        .map(|binding| verify_binding(&canonical_root, binding))
        .transpose()?;
    let positive = bindings
        .positive
        .as_ref()
        .map(|binding| verify_binding(&canonical_root, binding))
        .transpose()?;
    let preview = bindings
        .preview
        .as_ref()
        .map(|binding| verify_binding(&canonical_root, binding))
        .transpose()?;
    if let (Some(legacy), Some(trusted)) = (&outputs.archive_path, &archive) {
        ensure_legacy_path_matches(legacy, trusted)?;
    }
    if let (Some(legacy), Some(trusted)) = (&outputs.positive_path, &positive) {
        ensure_legacy_path_matches(legacy, trusted)?;
    }
    if let (Some(legacy), Some(trusted)) = (&outputs.preview_path, &preview) {
        ensure_legacy_path_matches(legacy, trusted)?;
    }

    let archive_xmp = match (&archive, &bindings.archive_xmp) {
        (Some(archive), Some(binding)) => {
            let trusted = verify_binding(&canonical_root, binding)?;
            if trusted != archive.with_extension("xmp") {
                return Err(target_refusal(
                    "archive sidecar binding is not the archive's exact XMP sibling",
                ));
            }
            Some(trusted)
        }
        (Some(archive), None) => {
            let relative_archive = archive.strip_prefix(&canonical_root).map_err(|_| {
                target_refusal("trusted archive escaped the active project output root")
            })?;
            let sidecar_relative = relative_archive.with_extension("xmp");
            if sidecar_relative == relative_archive {
                return Err(target_refusal(
                    "archive path cannot safely nominate an XMP sibling",
                ));
            }
            Some(ensure_safe_missing_leaf(
                &canonical_root,
                &sidecar_relative,
            )?)
        }
        (None, Some(_)) => {
            return Err(target_refusal(
                "receipt contains an archive-sidecar binding without an archive",
            ))
        }
        (None, None) => None,
    };

    let roles = [
        ("archive", archive.as_ref(), bindings.archive.as_ref()),
        (
            "archive XMP sidecar",
            archive_xmp.as_ref(),
            bindings.archive_xmp.as_ref(),
        ),
        ("positive", positive.as_ref(), bindings.positive.as_ref()),
        ("preview", preview.as_ref(), bindings.preview.as_ref()),
    ];
    for (index, (left_role, left_path, left_binding)) in roles.iter().enumerate() {
        let Some(left_path) = left_path else {
            continue;
        };
        for (right_role, right_path, right_binding) in roles.iter().skip(index + 1) {
            let Some(right_path) = right_path else {
                continue;
            };
            let same_identity = match (left_binding, right_binding) {
                (Some(left), Some(right)) => bindings_alias(left, right),
                _ => false,
            };
            if left_path == right_path || same_identity {
                return Err(target_refusal(format!(
                    "metadata roles {left_role} and {right_role} alias the same physical file"
                )));
            }
        }
    }
    Ok((archive, archive_xmp, positive, preview))
}

/// Resolves and verifies the target file list for `frame_index` beneath the
/// active project directory. Absolute receipt paths are never authority:
/// every target must carry an engine-minted relative binding, remain a
/// single-link regular file with the same filesystem identity and SHA-256,
/// and have no symlinked component. The archive's XMP sibling may be absent
/// on its first write, but an existing unbound sidecar is refused.
pub fn resolve_targets(
    project: &ScanProject,
    frame_index: u32,
    output_root: &Path,
) -> Result<Vec<PathBuf>, EngineError> {
    let frame = find_frame(project, frame_index)?;
    let Some(latest_receipt) = frame.receipts.last() else {
        return Ok(Vec::new());
    };
    let Some(outputs) = latest_receipt.outputs.as_ref() else {
        return Ok(Vec::new());
    };
    let (archive, archive_xmp, positive, preview) = verified_output_paths(output_root, outputs)?;
    let mut targets = Vec::new();
    if let Some(sidecar) = archive_xmp {
        if archive.as_ref() == Some(&sidecar) {
            return Err(target_refusal(
                "refusing to target the retained archive itself",
            ));
        }
        targets.push(sidecar);
    }
    targets.extend(positive);
    targets.extend(preview);
    let unique = targets.iter().collect::<std::collections::HashSet<_>>();
    if unique.len() != targets.len() {
        return Err(target_refusal(
            "metadata receipt resolves two roles to the same file",
        ));
    }
    Ok(targets)
}

/// Rebinds every metadata-capable output after a successful ExifTool write.
/// ExifTool may replace an inode as part of its safe-update strategy, so the
/// new identity/hash must be durably persisted before another apply can be
/// authorized.
pub fn refresh_metadata_bindings(
    output_root: &Path,
    outputs: &WrittenOutputs,
) -> Result<MetadataOutputBindings, EngineError> {
    let bindings = outputs
        .metadata_bindings
        .as_ref()
        .ok_or_else(|| target_refusal("metadata outputs have no secure file bindings"))?;
    require_binding_consistency(
        "archive",
        outputs.archive_path.as_ref(),
        bindings.archive.as_ref(),
    )?;
    require_binding_consistency(
        "positive",
        outputs.positive_path.as_ref(),
        bindings.positive.as_ref(),
    )?;
    require_binding_consistency(
        "preview",
        outputs.preview_path.as_ref(),
        bindings.preview.as_ref(),
    )?;
    let canonical_root = canonical_output_root(output_root)?;
    let bound_path = |binding: &WrittenFileBinding| -> Result<PathBuf, EngineError> {
        Ok(canonical_root.join(validate_relative_path(&binding.relative_path)?))
    };
    let archive = bindings.archive.as_ref().map(bound_path).transpose()?;
    let archive_xmp = archive.as_ref().map(|path| path.with_extension("xmp"));
    bind_metadata_outputs(
        &canonical_root,
        archive.as_deref(),
        archive_xmp.as_deref(),
        bindings
            .positive
            .as_ref()
            .map(bound_path)
            .transpose()?
            .as_deref(),
        bindings
            .preview
            .as_ref()
            .map(bound_path)
            .transpose()?
            .as_deref(),
    )
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
enum MetadataTargetRole {
    ArchiveXmp,
    Positive,
    Preview,
}

struct StagedMetadataTarget {
    role: MetadataTargetRole,
    relative: PathBuf,
    expected: Option<WrittenFileBinding>,
    parent: File,
    leaf: OsString,
    staged_name: OsString,
    execution_path: PathBuf,
    published_binding: Option<WrittenFileBinding>,
}

#[derive(Debug)]
pub struct MetadataExecutionResult {
    pub output: BoundedCommandOutput,
    pub bindings: Option<MetadataOutputBindings>,
    pub project: Option<ScanProject>,
}

const METADATA_JOURNAL_VERSION: u32 = 1;
const METADATA_JOURNAL_FILE: &str = "transaction.json";
const METADATA_ATTEMPT_PREFIX: &str = ".scanstudio-metadata-";
const METADATA_ATTEMPT_SUFFIX: &str = ".attempt";
#[cfg(test)]
static METADATA_TRANSACTION_FAILPOINT: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static METADATA_TRANSACTION_FAILPOINT_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
#[cfg(test)]
static METADATA_TRANSACTION_FAILPOINT_OWNER: std::sync::Mutex<Option<std::thread::ThreadId>> =
    std::sync::Mutex::new(None);

#[cfg(test)]
fn set_metadata_transaction_failpoint(value: usize) {
    *METADATA_TRANSACTION_FAILPOINT_OWNER.lock().unwrap() =
        (value != 0).then(|| std::thread::current().id());
    METADATA_TRANSACTION_FAILPOINT.store(value, Ordering::Release);
}

#[cfg(test)]
fn current_metadata_transaction_failpoint() -> usize {
    let value = METADATA_TRANSACTION_FAILPOINT.load(Ordering::Acquire);
    if value == 0
        || METADATA_TRANSACTION_FAILPOINT_OWNER
            .lock()
            .unwrap()
            .as_ref()
            != Some(&std::thread::current().id())
    {
        0
    } else {
        value
    }
}

#[cfg(test)]
pub(crate) fn metadata_transaction_failpoint_is(value: usize) -> bool {
    current_metadata_transaction_failpoint() == value
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MetadataJournalTarget {
    role: MetadataTargetRole,
    relative_path: String,
    old_binding: Option<WrittenFileBinding>,
    new_binding: WrittenFileBinding,
    staged_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MetadataTransactionJournal {
    version: u32,
    transaction_id: String,
    frame_index: u32,
    expected_receipt: ScanReceipt,
    new_bindings: MetadataOutputBindings,
    targets: Vec<MetadataJournalTarget>,
}

struct MetadataCommitContext<'a> {
    frame_index: u32,
    expected_receipt: &'a ScanReceipt,
}

/// Pathname-only tools such as ExifTool cannot be given a directory below an
/// adversarial project root: a rename of that directory could redirect the
/// tool after staging. This workspace lives beneath the OS-managed temporary
/// root, has an unpredictable private name, and retains both parent and child
/// capabilities so its pathname can be revalidated immediately around the
/// subprocess boundary.
struct PrivateMetadataWorkspace {
    parent_path: PathBuf,
    parent: File,
    name: OsString,
    path: PathBuf,
    directory: File,
}

fn directory_identity(directory: &File) -> Result<(u64, u64), EngineError> {
    let metadata = directory.metadata().map_err(|error| {
        subprocess_error(format!(
            "cannot inspect private metadata directory: {error}"
        ))
    })?;
    if !metadata.is_dir() || metadata_is_reparse_point(&metadata) {
        return Err(target_refusal(
            "private metadata workspace is a reparse point or non-directory",
        ));
    }
    let (volume, inode, _) = held_file_identity(directory, &metadata).ok_or_else(|| {
        target_refusal("private metadata workspace has no stable filesystem identity")
    })?;
    Ok((volume, inode))
}

#[cfg(unix)]
fn verify_private_directory_permissions(directory: &File) -> Result<(), EngineError> {
    use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
    let metadata = directory.metadata().map_err(|error| {
        subprocess_error(format!(
            "cannot inspect private metadata permissions: {error}"
        ))
    })?;
    if metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o777 != 0o700
    {
        return Err(target_refusal(
            "private metadata workspace is not owned by this engine user with mode 0700",
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn verify_private_directory_permissions(directory: &File) -> Result<(), EngineError> {
    metadata_publish_sys::verify_private_directory_permissions(directory).map_err(|error| {
        target_refusal(format!(
            "private metadata workspace does not have a protected owner-only Windows DACL: {error}"
        ))
    })
}

#[cfg(not(any(unix, windows)))]
fn verify_private_directory_permissions(_directory: &File) -> Result<(), EngineError> {
    Ok(())
}

fn verify_child_directory_authority(
    parent: &File,
    name: &OsStr,
    held: &File,
    label: &str,
) -> Result<(), EngineError> {
    let reopened = metadata_publish_sys::open_child_directory(parent, name).map_err(|error| {
        target_refusal(format!(
            "cannot re-open {label} without following aliases: {error}"
        ))
    })?;
    if directory_identity(held)? != directory_identity(&reopened)? {
        return Err(target_refusal(format!(
            "{label} namespace changed after its directory capability was acquired"
        )));
    }
    Ok(())
}

pub(crate) fn verify_directory_path_authority(
    path: &Path,
    held: &File,
    label: &str,
) -> Result<(), EngineError> {
    let reopened = metadata_publish_sys::open_directory(path).map_err(|error| {
        target_refusal(format!(
            "cannot re-open {label} without following aliases: {error}"
        ))
    })?;
    if directory_identity(held)? != directory_identity(&reopened)? {
        return Err(target_refusal(format!(
            "{label} pathname no longer reaches the held directory authority"
        )));
    }
    Ok(())
}

impl PrivateMetadataWorkspace {
    fn create() -> Result<Self, EngineError> {
        let parent_path = std::fs::canonicalize(std::env::temp_dir()).map_err(|error| {
            subprocess_error(format!("cannot resolve engine temporary root: {error}"))
        })?;
        let parent = metadata_publish_sys::open_directory(&parent_path).map_err(|error| {
            target_refusal(format!(
                "cannot anchor engine temporary root {}: {error}",
                parent_path.display()
            ))
        })?;
        for _ in 0..32 {
            let name = OsString::from(format!(
                "scanstudio-engine-metadata-{}",
                random_metadata_token()?
            ));
            let path = parent_path.join(&name);
            let directory = match metadata_publish_sys::create_private_directory(&parent, &name) {
                Ok(directory) => directory,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(subprocess_error(format!(
                        "cannot create engine-private metadata workspace: {error}"
                    )))
                }
            };
            let workspace = Self {
                parent_path: parent_path.clone(),
                parent,
                name,
                path,
                directory,
            };
            workspace.verify_namespace()?;
            verify_private_directory_permissions(&workspace.directory)?;
            metadata_publish_sys::sync_directory(&workspace.directory).map_err(|error| {
                subprocess_error(format!("cannot sync private metadata workspace: {error}"))
            })?;
            metadata_publish_sys::sync_directory(&workspace.parent).map_err(|error| {
                subprocess_error(format!(
                    "cannot sync private metadata workspace root: {error}"
                ))
            })?;
            return Ok(workspace);
        }
        Err(subprocess_error(
            "could not reserve a collision-isolated private metadata workspace",
        ))
    }

    fn verify_namespace(&self) -> Result<(), EngineError> {
        let reopened_parent =
            metadata_publish_sys::open_directory(&self.parent_path).map_err(|error| {
                target_refusal(format!("cannot re-open engine temporary root: {error}"))
            })?;
        if directory_identity(&self.parent)? != directory_identity(&reopened_parent)? {
            return Err(target_refusal(
                "engine temporary root identity changed during metadata execution",
            ));
        }
        verify_child_directory_authority(
            &self.parent,
            &self.name,
            &self.directory,
            "private metadata workspace",
        )?;
        verify_private_directory_permissions(&self.directory)
    }

    fn retire(self, target_names: &[OsString]) -> Result<(), EngineError> {
        self.verify_namespace()?;
        for target_name in target_names {
            let mut candidates = vec![target_name.clone()];
            for suffix in ["_original", "_exiftool_tmp"] {
                let mut candidate = target_name.clone();
                candidate.push(suffix);
                candidates.push(candidate);
            }
            for candidate in candidates {
                match metadata_publish_sys::unlink(&self.directory, &candidate) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => {
                        return Err(subprocess_error(format!(
                            "cannot retire private metadata workspace entry {candidate:?}: {error}"
                        )))
                    }
                }
            }
        }
        metadata_publish_sys::sync_directory(&self.directory).map_err(|error| {
            subprocess_error(format!(
                "cannot sync retired private metadata workspace: {error}"
            ))
        })?;
        self.verify_namespace()?;
        let Self {
            parent,
            name,
            directory,
            ..
        } = self;
        drop(directory);
        metadata_publish_sys::remove_directory(&parent, &name).map_err(|error| {
            subprocess_error(format!("cannot remove private metadata workspace: {error}"))
        })?;
        metadata_publish_sys::sync_directory(&parent).map_err(|error| {
            subprocess_error(format!(
                "cannot sync private metadata workspace retirement: {error}"
            ))
        })
    }
}

fn random_metadata_token() -> Result<String, EngineError> {
    let mut random = [0_u8; 16];
    getrandom::fill(&mut random).map_err(|error| {
        subprocess_error(format!(
            "failed to obtain metadata staging randomness: {error}"
        ))
    })?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn open_anchored_parent(root: &File, relative: &Path) -> Result<File, EngineError> {
    let mut directory = root.try_clone().map_err(|error| {
        target_refusal(format!(
            "cannot duplicate anchored project output root: {error}"
        ))
    })?;
    if let Some(parent) = relative.parent() {
        for component in parent.components() {
            let Component::Normal(component) = component else {
                return Err(target_refusal(
                    "metadata target parent contains a non-normal component",
                ));
            };
            directory = metadata_publish_sys::open_child_directory(&directory, component).map_err(
                |error| {
                    target_refusal(format!(
                        "cannot anchor metadata target directory component {:?}: {error}",
                        component
                    ))
                },
            )?;
        }
    }
    Ok(directory)
}

fn binding_from_open_file(
    file: &mut File,
    relative_path: &str,
) -> Result<WrittenFileBinding, EngineError> {
    ensure_supported_metadata_filesystem(file).map_err(|error| {
        target_refusal(format!(
            "metadata file filesystem cannot provide stable identity authority: {error}"
        ))
    })?;
    let before = file
        .metadata()
        .map_err(|error| target_refusal(format!("cannot inspect opened metadata file: {error}")))?;
    let (volume_id, file_id, links) = platform_identity(file, &before);
    if !before.is_file()
        || metadata_is_reparse_point(&before)
        || volume_id.is_none()
        || file_id.is_none()
        || links != Some(1)
        || before.len() > MAX_METADATA_TARGET_BYTES
    {
        return Err(target_refusal(
            "opened metadata file lacks a bounded, unique single-link identity",
        ));
    }
    let sha256 = hash_open_file_bounded(file, before.len())?;
    let after = file.metadata().map_err(|error| {
        target_refusal(format!("cannot re-inspect opened metadata file: {error}"))
    })?;
    let (after_volume, after_file, after_links) = platform_identity(file, &after);
    if metadata_is_reparse_point(&after)
        || before.len() != after.len()
        || (volume_id, file_id, links) != (after_volume, after_file, after_links)
    {
        return Err(target_refusal(
            "metadata file changed while its held descriptor was hashed",
        ));
    }
    Ok(WrittenFileBinding {
        relative_path: relative_path.to_string(),
        sha256,
        byte_length: after.len(),
        volume_id,
        file_id,
    })
}

fn copy_exact_bounded(
    source: &mut impl Read,
    destination: &mut impl Write,
    expected_len: u64,
) -> std::io::Result<()> {
    let copied = std::io::copy(
        &mut source.take(expected_len.saturating_add(1)),
        destination,
    )?;
    if copied != expected_len {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "metadata source length changed while copying: expected {expected_len}, copied {copied}"
            ),
        ));
    }
    Ok(())
}

#[cfg(test)]
static COPY_SOURCE_AFTER_BIND_HOOK: std::sync::Mutex<Option<Box<dyn FnOnce() + Send + 'static>>> =
    std::sync::Mutex::new(None);

#[cfg(test)]
fn set_copy_source_after_bind_hook(hook: impl FnOnce() + Send + 'static) {
    *COPY_SOURCE_AFTER_BIND_HOOK.lock().unwrap() = Some(Box::new(hook));
}

#[cfg(test)]
fn run_copy_source_after_bind_hook() {
    if let Some(hook) = COPY_SOURCE_AFTER_BIND_HOOK.lock().unwrap().take() {
        hook();
    }
}

fn copy_bound_source_to_stage(
    parent: &File,
    leaf: &OsStr,
    expected: &WrittenFileBinding,
    attempt: &File,
    staged_name: &OsStr,
    staged_path: &Path,
) -> Result<(), EngineError> {
    let mut source = metadata_publish_sys::open_regular(parent, leaf).map_err(|error| {
        target_refusal(format!(
            "cannot no-follow open bound metadata source: {error}"
        ))
    })?;
    let observed = binding_from_open_file(&mut source, &expected.relative_path)?;
    if &observed != expected {
        return Err(target_refusal(
            "metadata source identity changed before private staging",
        ));
    }
    #[cfg(test)]
    run_copy_source_after_bind_hook();
    source
        .seek(SeekFrom::Start(0))
        .map_err(|error| target_refusal(format!("cannot rewind bound metadata source: {error}")))?;
    let mut staged =
        metadata_publish_sys::create_new_regular(attempt, staged_name).map_err(|error| {
            subprocess_error(format!(
                "cannot create private metadata staging file {}: {error}",
                staged_path.display()
            ))
        })?;
    copy_exact_bounded(&mut source, &mut staged, expected.byte_length).map_err(|error| {
        subprocess_error(format!(
            "cannot copy metadata source into private staging: {error}"
        ))
    })?;
    staged.sync_all().map_err(|error| {
        subprocess_error(format!(
            "cannot sync private metadata staging file: {error}"
        ))
    })?;
    let staged_binding = binding_from_open_file(&mut staged, &expected.relative_path)?;
    if staged_binding.sha256 != expected.sha256
        || staged_binding.byte_length != expected.byte_length
    {
        return Err(target_refusal(
            "private metadata staging copy differs from the exact bound source bytes",
        ));
    }
    Ok(())
}

fn copy_verified_private_output_to_attempt(
    private: &File,
    source_name: &OsStr,
    relative_path: &str,
    attempt: &File,
    staged_name: &OsStr,
) -> Result<WrittenFileBinding, EngineError> {
    let mut source = metadata_publish_sys::open_regular(private, source_name).map_err(|error| {
        target_refusal(format!(
            "cannot anchor ExifTool output in the private workspace: {error}"
        ))
    })?;
    let source_binding = binding_from_open_file(&mut source, relative_path)?;
    source.seek(SeekFrom::Start(0)).map_err(|error| {
        target_refusal(format!("cannot rewind verified ExifTool output: {error}"))
    })?;
    let mut staged =
        metadata_publish_sys::create_new_regular(attempt, staged_name).map_err(|error| {
            subprocess_error(format!(
                "cannot create durable metadata transaction copy: {error}"
            ))
        })?;
    let copy_result = (|| {
        let copied = std::io::copy(&mut source, &mut staged).map_err(|error| {
            subprocess_error(format!(
                "cannot copy verified ExifTool output into the durable transaction: {error}"
            ))
        })?;
        if copied != source_binding.byte_length {
            return Err(target_refusal(
                "verified ExifTool output length changed while copying into the transaction",
            ));
        }
        staged.sync_all().map_err(|error| {
            subprocess_error(format!(
                "cannot sync durable metadata transaction copy: {error}"
            ))
        })?;
        let staged_binding = binding_from_open_file(&mut staged, relative_path)?;
        if staged_binding.sha256 != source_binding.sha256
            || staged_binding.byte_length != source_binding.byte_length
        {
            return Err(target_refusal(
                "durable metadata transaction copy differs from the verified ExifTool output",
            ));
        }
        Ok(staged_binding)
    })();
    if copy_result.is_err() {
        drop(staged);
        let _ = metadata_publish_sys::unlink(attempt, staged_name);
    }
    copy_result
}

fn create_metadata_attempt(
    root: &Path,
    root_handle: &File,
) -> Result<(PathBuf, OsString, File), EngineError> {
    for _ in 0..32 {
        let name = OsString::from(format!(
            ".scanstudio-metadata-{}.attempt",
            random_metadata_token()?
        ));
        let path = root.join(&name);
        match metadata_publish_sys::create_directory(root_handle, &name) {
            Ok(handle) => {
                #[cfg(test)]
                let root_sync = if metadata_transaction_failpoint_is(50) {
                    Err(std::io::Error::other(
                        "simulated metadata attempt parent-directory sync failure",
                    ))
                } else {
                    metadata_publish_sys::sync_directory(root_handle)
                };
                #[cfg(not(test))]
                let root_sync = metadata_publish_sys::sync_directory(root_handle);
                if let Err(error) = root_sync {
                    drop(handle);
                    let cleanup = metadata_publish_sys::remove_directory(root_handle, &name)
                        .and_then(|()| metadata_publish_sys::sync_directory(root_handle));
                    return Err(match cleanup {
                        Ok(()) => subprocess_error(format!(
                            "cannot durably publish metadata transaction attempt directory: {error}"
                        )),
                        Err(cleanup_error) => subprocess_error(format!(
                            "cannot durably publish metadata transaction attempt directory ({error}); cleanup of the empty attempt also failed: {cleanup_error}"
                        )),
                    });
                }
                return Ok((path, name, handle));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(subprocess_error(format!(
                    "cannot create private metadata attempt under {}: {error}",
                    root.display()
                )))
            }
        }
    }
    Err(subprocess_error(
        "could not reserve a unique private metadata attempt directory",
    ))
}

fn write_metadata_journal(
    attempt_path: &Path,
    attempt: &File,
    journal: &MetadataTransactionJournal,
) -> Result<(), EngineError> {
    let bytes = serde_json::to_vec_pretty(journal).map_err(|error| {
        subprocess_error(format!(
            "cannot serialize metadata transaction journal: {error}"
        ))
    })?;
    if bytes.len() > EXIFTOOL_OUTPUT_LIMIT {
        return Err(subprocess_error(
            "metadata transaction journal exceeded its fixed size bound",
        ));
    }
    let path = attempt_path.join(METADATA_JOURNAL_FILE);
    let mut file =
        metadata_publish_sys::create_new_regular(attempt, OsStr::new(METADATA_JOURNAL_FILE))
            .map_err(|error| {
                subprocess_error(format!(
                    "cannot create durable metadata transaction journal {}: {error}",
                    path.display()
                ))
            })?;
    file.write_all(&bytes).map_err(|error| {
        subprocess_error(format!(
            "cannot write metadata transaction journal: {error}"
        ))
    })?;
    file.sync_all().map_err(|error| {
        subprocess_error(format!("cannot sync metadata transaction journal: {error}"))
    })?;
    metadata_publish_sys::sync_directory(attempt).map_err(|error| {
        subprocess_error(format!(
            "cannot sync metadata transaction directory: {error}"
        ))
    })
}

fn read_bounded_journal_bytes(reader: &mut impl Read) -> std::io::Result<Vec<u8>> {
    let maximum = EXIFTOOL_OUTPUT_LIMIT as u64;
    let mut bytes = Vec::new();
    reader
        .take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > maximum {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "metadata transaction journal grew beyond its fixed read bound",
        ));
    }
    Ok(bytes)
}

fn read_metadata_journal(
    attempt: &File,
) -> Result<Option<MetadataTransactionJournal>, EngineError> {
    let mut file =
        match metadata_publish_sys::open_regular(attempt, OsStr::new(METADATA_JOURNAL_FILE)) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(subprocess_error(format!(
                    "cannot open metadata transaction journal without following links: {error}"
                )))
            }
        };
    let metadata = file.metadata().map_err(|error| {
        subprocess_error(format!(
            "cannot inspect metadata transaction journal: {error}"
        ))
    })?;
    let single_link = held_file_identity(&file, &metadata)
        .map(|(_, _, links)| links == 1)
        .unwrap_or(false);
    if !metadata.is_file()
        || metadata_is_reparse_point(&metadata)
        || !single_link
        || metadata.len() > EXIFTOOL_OUTPUT_LIMIT as u64
    {
        return Err(subprocess_error(
            "metadata transaction journal is not a bounded regular file",
        ));
    }
    let identity_before = held_file_identity(&file, &metadata);
    let bytes = read_bounded_journal_bytes(&mut file).map_err(|error| {
        subprocess_error(format!("cannot read metadata transaction journal: {error}"))
    })?;
    let after = file.metadata().map_err(|error| {
        subprocess_error(format!(
            "cannot re-inspect metadata transaction journal: {error}"
        ))
    })?;
    if held_file_identity(&file, &after) != identity_before
        || after.len() != metadata.len()
        || bytes.len() as u64 != metadata.len()
    {
        return Err(subprocess_error(
            "metadata transaction journal identity or length changed while it was being read",
        ));
    }
    let journal: MetadataTransactionJournal = serde_json::from_slice(&bytes).map_err(|error| {
        subprocess_error(format!(
            "cannot parse metadata transaction journal: {error}"
        ))
    })?;
    if journal.version != METADATA_JOURNAL_VERSION
        || journal.transaction_id.is_empty()
        || journal.targets.len() > 4
    {
        return Err(subprocess_error(
            "metadata transaction journal has an unsupported or invalid shape",
        ));
    }
    Ok(Some(journal))
}

fn observed_binding(
    parent: &File,
    name: &OsStr,
    relative_path: &str,
) -> Result<Option<WrittenFileBinding>, EngineError> {
    let mut file = match metadata_publish_sys::open_regular(parent, name) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(target_refusal(format!(
                "cannot no-follow open metadata transaction file {name:?}: {error}"
            )))
        }
    };
    binding_from_open_file(&mut file, relative_path).map(Some)
}

fn remove_exact_file(
    parent: &File,
    name: &OsStr,
    expected: &WrittenFileBinding,
) -> Result<(), EngineError> {
    let observed = observed_binding(parent, name, &expected.relative_path)?;
    if observed.as_ref() != Some(expected) {
        return Err(target_refusal(format!(
            "refusing to remove metadata transaction file {name:?} with an unexpected identity"
        )));
    }
    metadata_publish_sys::unlink(parent, name).map_err(|error| {
        subprocess_error(format!(
            "cannot remove verified metadata transaction file {name:?}: {error}"
        ))
    })
}

fn windows_swap_name(staged_name: &OsStr) -> OsString {
    let mut name = OsString::from(".swap-");
    name.push(staged_name);
    name
}

fn converge_metadata_target(
    root: &File,
    attempt: &File,
    target: &MetadataJournalTarget,
    want_new: bool,
) -> Result<(), EngineError> {
    let relative = validate_relative_path(&target.relative_path)?;
    let parent = open_anchored_parent(root, &relative)?;
    let leaf = relative
        .file_name()
        .ok_or_else(|| target_refusal("journaled metadata target has no leaf"))?;
    let desired = if want_new {
        Some(&target.new_binding)
    } else {
        target.old_binding.as_ref()
    };
    let alternate = if want_new {
        target.old_binding.as_ref()
    } else {
        Some(&target.new_binding)
    };
    let current = observed_binding(&parent, leaf, &target.relative_path)?;

    if desired.is_none() {
        match current {
            None => return Ok(()),
            Some(ref observed) if Some(observed) == alternate => {
                remove_exact_file(&parent, leaf, observed)?;
                metadata_publish_sys::sync_directory(&parent).map_err(|error| {
                    subprocess_error(format!(
                        "cannot sync metadata target directory after rollback: {error}"
                    ))
                })?;
                return Ok(());
            }
            Some(_) => {
                return Err(target_refusal(
                    "metadata target has an unknown identity during rollback",
                ))
            }
        }
    }
    let desired = desired.expect("checked Some above");
    if current.as_ref() == Some(desired) {
        return Ok(());
    }
    if current.is_some() && current.as_ref() != alternate {
        return Err(target_refusal(
            "metadata target has an unknown identity during transaction recovery",
        ));
    }

    let staged_name = OsString::from(&target.staged_name);
    let candidates = [staged_name.clone(), windows_swap_name(&staged_name)];
    let mut source_name = None;
    for candidate in &candidates {
        match observed_binding(attempt, candidate, &target.relative_path)? {
            Some(binding) if binding == *desired => {
                source_name = Some(candidate.clone());
                break;
            }
            Some(binding) if Some(&binding) == alternate || binding == target.new_binding => {}
            Some(_) => {
                return Err(target_refusal(
                    "metadata staging file has an unknown identity during recovery",
                ))
            }
            None => {}
        }
    }
    let source_name = source_name.ok_or_else(|| {
        target_refusal("the journaled metadata inode needed for recovery is unavailable")
    })?;
    if current.is_some() {
        metadata_publish_sys::rename_exchange(attempt, &source_name, &parent, leaf).map_err(
            |error| {
                subprocess_error(format!(
                    "cannot exchange journaled metadata inode during recovery: {error}"
                ))
            },
        )?;
    } else {
        metadata_publish_sys::rename_exclusive(attempt, &source_name, &parent, leaf).map_err(
            |error| {
                subprocess_error(format!(
                    "cannot restore journaled metadata inode during recovery: {error}"
                ))
            },
        )?;
    }
    metadata_publish_sys::sync_directory(&parent).map_err(|error| {
        subprocess_error(format!(
            "cannot sync recovered metadata target directory: {error}"
        ))
    })?;
    metadata_publish_sys::sync_directory(attempt).map_err(|error| {
        subprocess_error(format!(
            "cannot sync recovered metadata staging directory: {error}"
        ))
    })?;
    let observed = observed_binding(&parent, leaf, &target.relative_path)?;
    if observed.as_ref() != Some(desired) {
        return Err(target_refusal(
            "metadata recovery operation did not publish the journaled inode",
        ));
    }
    Ok(())
}

fn converge_metadata_targets(
    root: &File,
    attempt: &File,
    targets: &[MetadataJournalTarget],
    want_new: bool,
) -> Result<(), EngineError> {
    for target in targets.iter().rev() {
        converge_metadata_target(root, attempt, target, want_new)?;
    }
    Ok(())
}

fn rollback_metadata_failure(
    root: &File,
    attempt: &File,
    targets: &[MetadataJournalTarget],
    journaled: bool,
    original: EngineError,
) -> EngineError {
    #[cfg(test)]
    let rollback = if current_metadata_transaction_failpoint() == 350 {
        Err(subprocess_error(
            "simulated checked metadata rollback failure",
        ))
    } else {
        converge_metadata_targets(root, attempt, targets, false)
    };
    #[cfg(not(test))]
    let rollback = converge_metadata_targets(root, attempt, targets, false);
    match rollback {
        Ok(()) => {
            let cleanup = if journaled {
                cleanup_metadata_transaction_artifacts(attempt, targets)
            } else {
                cleanup_metadata_staged_files(attempt, targets)
            };
            match cleanup {
                Ok(()) => original,
                Err(cleanup_error) => EngineError::new(
                    ErrorCode::Internal,
                    format!(
                        "{original}; metadata files were rolled back, but cleanup failed and recovery artifacts were retained: {cleanup_error}"
                    ),
                )
                .with_recoverable(true),
            }
        }
        Err(rollback_error) => EngineError::new(
            ErrorCode::Internal,
            format!(
                "{original}; checked metadata rollback could not complete, so the durable recovery journal and displaced inodes were retained: {rollback_error}"
            ),
        )
        .with_recoverable(true),
    }
}

fn remove_metadata_journal(attempt: &File) -> Result<(), EngineError> {
    metadata_publish_sys::unlink(attempt, OsStr::new(METADATA_JOURNAL_FILE)).map_err(|error| {
        subprocess_error(format!("cannot remove completed metadata journal: {error}"))
    })?;
    metadata_publish_sys::sync_directory(attempt).map_err(|error| {
        subprocess_error(format!(
            "cannot sync completed metadata transaction directory: {error}"
        ))
    })
}

fn cleanup_metadata_staged_files(
    attempt: &File,
    targets: &[MetadataJournalTarget],
) -> Result<(), EngineError> {
    for target in targets {
        let staged_name = OsString::from(&target.staged_name);
        for candidate in [staged_name.clone(), windows_swap_name(&staged_name)] {
            let observed = observed_binding(attempt, &candidate, &target.relative_path)?;
            let Some(observed) = observed else { continue };
            let known =
                observed == target.new_binding || target.old_binding.as_ref() == Some(&observed);
            if !known {
                return Err(target_refusal(
                    "refusing to clean a metadata staging file with an unknown identity",
                ));
            }
            remove_exact_file(attempt, &candidate, &observed)?;
        }
    }
    metadata_publish_sys::sync_directory(attempt).map_err(|error| {
        subprocess_error(format!(
            "cannot sync cleaned metadata staging directory: {error}"
        ))
    })
}

fn cleanup_metadata_transaction_artifacts(
    attempt: &File,
    targets: &[MetadataJournalTarget],
) -> Result<(), EngineError> {
    cleanup_metadata_staged_files(attempt, targets)?;
    // The journal is the recovery authority and is deliberately removed
    // last, only after every displaced/unused inode has been accounted for.
    remove_metadata_journal(attempt)
}

fn cleanup_prepublication_transaction_artifacts(
    attempt: &File,
    targets: &[MetadataJournalTarget],
) -> Result<(), EngineError> {
    cleanup_metadata_staged_files(attempt, targets)?;
    match metadata_publish_sys::unlink(attempt, OsStr::new(METADATA_JOURNAL_FILE)) {
        Ok(()) => metadata_publish_sys::sync_directory(attempt).map_err(|error| {
            subprocess_error(format!(
                "cannot sync failed pre-publication metadata transaction cleanup: {error}"
            ))
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(subprocess_error(format!(
            "cannot remove failed pre-publication metadata journal: {error}"
        ))),
    }
}

fn journal_invalid(message: impl Into<String>) -> EngineError {
    EngineError::new(ErrorCode::ManifestInvalid, message).with_recoverable(true)
}

fn validate_journal_binding(binding: &WrittenFileBinding) -> Result<(), EngineError> {
    validate_relative_path(&binding.relative_path).map_err(|error| {
        journal_invalid(format!(
            "metadata transaction journal contains an unsafe binding path: {error}"
        ))
    })?;
    if binding.sha256.len() != 64
        || !binding
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || binding.byte_length > MAX_METADATA_TARGET_BYTES
        || binding.volume_id.is_none()
        || binding.file_id.is_none()
    {
        return Err(journal_invalid(
            "metadata transaction journal contains an invalid file binding",
        ));
    }
    Ok(())
}

fn journal_binding_identity(binding: &WrittenFileBinding) -> (u64, u64) {
    (
        binding.volume_id.expect("validated binding volume"),
        binding.file_id.expect("validated binding file"),
    )
}

#[cfg(windows)]
fn journal_path_key(path: &str) -> String {
    path.to_ascii_lowercase()
}

#[cfg(not(windows))]
fn journal_path_key(path: &str) -> String {
    path.to_string()
}

fn validate_journal_binding_set(bindings: &MetadataOutputBindings) -> Result<(), EngineError> {
    let mut identities = std::collections::HashSet::new();
    let mut paths = std::collections::HashSet::new();
    for binding in [
        bindings.archive.as_ref(),
        bindings.archive_xmp.as_ref(),
        bindings.positive.as_ref(),
        bindings.preview.as_ref(),
    ]
    .into_iter()
    .flatten()
    {
        validate_journal_binding(binding)?;
        if !identities.insert(journal_binding_identity(binding))
            || !paths.insert(journal_path_key(&binding.relative_path))
        {
            return Err(journal_invalid(
                "metadata transaction journal aliases output paths or physical file identities",
            ));
        }
    }
    Ok(())
}

fn validate_metadata_journal(
    attempt_name: &OsStr,
    journal: &MetadataTransactionJournal,
) -> Result<(), EngineError> {
    if attempt_name.to_str() != Some(&journal.transaction_id) {
        return Err(journal_invalid(
            "metadata transaction journal does not match its attempt directory",
        ));
    }
    let old_bindings = journal
        .expected_receipt
        .outputs
        .as_ref()
        .and_then(|outputs| outputs.metadata_bindings.as_ref())
        .ok_or_else(|| journal_invalid("journaled receipt lacks old metadata bindings"))?;
    validate_journal_binding_set(old_bindings)?;
    validate_journal_binding_set(&journal.new_bindings)?;
    if journal.new_bindings.archive != old_bindings.archive {
        return Err(journal_invalid(
            "metadata transaction journal attempts to change archive authority",
        ));
    }

    let mut expected_targets = Vec::<(
        MetadataTargetRole,
        String,
        Option<WrittenFileBinding>,
        WrittenFileBinding,
    )>::new();
    match old_bindings.archive.as_ref() {
        Some(archive) => {
            let sidecar_path = PathBuf::from(&archive.relative_path).with_extension("xmp");
            let sidecar_path = sidecar_path.to_str().ok_or_else(|| {
                journal_invalid("journaled archive sidecar path is not valid UTF-8")
            })?;
            if old_bindings
                .archive_xmp
                .as_ref()
                .is_some_and(|binding| binding.relative_path != sidecar_path)
            {
                return Err(journal_invalid(
                    "journaled archive sidecar is not the archive's exact .xmp sibling",
                ));
            }
            let new = journal.new_bindings.archive_xmp.clone().ok_or_else(|| {
                journal_invalid("journaled archive target has no new .xmp binding")
            })?;
            if new.relative_path != sidecar_path {
                return Err(journal_invalid(
                    "journaled new archive sidecar is not the archive's exact .xmp sibling",
                ));
            }
            expected_targets.push((
                MetadataTargetRole::ArchiveXmp,
                sidecar_path.to_string(),
                old_bindings.archive_xmp.clone(),
                new,
            ));
        }
        None => {
            if old_bindings.archive_xmp.is_some() || journal.new_bindings.archive_xmp.is_some() {
                return Err(journal_invalid(
                    "journaled archive sidecar exists without immutable archive authority",
                ));
            }
        }
    }
    for (role, old, new) in [
        (
            MetadataTargetRole::Positive,
            old_bindings.positive.as_ref(),
            journal.new_bindings.positive.as_ref(),
        ),
        (
            MetadataTargetRole::Preview,
            old_bindings.preview.as_ref(),
            journal.new_bindings.preview.as_ref(),
        ),
    ] {
        match (old, new) {
            (Some(old), Some(new)) if old.relative_path == new.relative_path => {
                expected_targets.push((
                    role,
                    old.relative_path.clone(),
                    Some(old.clone()),
                    new.clone(),
                ));
            }
            (None, None) => {}
            _ => {
                return Err(journal_invalid(
                    "journaled derivative bindings do not preserve exact receipt target coverage",
                ))
            }
        }
    }
    if journal.targets.len() != expected_targets.len() {
        return Err(journal_invalid(
            "metadata transaction journal does not cover every and only the derived targets",
        ));
    }
    for (index, (target, (role, relative_path, old_binding, new_binding))) in journal
        .targets
        .iter()
        .zip(expected_targets.iter())
        .enumerate()
    {
        let extension = Path::new(relative_path)
            .extension()
            .and_then(OsStr::to_str)
            .ok_or_else(|| journal_invalid("journaled target has no safe extension"))?;
        let expected_staged_name = format!("target-{index}.{extension}");
        if target.role != *role
            || target.relative_path != *relative_path
            || target.old_binding != *old_binding
            || target.new_binding != *new_binding
            || target.staged_name != expected_staged_name
            || target.new_binding.relative_path != target.relative_path
            || target.old_binding.as_ref().is_some_and(|old| {
                old.relative_path != target.relative_path
                    || journal_binding_identity(old)
                        == journal_binding_identity(&target.new_binding)
            })
        {
            return Err(journal_invalid(
                "metadata transaction journal target derivation or binding transition is invalid",
            ));
        }
    }
    Ok(())
}

fn receipt_with_metadata_bindings(
    expected: &ScanReceipt,
    bindings: &MetadataOutputBindings,
) -> Result<ScanReceipt, EngineError> {
    let mut updated = expected.clone();
    updated
        .outputs
        .as_mut()
        .ok_or_else(|| target_refusal("journaled receipt has no written outputs"))?
        .metadata_bindings = Some(bindings.clone());
    Ok(updated)
}

enum ObservedMetadataManifestAuthority {
    Old,
    New(ScanProject),
}

/// Resolves an ambiguous manifest write from the manifest inode currently
/// reachable through the held project directory. The caller still owns the
/// stable manifest transaction lock, so no legitimate writer can change the
/// latest receipt between the failed write and this classification.
fn observe_metadata_manifest_authority(
    root: &File,
    display_root: &Path,
    frame_index: u32,
    expected: &ScanReceipt,
    bindings: &MetadataOutputBindings,
) -> Result<ObservedMetadataManifestAuthority, EngineError> {
    let project = crate::manifest::read_manifest_from_directory_handle(root, display_root)?;
    let frame = project
        .frames
        .iter()
        .find(|frame| frame.index == frame_index)
        .ok_or_else(|| {
            EngineError::new(
                ErrorCode::ManifestInvalid,
                "cannot resolve an ambiguous metadata commit because its frame is missing",
            )
            .with_recoverable(true)
        })?;
    let latest = frame.receipts.last().ok_or_else(|| {
        EngineError::new(
            ErrorCode::ManifestInvalid,
            "cannot resolve an ambiguous metadata commit because its receipt is missing",
        )
        .with_recoverable(true)
    })?;
    let committed = receipt_with_metadata_bindings(expected, bindings)?;
    if latest == expected {
        Ok(ObservedMetadataManifestAuthority::Old)
    } else if latest == &committed {
        Ok(ObservedMetadataManifestAuthority::New(project))
    } else {
        Err(EngineError::new(
            ErrorCode::ManifestInvalid,
            "cannot resolve an ambiguous metadata commit because the latest receipt is neither the journaled old nor new authority",
        )
        .with_recoverable(true))
    }
}

fn remove_attempt_directory(root: &File, attempt_name: &OsStr) -> Result<(), EngineError> {
    metadata_publish_sys::remove_directory(root, attempt_name).map_err(|error| {
        subprocess_error(format!("cannot remove completed metadata attempt: {error}"))
    })?;
    metadata_publish_sys::sync_directory(root)
        .map_err(|error| subprocess_error(format!("cannot sync metadata recovery root: {error}")))
}

fn persisted_first_use_target_exists(
    root: &File,
    target: &MetadataJournalTarget,
) -> Result<bool, EngineError> {
    let relative = validate_relative_path(&target.relative_path).map_err(|error| {
        journal_invalid(format!(
            "cannot inspect journaled first-use target path: {error}"
        ))
    })?;
    let parent = open_anchored_parent(root, &relative)?;
    let leaf = relative
        .file_name()
        .ok_or_else(|| journal_invalid("journaled first-use target has no leaf"))?;
    match metadata_publish_sys::open_regular(&parent, leaf) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(journal_invalid(format!(
            "cannot safely inspect journaled first-use target: {error}"
        ))),
    }
}

pub(crate) fn recover_pending_metadata_transactions_locked(
    root: &Path,
    root_handle: &File,
) -> Result<(), EngineError> {
    // Recovery belongs to the already-held project capability. Enumerating
    // `root` by pathname here would let a post-capture rename/replacement
    // choose attacker-controlled attempt names which are then looked up in
    // the original directory. The display path is diagnostics only.
    let entries = metadata_publish_sys::read_directory_names(root_handle).map_err(|error| {
        subprocess_error(format!(
            "cannot inspect held project for metadata recovery journals: {error}"
        ))
    })?;
    let mut attempts = Vec::new();
    for name in entries {
        let Some(name_string) = name.to_str() else {
            continue;
        };
        if name_string.starts_with(METADATA_ATTEMPT_PREFIX)
            && name_string.ends_with(METADATA_ATTEMPT_SUFFIX)
        {
            attempts.push((name.clone(), root.join(name)));
        }
    }
    attempts.sort_by(|left, right| left.0.cmp(&right.0));

    for (attempt_name, attempt_path) in attempts {
        let attempt = metadata_publish_sys::open_child_directory(root_handle, &attempt_name)
            .map_err(|error| {
                target_refusal(format!(
                    "cannot anchor metadata recovery attempt {}: {error}",
                    attempt_path.display()
                ))
            })?;
        let Some(journal) = read_metadata_journal(&attempt)? else {
            // Publication is ordered strictly after the durable journal. An
            // unjournaled directory is therefore either pre-publication crash
            // debris or post-commit cleanup debris; leave it untouched rather
            // than guessing at identities without authority.
            continue;
        };
        validate_metadata_journal(&attempt_name, &journal)?;
        let project = crate::manifest::read_manifest_from_directory_handle(root_handle, root)?;
        let frame = project
            .frames
            .iter()
            .find(|frame| frame.index == journal.frame_index)
            .ok_or_else(|| target_refusal("journaled metadata frame no longer exists"))?;
        let latest = frame
            .receipts
            .last()
            .ok_or_else(|| target_refusal("journaled metadata receipt no longer exists"))?;
        let committed =
            receipt_with_metadata_bindings(&journal.expected_receipt, &journal.new_bindings)?;
        let want_new = if latest == &committed {
            true
        } else if latest == &journal.expected_receipt {
            false
        } else {
            return Err(EngineError::new(
                ErrorCode::ManifestInvalid,
                "metadata recovery cannot choose old or new authority because the latest receipt changed; recovery artifacts were preserved",
            )
            .with_recoverable(true));
        };
        let mut destructive_first_use_rollback = false;
        if !want_new {
            for target in journal
                .targets
                .iter()
                .filter(|target| target.old_binding.is_none())
            {
                if persisted_first_use_target_exists(root_handle, target)? {
                    destructive_first_use_rollback = true;
                    break;
                }
            }
        }
        if destructive_first_use_rollback {
            // A persisted project-root journal is not authenticated outside
            // the adversarial namespace. In particular, a self-authenticating
            // `oldBinding: null` must never authorize deleting a current leaf
            // during automatic restart rollback. If the leaf is absent,
            // converging to old is non-destructive and may safely retire only
            // the transaction's own staged inode. A committed-new manifest may
            // likewise converge non-destructively.
            return Err(journal_invalid(
                "automatic metadata recovery refuses destructive rollback of an unauthenticated first-use sidecar; project files and recovery artifacts were preserved",
            ));
        }
        converge_metadata_targets(root_handle, &attempt, &journal.targets, want_new)?;
        cleanup_metadata_transaction_artifacts(&attempt, &journal.targets)?;
        drop(attempt);
        remove_attempt_directory(root_handle, &attempt_name)?;
    }
    Ok(())
}

/// Production metadata apply boundary. The cross-process manifest lock,
/// durable journal, checked file publication, exact receipt update, and final
/// cleanup are one operation: displaced old inodes remain recoverable until
/// the new receipt authority is fsynced.
pub fn execute_and_persist_metadata_transaction(
    detection: &ExifToolDetection,
    metadata_arguments: &[String],
    output_root: &Path,
    frame_index: u32,
    expected_receipt: &ScanReceipt,
) -> Result<MetadataExecutionResult, EngineError> {
    let canonical_root = canonical_output_root(output_root)?;
    let lock = crate::manifest::lock_manifest_transaction(&canonical_root)?;
    recover_pending_metadata_transactions_locked(&canonical_root, &lock.directory)?;
    let outputs = expected_receipt
        .outputs
        .as_ref()
        .ok_or_else(|| target_refusal("the latest frame receipt has no written outputs"))?;
    execute_metadata_transaction_inner(
        detection,
        metadata_arguments,
        &canonical_root,
        outputs,
        Some(&lock.directory),
        Some(MetadataCommitContext {
            frame_index,
            expected_receipt,
        }),
    )
}

#[cfg(test)]
fn execute_metadata_transaction(
    detection: &ExifToolDetection,
    metadata_arguments: &[String],
    output_root: &Path,
    outputs: &WrittenOutputs,
) -> Result<MetadataExecutionResult, EngineError> {
    execute_metadata_transaction_inner(
        detection,
        metadata_arguments,
        output_root,
        outputs,
        None,
        None,
    )
}

/// Executes ExifTool only against private copies. The production caller
/// supplies `commit`; unit tests may exercise the publication seam without a
/// manifest, but no non-test API can publish without the durable commit.
fn execute_metadata_transaction_inner(
    detection: &ExifToolDetection,
    metadata_arguments: &[String],
    output_root: &Path,
    outputs: &WrittenOutputs,
    root_authority: Option<&File>,
    commit: Option<MetadataCommitContext<'_>>,
) -> Result<MetadataExecutionResult, EngineError> {
    let executable = verify_executable_binding(detection)?;
    let canonical_root = canonical_output_root(output_root)?;
    let owned_root = if root_authority.is_none() {
        Some(
            metadata_publish_sys::open_directory(&canonical_root).map_err(|error| {
                target_refusal(format!("cannot anchor metadata output root: {error}"))
            })?,
        )
    } else {
        None
    };
    let root_handle = root_authority
        .or(owned_root.as_ref())
        .expect("an owned root is created when authority is absent");
    if let Some(commit) = &commit {
        if commit.expected_receipt.outputs.as_ref() != Some(outputs) {
            return Err(target_refusal(
                "metadata commit outputs do not match the exact expected receipt",
            ));
        }
    }
    // Revalidate all role/identity/containment invariants immediately before
    // opening anchored handles and taking private copies.
    let _ = verified_output_paths(&canonical_root, outputs)?;
    let old_bindings = outputs
        .metadata_bindings
        .as_ref()
        .ok_or_else(|| target_refusal("metadata outputs have no secure file bindings"))?;
    let private_workspace = PrivateMetadataWorkspace::create()?;
    let (attempt_path, attempt_name, attempt_handle) =
        match create_metadata_attempt(&canonical_root, root_handle) {
            Ok(attempt) => attempt,
            Err(error) => {
                let _ = private_workspace.retire(&[]);
                return Err(error);
            }
        };
    let mut private_target_names = Vec::new();

    let result = (|| {
        let mut nominations: Vec<(MetadataTargetRole, PathBuf, Option<WrittenFileBinding>)> =
            Vec::new();
        if let Some(archive) = &old_bindings.archive {
            let relative = match &old_bindings.archive_xmp {
                Some(sidecar) => PathBuf::from(&sidecar.relative_path),
                None => PathBuf::from(&archive.relative_path).with_extension("xmp"),
            };
            nominations.push((
                MetadataTargetRole::ArchiveXmp,
                relative,
                old_bindings.archive_xmp.clone(),
            ));
        }
        if let Some(positive) = &old_bindings.positive {
            nominations.push((
                MetadataTargetRole::Positive,
                PathBuf::from(&positive.relative_path),
                Some(positive.clone()),
            ));
        }
        if let Some(preview) = &old_bindings.preview {
            nominations.push((
                MetadataTargetRole::Preview,
                PathBuf::from(&preview.relative_path),
                Some(preview.clone()),
            ));
        }

        let mut targets = Vec::with_capacity(nominations.len());
        for (index, (role, relative, expected)) in nominations.into_iter().enumerate() {
            let relative =
                validate_relative_path(relative.to_str().ok_or_else(|| {
                    target_refusal("metadata target relative path is not UTF-8")
                })?)?;
            let leaf = relative
                .file_name()
                .ok_or_else(|| target_refusal("metadata target has no file name"))?
                .to_os_string();
            let extension = relative
                .extension()
                .and_then(OsStr::to_str)
                .ok_or_else(|| target_refusal("metadata target has no safe extension"))?;
            let staged_name = OsString::from(format!("target-{index}.{extension}"));
            private_target_names.push(staged_name.clone());
            let execution_path = private_workspace.path.join(&staged_name);
            let parent = open_anchored_parent(root_handle, &relative)?;
            if let Some(expected) = &expected {
                copy_bound_source_to_stage(
                    &parent,
                    &leaf,
                    expected,
                    &private_workspace.directory,
                    &staged_name,
                    &execution_path,
                )?;
            } else {
                match metadata_publish_sys::open_regular(&parent, &leaf) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => {
                        return Err(target_refusal(format!(
                            "cannot verify absent first-use sidecar: {error}"
                        )))
                    }
                    Ok(_) => {
                        return Err(target_refusal(
                            "first-use metadata sidecar appeared before staging",
                        ))
                    }
                }
            }
            targets.push(StagedMetadataTarget {
                role,
                relative,
                expected,
                parent,
                leaf,
                staged_name,
                execution_path,
                published_binding: None,
            });
        }

        verify_child_directory_authority(
            root_handle,
            &attempt_name,
            &attempt_handle,
            "durable metadata transaction attempt",
        )?;
        verify_directory_path_authority(
            &canonical_root,
            root_handle,
            "metadata transaction project root",
        )?;
        private_workspace.verify_namespace()?;
        let mut execution_arguments = metadata_arguments.to_vec();
        execution_arguments.push("-overwrite_original".to_string());
        execution_arguments.extend(
            targets
                .iter()
                .map(|target| target.execution_path.display().to_string()),
        );
        let mut output = run_bounded_exiftool_command(
            executable,
            &execution_arguments,
            EXIFTOOL_APPLY_TIMEOUT,
            EXIFTOOL_OUTPUT_LIMIT,
        )?;
        private_workspace.verify_namespace()?;
        if !output.status.success() {
            return Ok(MetadataExecutionResult {
                output,
                bindings: None,
                project: None,
            });
        }

        // The durable attempt is below the project root and was never exposed
        // to ExifTool. Prove its name still reaches the held directory before
        // copying exact verified private outputs into it.
        verify_child_directory_authority(
            root_handle,
            &attempt_name,
            &attempt_handle,
            "durable metadata transaction attempt",
        )?;
        verify_directory_path_authority(
            &canonical_root,
            root_handle,
            "metadata transaction project root",
        )?;
        let copy_result = (|| {
            for target in &mut targets {
                let relative_path = target
                    .relative
                    .to_str()
                    .ok_or_else(|| target_refusal("published target path is not UTF-8"))?
                    .to_string();
                target.published_binding = Some(copy_verified_private_output_to_attempt(
                    &private_workspace.directory,
                    &target.staged_name,
                    &relative_path,
                    &attempt_handle,
                    &target.staged_name,
                )?);
            }
            metadata_publish_sys::sync_directory(&attempt_handle).map_err(|error| {
                subprocess_error(format!(
                    "cannot sync durable metadata transaction staging: {error}"
                ))
            })?;
            private_workspace.verify_namespace()
        })();
        if let Err(error) = copy_result {
            for target in &targets {
                if let Some(binding) = &target.published_binding {
                    let _ = remove_exact_file(&attempt_handle, &target.staged_name, binding);
                }
            }
            let _ = metadata_publish_sys::sync_directory(&attempt_handle);
            return Err(error);
        }

        let mut rebound = old_bindings.clone();
        for target in &targets {
            let binding = target
                .published_binding
                .clone()
                .expect("successful staging has a binding");
            match target.role {
                MetadataTargetRole::ArchiveXmp => rebound.archive_xmp = Some(binding),
                MetadataTargetRole::Positive => rebound.positive = Some(binding),
                MetadataTargetRole::Preview => rebound.preview = Some(binding),
            }
        }
        let journal_targets = targets
            .iter()
            .map(|target| MetadataJournalTarget {
                role: target.role,
                relative_path: target.relative.to_string_lossy().into_owned(),
                old_binding: target.expected.clone(),
                new_binding: target
                    .published_binding
                    .clone()
                    .expect("successful staging has a binding"),
                staged_name: target.staged_name.to_string_lossy().into_owned(),
            })
            .collect::<Vec<_>>();
        let journaled = if let Some(commit) = &commit {
            let transaction_id = attempt_name
                .to_str()
                .ok_or_else(|| target_refusal("metadata attempt name is not UTF-8"))?
                .to_string();
            let journal = MetadataTransactionJournal {
                version: METADATA_JOURNAL_VERSION,
                transaction_id,
                frame_index: commit.frame_index,
                expected_receipt: commit.expected_receipt.clone(),
                new_bindings: rebound.clone(),
                targets: journal_targets.clone(),
            };
            if let Err(error) = validate_metadata_journal(&attempt_name, &journal)
                .and_then(|()| write_metadata_journal(&attempt_path, &attempt_handle, &journal))
            {
                return match cleanup_prepublication_transaction_artifacts(
                    &attempt_handle,
                    &journal_targets,
                ) {
                    Ok(()) => Err(error),
                    Err(cleanup_error) => Err(EngineError::new(
                        ErrorCode::Internal,
                        format!(
                            "{error}; failed pre-publication transaction artifacts were retained: {cleanup_error}"
                        ),
                    )
                    .with_recoverable(true)),
                };
            }
            true
        } else {
            false
        };

        for index in 0..targets.len() {
            let target = &targets[index];
            let expected_staged = target
                .published_binding
                .as_ref()
                .expect("successful staging has a binding");
            let staged_now = observed_binding(
                &attempt_handle,
                &target.staged_name,
                &expected_staged.relative_path,
            )?;
            let target_now =
                observed_binding(&target.parent, &target.leaf, &expected_staged.relative_path)?;
            if staged_now.as_ref() != Some(expected_staged)
                || target_now.as_ref() != target.expected.as_ref()
            {
                let original = target_refusal(
                    "metadata staging or target identity changed before atomic publication",
                );
                return Err(rollback_metadata_failure(
                    root_handle,
                    &attempt_handle,
                    &journal_targets,
                    journaled,
                    original,
                ));
            }
            let publication = if target.expected.is_some() {
                metadata_publish_sys::rename_exchange(
                    &attempt_handle,
                    &target.staged_name,
                    &target.parent,
                    &target.leaf,
                )
            } else {
                metadata_publish_sys::rename_exclusive(
                    &attempt_handle,
                    &target.staged_name,
                    &target.parent,
                    &target.leaf,
                )
            };
            if let Err(error) = publication {
                let original = target_refusal(format!(
                    "metadata target changed before atomic publication: {error}"
                ));
                return Err(rollback_metadata_failure(
                    root_handle,
                    &attempt_handle,
                    &journal_targets,
                    journaled,
                    original,
                ));
            }
            let published_now =
                observed_binding(&target.parent, &target.leaf, &expected_staged.relative_path)?;
            let displaced_now = observed_binding(
                &attempt_handle,
                &target.staged_name,
                &expected_staged.relative_path,
            )?;
            if published_now.as_ref() != Some(expected_staged)
                || displaced_now.as_ref() != target.expected.as_ref()
            {
                let original = target_refusal(
                    "atomic metadata publication did not move the exact journaled inodes",
                );
                return Err(rollback_metadata_failure(
                    root_handle,
                    &attempt_handle,
                    &journal_targets,
                    journaled,
                    original,
                ));
            }
            if let Err(error) = metadata_publish_sys::sync_directory(&target.parent)
                .and_then(|()| metadata_publish_sys::sync_directory(&attempt_handle))
            {
                let original =
                    subprocess_error(format!("cannot sync metadata target directory: {error}"));
                return Err(rollback_metadata_failure(
                    root_handle,
                    &attempt_handle,
                    &journal_targets,
                    journaled,
                    original,
                ));
            }
            #[cfg(test)]
            if commit.is_some() && current_metadata_transaction_failpoint() == 100 + index {
                return Err(subprocess_error(format!(
                    "simulated crash after metadata publication {index}"
                )));
            }
        }

        let project = if let Some(commit) = &commit {
            #[cfg(test)]
            let persist_result = if matches!(current_metadata_transaction_failpoint(), 300 | 350) {
                Err(subprocess_error(
                    "simulated metadata manifest write failure",
                ))
            } else {
                crate::manifest::persist_latest_receipt_metadata_bindings_locked(
                    root_handle,
                    &canonical_root,
                    commit.frame_index,
                    commit.expected_receipt,
                    rebound.clone(),
                )
            };
            #[cfg(not(test))]
            let persist_result = crate::manifest::persist_latest_receipt_metadata_bindings_locked(
                root_handle,
                &canonical_root,
                commit.frame_index,
                commit.expected_receipt,
                rebound.clone(),
            );
            match persist_result {
                Ok(project) => Some(project),
                Err(error) => {
                    let original = EngineError::new(
                        ErrorCode::Internal,
                        format!(
                            "metadata files were published, but receipt authority could not be committed: {error}"
                        ),
                    )
                    .with_recoverable(true);
                    match observe_metadata_manifest_authority(
                        root_handle,
                        &canonical_root,
                        commit.frame_index,
                        commit.expected_receipt,
                        &rebound,
                    ) {
                        Ok(ObservedMetadataManifestAuthority::Old) => {
                            return Err(rollback_metadata_failure(
                                root_handle,
                                &attempt_handle,
                                &journal_targets,
                                journaled,
                                original,
                            ));
                        }
                        Ok(ObservedMetadataManifestAuthority::New(_project)) => {
                            if let Err(converge_error) = converge_metadata_targets(
                                root_handle,
                                &attempt_handle,
                                &journal_targets,
                                true,
                            ) {
                                return Err(EngineError::new(
                                    ErrorCode::Internal,
                                    format!(
                                        "{original}; the held manifest records the new receipt, but the files could not be converged to that authority, so the durable journal and displaced inodes were retained: {converge_error}"
                                    ),
                                )
                                .with_recoverable(true));
                            }
                            return Err(EngineError::new(
                                ErrorCode::Internal,
                                format!(
                                    "{original}; the held manifest already records the new receipt and the files were converged to it, but manifest-directory durability is uncertain, so the recovery journal and displaced old inodes were retained"
                                ),
                            )
                            .with_recoverable(true));
                        }
                        Err(observation_error) => {
                            return Err(EngineError::new(
                                ErrorCode::Internal,
                                format!(
                                    "{original}; manifest authority could not be classified after the write error, so no rollback or cleanup was attempted and the durable recovery journal was retained: {observation_error}"
                                ),
                            )
                            .with_recoverable(true));
                        }
                    }
                }
            }
        } else {
            None
        };

        #[cfg(test)]
        if current_metadata_transaction_failpoint() == 400 {
            return Err(subprocess_error(
                "simulated crash after metadata manifest commit",
            ));
        }

        #[cfg(test)]
        let transaction_cleanup = if metadata_transaction_failpoint_is(425) {
            Err(subprocess_error(
                "simulated post-commit metadata artifact cleanup failure",
            ))
        } else if journaled {
            cleanup_metadata_transaction_artifacts(&attempt_handle, &journal_targets)
        } else {
            cleanup_metadata_staged_files(&attempt_handle, &journal_targets)
        };
        #[cfg(not(test))]
        let transaction_cleanup = if journaled {
            cleanup_metadata_transaction_artifacts(&attempt_handle, &journal_targets)
        } else {
            cleanup_metadata_staged_files(&attempt_handle, &journal_targets)
        };
        if let Err(error) = transaction_cleanup {
            if project.is_some() {
                append_committed_warning(
                    &mut output,
                    &format!(
                        "metadata and receipt authority were committed, but recovery-artifact cleanup is pending: {error}"
                    ),
                );
            } else {
                return Err(error);
            }
        }
        Ok(MetadataExecutionResult {
            output,
            bindings: Some(rebound),
            project,
        })
    })();

    let private_cleanup = private_workspace.retire(&private_target_names);
    drop(attempt_handle);
    let removal = remove_attempt_directory(root_handle, &attempt_name);
    match result {
        Err(error) => Err(error),
        Ok(mut value) => {
            let mut cleanup_errors = Vec::new();
            if let Err(error) = private_cleanup {
                cleanup_errors.push(format!("private workspace cleanup: {error}"));
            }
            if let Err(error) = removal {
                cleanup_errors.push(format!("durable attempt cleanup: {error}"));
            }
            if cleanup_errors.is_empty() {
                return Ok(value);
            }
            let message = cleanup_errors.join("; ");
            if value.output.status.success() && value.project.is_some() {
                append_committed_warning(
                    &mut value.output,
                    &format!(
                        "metadata and receipt authority are committed; deferred recovery cleanup remains: {message}"
                    ),
                );
                Ok(value)
            } else {
                Err(subprocess_error(message))
            }
        }
    }
}

/// Structural guard: `Err` if `archive_path` appears literally among
/// `targets`. Called unconditionally before both the preview-building
/// method and the apply method do anything else with a target list — by
/// construction, `resolve_targets` above never includes the archive path
/// itself (only its `.xmp`-transformed sibling and derivative paths), so
/// this should never actually trip in normal operation; it exists as an
/// independently-testable invariant, not a convention trusted to hold on
/// its own.
pub fn assert_no_archive_target(
    targets: &[PathBuf],
    archive_path: &Path,
) -> Result<(), EngineError> {
    if targets.iter().any(|target| target == archive_path) {
        Err(EngineError::new(
            ErrorCode::Internal,
            "refusing to target the archive file",
        ))
    } else {
        Ok(())
    }
}

// ---------------------------------------------------------------------
// Argument-array construction
// ---------------------------------------------------------------------

/// Maps a `FilmProcess` to the exact display label this app's UI already
/// uses (`ProjectLauncherView.swift`'s `filmProcessLabel`) — kept
/// byte-for-byte identical so a written `-UserComment` never drifts from
/// what the app itself calls each process.
fn process_display_name(process: FilmProcess) -> &'static str {
    match process {
        FilmProcess::Positive => "Positive",
        FilmProcess::C41ColorNegative => "C-41 Color Negative",
        FilmProcess::BwNegative => "B&W Negative",
        FilmProcess::Kodachrome => "Kodachrome",
    }
}

/// Composes the `-UserComment` value from `film_stock`/`process`: both
/// populated -> `"{film_stock} ({process label})"`; exactly one populated
/// -> just that field's own value, undecorated; neither populated ->
/// `None` (the caller omits the argument entirely rather than writing an
/// empty comment).
fn compose_user_comment(film_stock: Option<&str>, process: Option<FilmProcess>) -> Option<String> {
    match (film_stock, process) {
        (Some(stock), Some(process)) => {
            Some(format!("{stock} ({})", process_display_name(process)))
        }
        (Some(stock), None) => Some(stock.to_string()),
        (None, Some(process)) => Some(process_display_name(process).to_string()),
        (None, None) => None,
    }
}

/// Builds the `-XMP-photoshop:DateCreated` argument per `PartialDate`'s
/// variant — the only date tag this module ever writes. The bare EXIF
/// `DateTimeOriginal`/`-DateCreated` tags reject a placeholder day/month
/// (verified against the real binary: `Day '00' out of range`, exit 1,
/// nothing written); `-XMP-photoshop:DateCreated` natively accepts
/// ISO-8601 partial precision. Never fabricates a day or month component:
/// `MonthOnly` writes `YYYY-MM` only, `YearOnly` writes `YYYY` only, and
/// `Unknown`/`None` produce no argument at all — not an empty string, not
/// a placeholder.
fn build_date_argument(date: Option<&PartialDate>) -> Option<String> {
    match date {
        Some(PartialDate::Exact { date }) => Some(format!("-XMP-photoshop:DateCreated={date}")),
        Some(PartialDate::MonthOnly { year, month }) => {
            Some(format!("-XMP-photoshop:DateCreated={year:04}-{month:02}"))
        }
        Some(PartialDate::YearOnly { year }) => {
            Some(format!("-XMP-photoshop:DateCreated={year:04}"))
        }
        Some(PartialDate::Unknown) | None => None,
    }
}

/// Pure, deterministic argument-array builder: every populated
/// `MetadataSet` field becomes exactly one `-Tag=value` argument
/// (`keywords` becomes one `-Subject+=value` per entry, the `+=` append
/// form); every `None`/empty field is simply absent from the returned
/// vector — never an empty-string argument, never a placeholder. Field
/// order is fixed (a sequence of explicit `if let Some(..)` pushes, never a
/// `HashMap`), so the same `MetadataSet` produces the byte-identical
/// `Vec<String>` on every call.
pub fn build_exiftool_arguments(metadata: &MetadataSet) -> Vec<String> {
    let mut arguments = Vec::new();

    if let Some(camera) = &metadata.camera {
        arguments.push(format!("-Model={camera}"));
    }
    if let Some(lens) = &metadata.lens {
        arguments.push(format!("-LensModel={lens}"));
    }
    if let Some(comment) = compose_user_comment(metadata.film_stock.as_deref(), metadata.process) {
        arguments.push(format!("-UserComment={comment}"));
    }
    if let Some(iso) = metadata.iso {
        arguments.push(format!("-ISO={iso}"));
    }
    if let Some(date_argument) = build_date_argument(metadata.date.as_ref()) {
        arguments.push(date_argument);
    }
    if let Some(location) = &metadata.location {
        arguments.push(format!("-Location={location}"));
    }
    if let Some(photographer) = &metadata.photographer {
        arguments.push(format!("-Artist={photographer}"));
    }
    if let Some(copyright) = &metadata.copyright {
        arguments.push(format!("-Copyright={copyright}"));
    }
    if let Some(roll_id) = &metadata.roll_id {
        arguments.push(format!("-Identifier={roll_id}"));
    }
    if let Some(frame_number) = metadata.frame_number {
        arguments.push(format!("-ImageNumber={frame_number}"));
    }
    if let Some(notes) = &metadata.notes {
        arguments.push(format!("-Description={notes}"));
    }
    for keyword in &metadata.keywords {
        arguments.push(format!("-Subject+={keyword}"));
    }

    arguments
}

/// Stable approval fingerprint for the exact argument vector shown to the
/// operator. Length-prefixing keeps argument boundaries unambiguous; target
/// paths are included because preview/apply append them to this same vector.
pub fn metadata_command_fingerprint(arguments: &[String]) -> String {
    let mut hasher = Sha256::new();
    for argument in arguments {
        hasher.update((argument.len() as u64).to_be_bytes());
        hasher.update(argument.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

/// Approval token for both the logical command and the exact ExifTool bytes
/// detected while it was shown. Apply recomputes this after a fresh probe, so
/// a PATH change, package upgrade, or same-path executable replacement forces
/// a new preview before any write-capable invocation.
pub fn metadata_approval_fingerprint(
    arguments: &[String],
    detection: &ExifToolDetection,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"scanstudio-metadata-approval-v4\0");
    hasher.update(b"config-disabled-sanitized-env-v1\0");
    for argument in arguments {
        hasher.update((argument.len() as u64).to_be_bytes());
        hasher.update(argument.as_bytes());
    }
    hasher.update([u8::from(detection.available)]);
    for value in [detection.path.as_deref(), detection.version.as_deref()] {
        match value {
            Some(value) => {
                hasher.update([1]);
                hasher.update((value.len() as u64).to_be_bytes());
                hasher.update(value.as_bytes());
            }
            None => hasher.update([0]),
        }
    }
    if let Some(binding) = &detection.executable_binding {
        hasher.update([1]);
        for value in [
            binding.canonical_path.as_str(),
            binding.file.relative_path.as_str(),
            binding.file.sha256.as_str(),
        ] {
            hasher.update((value.len() as u64).to_be_bytes());
            hasher.update(value.as_bytes());
        }
        hasher.update(binding.file.byte_length.to_be_bytes());
        hasher.update(binding.file.volume_id.unwrap_or_default().to_be_bytes());
        hasher.update(binding.file.file_id.unwrap_or_default().to_be_bytes());
        match &binding.approved.launch {
            #[cfg(unix)]
            ApprovedLaunch::Script(interpreter) => {
                hasher.update([1]);
                for value in [
                    interpreter.canonical_path.to_string_lossy().as_ref(),
                    interpreter.file.sha256.as_str(),
                ] {
                    hasher.update((value.len() as u64).to_be_bytes());
                    hasher.update(value.as_bytes());
                }
                hasher.update(interpreter.file.byte_length.to_be_bytes());
                hasher.update(interpreter.file.volume_id.unwrap_or_default().to_be_bytes());
                hasher.update(interpreter.file.file_id.unwrap_or_default().to_be_bytes());
                if let Some(argument) = &interpreter.shebang_argument {
                    let argument = argument.to_string_lossy();
                    hasher.update([1]);
                    hasher.update((argument.len() as u64).to_be_bytes());
                    hasher.update(argument.as_bytes());
                } else {
                    hasher.update([0]);
                }
            }
            #[cfg(target_os = "linux")]
            ApprovedLaunch::NativeLinux => hasher.update([2]),
            #[cfg(windows)]
            ApprovedLaunch::WindowsPath => hasher.update([3]),
        }
        #[cfg(unix)]
        if let Some(distribution) = &binding.approved.distribution {
            hasher.update([1]);
            for value in [
                distribution.source_module_root.to_string_lossy().as_ref(),
                distribution.tree_digest.as_str(),
                "private-module-root-rewrite-v1",
            ] {
                hasher.update((value.len() as u64).to_be_bytes());
                hasher.update(value.as_bytes());
            }
        } else {
            hasher.update([0]);
        }
    } else {
        hasher.update([0]);
    }
    format!("{:x}", hasher.finalize())
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{MediaCarrier, OutputRecipe, ScanReceipt, WrittenOutputs};

    fn temp_root(label: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "scanstudio-exiftool-{label}-{}",
            crate::manifest::generate_project_id()
        ));
        std::fs::create_dir_all(&root).expect("create ExifTool test root");
        root
    }

    #[test]
    fn bounded_journal_reader_rejects_growth_beyond_limit() {
        let mut exact = std::io::Cursor::new(vec![0_u8; EXIFTOOL_OUTPUT_LIMIT]);
        assert_eq!(
            read_bounded_journal_bytes(&mut exact).unwrap().len(),
            EXIFTOOL_OUTPUT_LIMIT
        );
        let mut oversized = std::io::Cursor::new(vec![0_u8; EXIFTOOL_OUTPUT_LIMIT + 1]);
        let error = read_bounded_journal_bytes(&mut oversized).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    #[cfg(unix)]
    #[test]
    fn staged_base_copy_rejects_growth_after_source_binding() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let root = temp_root("staged-copy-growth-race");
        let source_path = root.join("source.tif");
        std::fs::write(&source_path, b"stable-source").unwrap();
        let expected = bind_written_path(&root, &source_path).unwrap();
        let root_handle = metadata_publish_sys::open_directory(&root).unwrap();
        let attempt =
            metadata_publish_sys::create_directory(&root_handle, OsStr::new("attempt")).unwrap();
        let raced_path = source_path.clone();
        set_copy_source_after_bind_hook(move || {
            use std::io::Write as _;
            let mut raced = std::fs::OpenOptions::new()
                .append(true)
                .open(raced_path)
                .unwrap();
            raced.write_all(b"-attacker-growth").unwrap();
            raced.sync_all().unwrap();
        });

        let error = copy_bound_source_to_stage(
            &root_handle,
            OsStr::new("source.tif"),
            &expected,
            &attempt,
            OsStr::new("target-0.tif"),
            &root.join("attempt/target-0.tif"),
        )
        .expect_err("post-binding source growth must never reach ExifTool");
        assert!(error.message.contains("length changed"), "{error}");
        let _ = std::fs::remove_dir_all(root);
    }

    fn project_with_one_frame() -> ScanProject {
        ScanProject {
            schema_version: 4,
            id: "proj-exiftool-test".to_string(),
            name: "ExifTool Test".to_string(),
            carrier: MediaCarrier::Strip6,
            frame_count: 1,
            film_process: FilmProcess::Positive,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet::default(),
            created_at: "2026-07-24T00:00:00Z".to_string(),
            frames: vec![ProjectFrame {
                index: 1,
                excluded: false,
                capture_override: None,
                processing_override: None,
                output_override: None,
                alignment: None,
                metadata_override: None,
                receipts: vec![],
            }],
        }
    }

    fn add_bound_outputs(
        project: &mut ScanProject,
        root: &Path,
        archive: Option<&Path>,
        positive: Option<&Path>,
        preview: Option<&Path>,
    ) {
        let bindings = bind_metadata_outputs(root, archive, None, positive, preview)
            .expect("bind test outputs");
        project.frames[0].receipts.push(ScanReceipt {
            exposure_authority: None,
            auto_crop: None,
            job_id: "job-bound-output".into(),
            frame_index: 1,
            started_at: "2026-07-27T00:00:00Z".into(),
            duration_ms: 0,
            passes: 1,
            resolution_dpi: 4000,
            bit_depth: 16,
            channels: "rgb".into(),
            engine_version: "test".into(),
            device_id: "test".into(),
            simulated: true,
            settings_fingerprint: "0000000000000000".into(),
            processing: None,
            output: None,
            outputs: Some(WrittenOutputs {
                archive_path: archive.map(|path| path.display().to_string()),
                positive_path: positive.map(|path| path.display().to_string()),
                preview_path: preview.map(|path| path.display().to_string()),
                raw_negative_path: None,
                raw_negative_ir_path: None,
                metadata_bindings: Some(bindings),
                derivative_transform: crate::domain::DerivativeTransform::default(),
            }),
            rgb_path: None,
            ir_path: None,
            storage_transform: None,
            meter_rgbi_path: None,
            hardware_telemetry: None,
            nikonlook: None,
        });
    }

    // Test 1: every field populated produces the exact expected sequence.
    #[test]
    fn build_exiftool_arguments_with_every_field_populated_matches_the_verified_mapping() {
        let metadata = MetadataSet {
            camera: Some("Nikon F100".to_string()),
            lens: Some("50mm f/1.4".to_string()),
            film_stock: Some("Kodak Portra 400".to_string()),
            process: Some(FilmProcess::C41ColorNegative),
            iso: Some(400),
            date: Some(PartialDate::Exact {
                date: "2026-07-22".to_string(),
            }),
            location: Some("Home".to_string()),
            photographer: Some("Rohan".to_string()),
            copyright: Some("(c) 2026".to_string()),
            roll_id: Some("roll-1".to_string()),
            frame_number: Some(5),
            notes: Some("test notes".to_string()),
            keywords: vec!["family".to_string(), "vacation".to_string()],
        };

        let arguments = build_exiftool_arguments(&metadata);

        assert_eq!(
            arguments,
            vec![
                "-Model=Nikon F100".to_string(),
                "-LensModel=50mm f/1.4".to_string(),
                "-UserComment=Kodak Portra 400 (C-41 Color Negative)".to_string(),
                "-ISO=400".to_string(),
                "-XMP-photoshop:DateCreated=2026-07-22".to_string(),
                "-Location=Home".to_string(),
                "-Artist=Rohan".to_string(),
                "-Copyright=(c) 2026".to_string(),
                "-Identifier=roll-1".to_string(),
                "-ImageNumber=5".to_string(),
                "-Description=test notes".to_string(),
                "-Subject+=family".to_string(),
                "-Subject+=vacation".to_string(),
            ]
        );
    }

    // Test 2: month-only date has no day component anywhere.
    #[test]
    fn build_exiftool_arguments_month_only_date_has_no_day_component() {
        let metadata = MetadataSet {
            date: Some(PartialDate::MonthOnly {
                year: 2026,
                month: 7,
            }),
            ..MetadataSet::default()
        };
        let arguments = build_exiftool_arguments(&metadata);
        assert_eq!(
            arguments,
            vec!["-XMP-photoshop:DateCreated=2026-07".to_string()]
        );
    }

    // Test 3: year-only date has no month or day component anywhere.
    #[test]
    fn build_exiftool_arguments_year_only_date_has_no_month_or_day_component() {
        let metadata = MetadataSet {
            date: Some(PartialDate::YearOnly { year: 2026 }),
            ..MetadataSet::default()
        };
        let arguments = build_exiftool_arguments(&metadata);
        assert_eq!(
            arguments,
            vec!["-XMP-photoshop:DateCreated=2026".to_string()]
        );
    }

    // Test 4: None and Unknown both produce zero DateCreated-prefixed
    // arguments — not just an empty string.
    #[test]
    fn build_exiftool_arguments_omits_date_created_entirely_when_date_is_none_or_unknown() {
        let no_date = MetadataSet {
            date: None,
            ..MetadataSet::default()
        };
        let unknown_date = MetadataSet {
            date: Some(PartialDate::Unknown),
            ..MetadataSet::default()
        };
        for metadata in [no_date, unknown_date] {
            let arguments = build_exiftool_arguments(&metadata);
            assert!(
                arguments.iter().all(|arg| !arg.contains("DateCreated")),
                "no argument may reference DateCreated: {arguments:?}"
            );
        }
    }

    // Test 5: every field None/empty produces an empty Vec<String>.
    #[test]
    fn build_exiftool_arguments_with_every_field_absent_is_empty() {
        let arguments = build_exiftool_arguments(&MetadataSet::default());
        assert!(
            arguments.is_empty(),
            "expected no arguments, got {arguments:?}"
        );
    }

    // Test 6: assert_no_archive_target rejects a sneaked-in archive path
    // and accepts a clean target list.
    #[test]
    fn assert_no_archive_target_rejects_the_archive_path_and_accepts_a_clean_list() {
        let archive_path = PathBuf::from("/tmp/scanstudio-test/Archive/Archive_0001.tiff");
        let sneaked_in = vec![
            PathBuf::from("/tmp/scanstudio-test/Archive/Archive_0001.xmp"),
            archive_path.clone(),
        ];
        let err = assert_no_archive_target(&sneaked_in, &archive_path).unwrap_err();
        assert_eq!(err.code, ErrorCode::Internal);

        let clean = vec![PathBuf::from(
            "/tmp/scanstudio-test/Archive/Archive_0001.xmp",
        )];
        assert!(assert_no_archive_target(&clean, &archive_path).is_ok());
    }

    // Test 7: a frame with an empty receipts vec resolves to Ok(vec![]),
    // never an error.
    #[test]
    fn resolve_targets_on_a_frame_with_no_receipts_returns_an_empty_list_not_an_error() {
        let project = project_with_one_frame();
        let targets = resolve_targets(&project, 1, Path::new("/unused"))
            .expect("a receiptless frame must not error");
        assert!(targets.is_empty());
    }

    #[test]
    fn derivative_only_receipt_targets_no_archive_xmp() {
        let root = temp_root("derivative-only");
        let positive_dir = root.join("Positive");
        let preview_dir = root.join("Preview");
        std::fs::create_dir_all(&positive_dir).unwrap();
        std::fs::create_dir_all(&preview_dir).unwrap();
        let positive = positive_dir.join("ScanStudio1.tif");
        let preview = preview_dir.join("ScanStudio1.jpg");
        std::fs::write(&positive, b"positive").unwrap();
        std::fs::write(&preview, b"preview").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, None, Some(&positive), Some(&preview));
        let targets =
            resolve_targets(&project, 1, &root).expect("derivative-only receipt resolves");
        assert_eq!(
            targets,
            vec![
                std::fs::canonicalize(positive).unwrap(),
                std::fs::canonicalize(preview).unwrap(),
            ]
        );
        assert!(targets
            .iter()
            .all(|path| path.extension().is_none_or(|ext| ext != "xmp")));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn outside_root_receipt_target_is_refused() {
        let root = temp_root("outside-root");
        let inside = root.join("positive.tif");
        std::fs::write(&inside, b"inside").unwrap();
        let outside = root.parent().expect("temp root has parent").join(format!(
            "outside-{}",
            crate::manifest::generate_project_id()
        ));
        std::fs::write(&outside, b"outside").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, None, Some(&inside), None);
        project.frames[0].receipts[0]
            .outputs
            .as_mut()
            .unwrap()
            .positive_path = Some(outside.display().to_string());

        let error = resolve_targets(&project, 1, &root).unwrap_err();
        assert_eq!(error.code, ErrorCode::InvalidParams);
        assert!(error.message.contains("does not match"));
        assert_eq!(std::fs::read(&outside).unwrap(), b"outside");
        let _ = std::fs::remove_file(outside);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_substitution_is_refused() {
        use std::os::unix::fs::symlink;

        let root = temp_root("symlink-substitution");
        let target = root.join("positive.tif");
        let outside = root.parent().unwrap().join(format!(
            "symlink-outside-{}",
            crate::manifest::generate_project_id()
        ));
        std::fs::write(&target, b"original").unwrap();
        std::fs::write(&outside, b"outside").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, None, Some(&target), None);
        std::fs::remove_file(&target).unwrap();
        symlink(&outside, &target).unwrap();

        let error = resolve_targets(&project, 1, &root).unwrap_err();
        assert!(error.message.contains("symlink"));
        assert_eq!(std::fs::read(&outside).unwrap(), b"outside");
        let _ = std::fs::remove_file(outside);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn hard_link_substitution_is_refused() {
        let root = temp_root("hardlink-substitution");
        let target = root.join("positive.tif");
        let outside = root.parent().unwrap().join(format!(
            "hardlink-outside-{}",
            crate::manifest::generate_project_id()
        ));
        std::fs::write(&target, b"original").unwrap();
        // Keep byte length/content equal to the originally bound target so
        // this regression specifically reaches the nlink identity check.
        std::fs::write(&outside, b"original").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, None, Some(&target), None);
        std::fs::remove_file(&target).unwrap();
        std::fs::hard_link(&outside, &target).unwrap();

        let error = resolve_targets(&project, 1, &root).unwrap_err();
        assert!(error.message.contains("single-link filesystem identity"));
        assert_eq!(std::fs::read(&outside).unwrap(), b"original");
        let _ = std::fs::remove_dir_all(root);
        let _ = std::fs::remove_file(outside);
    }

    #[test]
    fn same_bytes_on_a_replaced_inode_are_refused() {
        let root = temp_root("inode-substitution");
        let target = root.join("positive.tif");
        let old = root.join("old-positive.tif");
        std::fs::write(&target, b"identical bytes").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, None, Some(&target), None);
        std::fs::rename(&target, &old).unwrap();
        std::fs::write(&target, b"identical bytes").unwrap();

        let error = resolve_targets(&project, 1, &root).unwrap_err();
        assert!(error.message.contains("replaced or modified"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn an_existing_unbound_archive_sidecar_is_refused() {
        let root = temp_root("unbound-sidecar");
        let archive = root.join("archive.tiff");
        let sidecar = root.join("archive.xmp");
        std::fs::write(&archive, b"archive").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, Some(&archive), None, None);
        let canonical_sidecar = std::fs::canonicalize(&root).unwrap().join("archive.xmp");
        assert_eq!(
            resolve_targets(&project, 1, &root).unwrap(),
            vec![canonical_sidecar]
        );
        std::fs::write(&sidecar, b"foreign sidecar").unwrap();

        let error = resolve_targets(&project, 1, &root).unwrap_err();
        assert!(error.message.contains("existing metadata sidecar"));
        assert_eq!(std::fs::read(&archive).unwrap(), b"archive");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn derivative_role_cannot_alias_the_retained_archive() {
        let root = temp_root("archive-alias");
        let archive = root.join("archive.tiff");
        std::fs::write(&archive, b"archive").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, Some(&archive), Some(&archive), None);

        let error = resolve_targets(&project, 1, &root).unwrap_err();
        assert!(error.message.contains("alias the same physical file"));
        assert_eq!(std::fs::read(&archive).unwrap(), b"archive");
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    fn executable_fixture(root: &Path, name: &str, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt as _;

        let path = root.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        let mut permissions = std::fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&path, permissions).unwrap();
        path
    }

    #[cfg(windows)]
    #[test]
    fn windows_runner_can_configure_its_kill_on_close_job() {
        let _job = windows_job::Job::new().expect("create configured Windows Job Object");
    }

    #[cfg(windows)]
    #[test]
    fn windows_metadata_identity_rejects_refs_and_accepts_ntfs() {
        assert!(windows_metadata_filesystem_name_is_supported(
            &"NTFS\0".encode_utf16().collect::<Vec<_>>()
        ));
        assert!(!windows_metadata_filesystem_name_is_supported(
            &"ReFS\0".encode_utf16().collect::<Vec<_>>()
        ));
    }

    #[cfg(windows)]
    #[test]
    fn windows_private_workspace_rejects_an_inherited_temp_dacl() {
        let root = temp_root("windows-private-dacl");
        let parent = metadata_publish_sys::open_directory(&root).unwrap();
        let inherited =
            metadata_publish_sys::create_directory(&parent, OsStr::new("inherited-workspace"))
                .unwrap();
        assert!(
            verify_private_directory_permissions(&inherited).is_err(),
            "a null security descriptor inherited from the ambient temp root is not private authority"
        );
        let private = metadata_publish_sys::create_private_directory(
            &parent,
            OsStr::new("private-workspace"),
        )
        .unwrap();
        verify_private_directory_permissions(&private)
            .expect("explicit protected owner-only DACL is accepted");
        drop((inherited, private, parent));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(windows)]
    #[test]
    fn windows_runner_assigns_and_resumes_a_normal_process() {
        let command =
            std::env::var("ComSpec").unwrap_or_else(|_| r"C:\Windows\System32\cmd.exe".to_string());
        let command = bind_executable(Path::new(&command)).expect("bind Windows command");
        let output = run_bounded_command(
            &command,
            &["/D".into(), "/C".into(), "exit /B 0".into()],
            Duration::from_secs(5),
            4096,
        )
        .expect("run a Job-contained Windows process");
        assert!(output.status.success());
    }

    #[cfg(windows)]
    #[test]
    fn windows_metadata_publication_exchanges_held_files_and_keeps_create_only_semantics() {
        let root = temp_root("windows-held-publication");
        let root_handle = metadata_publish_sys::open_directory(&root).unwrap();
        let attempt_name = OsStr::new("attempt");
        let target_name = OsStr::new("target");
        let attempt = metadata_publish_sys::create_directory(&root_handle, attempt_name).unwrap();
        let target = metadata_publish_sys::create_directory(&root_handle, target_name).unwrap();
        let leaf = OsStr::new("frame.xmp");
        let mut new_file = metadata_publish_sys::create_new_regular(&attempt, leaf).unwrap();
        new_file.write_all(b"new").unwrap();
        new_file.sync_all().unwrap();
        drop(new_file);
        let mut old_file = metadata_publish_sys::create_new_regular(&target, leaf).unwrap();
        old_file.write_all(b"old").unwrap();
        old_file.sync_all().unwrap();
        drop(old_file);

        let collision = metadata_publish_sys::create_new_regular(&target, leaf).unwrap_err();
        assert_eq!(collision.kind(), std::io::ErrorKind::AlreadyExists);
        metadata_publish_sys::rename_exchange(&attempt, leaf, &target, leaf).unwrap();
        let mut published = metadata_publish_sys::open_regular(&target, leaf).unwrap();
        let mut displaced = metadata_publish_sys::open_regular(&attempt, leaf).unwrap();
        let mut published_bytes = Vec::new();
        let mut displaced_bytes = Vec::new();
        published.read_to_end(&mut published_bytes).unwrap();
        displaced.read_to_end(&mut displaced_bytes).unwrap();
        assert_eq!(published_bytes, b"new");
        assert_eq!(displaced_bytes, b"old");

        drop((published, displaced, attempt, target, root_handle));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(windows)]
    #[test]
    fn windows_metadata_publication_rejects_a_reparse_leaf() {
        use std::os::windows::fs::symlink_file;

        let root = temp_root("windows-reparse-publication");
        let outside = root.with_extension("outside");
        std::fs::write(&outside, b"outside").unwrap();
        let alias = root.join("alias.xmp");
        if symlink_file(&outside, &alias).is_err() {
            let _ = std::fs::remove_file(outside);
            let _ = std::fs::remove_dir_all(root);
            return;
        }
        let root_handle = metadata_publish_sys::open_directory(&root).unwrap();
        assert!(metadata_publish_sys::open_regular(&root_handle, OsStr::new("alias.xmp")).is_err());
        assert_eq!(std::fs::read(&outside).unwrap(), b"outside");
        drop(root_handle);
        let _ = std::fs::remove_file(alias);
        let _ = std::fs::remove_file(outside);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn bounded_runner_terminates_a_never_exiting_process_group() {
        let root = temp_root("bounded-timeout");
        let fixture = executable_fixture(&root, "hang.sh", "while :; do sleep 1; done");
        let fixture = bind_executable(&fixture).expect("bind fixture executable");
        let started = Instant::now();
        let error =
            run_bounded_command(&fixture, &[], Duration::from_millis(150), 4096).unwrap_err();
        assert!(error.message.contains("deadline"));
        assert!(error.recoverable());
        assert!(started.elapsed() < Duration::from_secs(3));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn bounded_runner_terminates_excessive_combined_output() {
        let root = temp_root("bounded-output");
        let fixture = executable_fixture(
            &root,
            "flood.sh",
            "while :; do printf '0123456789abcdef0123456789abcdef'; done",
        );
        let fixture = bind_executable(&fixture).expect("bind fixture executable");
        let started = Instant::now();
        let error = run_bounded_command(&fixture, &[], Duration::from_secs(5), 4096).unwrap_err();
        assert!(error.message.contains("more than 4096 bytes"));
        assert!(error.recoverable());
        assert!(started.elapsed() < Duration::from_secs(3));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn bounded_runner_reaps_a_pipe_inheriting_descendant_after_leader_exit() {
        let root = temp_root("bounded-descendant");
        let fixture = executable_fixture(&root, "descendant.sh", "sleep 60 & exit 0");
        let fixture = bind_executable(&fixture).expect("bind fixture executable");
        let started = Instant::now();
        let output = run_bounded_command(&fixture, &[], Duration::from_secs(5), 4096)
            .expect("the exited leader's descendant is group-terminated");
        assert!(output.status.success());
        assert!(started.elapsed() < Duration::from_secs(3));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn bounded_runner_normal_exit_closes_without_group_cleanup_delay() {
        let root = temp_root("bounded-normal-exit");
        let fixture = executable_fixture(&root, "normal.sh", "printf 'ok'");
        let fixture = bind_executable(&fixture).expect("bind fixture executable");
        let started = Instant::now();
        let output = run_bounded_command(&fixture, &[], Duration::from_secs(5), 4096).unwrap();
        assert_eq!(output.stdout, b"ok");
        assert!(started.elapsed() < Duration::from_secs(1));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn bounded_runner_executes_held_script_after_approved_path_is_replaced() {
        let root = temp_root("held-executable-race");
        let fixture = executable_fixture(&root, "approved.sh", "printf 'approved-bytes'");
        let approved = bind_executable(&fixture).expect("bind approved script descriptor");
        let displaced = root.join("approved-original.sh");
        std::fs::rename(&fixture, &displaced).expect("move approved inode away from its path");
        let replacement = executable_fixture(&root, "approved.sh", "printf 'attacker-bytes'");
        assert_eq!(replacement, fixture);

        let output = run_bounded_command(&approved, &[], Duration::from_secs(5), 4096)
            .expect("execute exact held script after pathname replacement");
        assert!(output.status.success());
        assert_eq!(output.stdout, b"approved-bytes");
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    fn metadata_writer_fixture(root: &Path, name: &str, before_write: &str) -> ExifToolDetection {
        let fixture = executable_fixture(
            root,
            name,
            &format!(
                "[ \"$1\" = '-config' ] && [ -z \"$2\" ] || exit 92; shift 2\nif [ \"$1\" = '-ver' ]; then printf '99.0\\n'; exit 0; fi\n{before_write}\nfor value in \"$@\"; do case \"$value\" in -*) ;; *) printf '\\nmetadata-applied' >> \"$value\" ;; esac; done"
            ),
        );
        probe_candidate(fixture.to_str().expect("fixture path is UTF-8"))
            .expect("fixture must pass bounded ExifTool detection")
    }

    #[cfg(unix)]
    fn perl_distribution_fixture(
        root: &Path,
        marker: &str,
        attacker_home: &Path,
    ) -> Option<(PathBuf, PathBuf)> {
        use std::os::unix::fs::PermissionsExt as _;

        // GitHub's macOS runners can put a Homebrew Perl ahead of the system
        // interpreter. That user-owned prefix is correctly rejected by
        // `bind_secure_interpreter`, but these security regressions need a
        // root-owned interpreter to exercise the approved path. Prefer the
        // fixed system locations and use PATH only as a final candidate.
        let mut perl_candidates = vec![PathBuf::from("/usr/bin/perl"), PathBuf::from("/bin/perl")];
        if let Some(path_perl) = resolve_executable("perl") {
            perl_candidates.push(path_perl);
        }
        let perl = perl_candidates.into_iter().find_map(|candidate| {
            let canonical = std::fs::canonicalize(candidate).ok()?;
            bind_secure_interpreter(&canonical, None)
                .ok()
                .map(|_| canonical)
        })?;
        let module_root = root.join("lib");
        let image_root = module_root.join("Image");
        std::fs::create_dir_all(&image_root).ok()?;
        let module = image_root.join("ExifTool.pm");
        std::fs::write(
            &module,
            format!("package Image::ExifTool; sub scanstudio_marker {{ '{marker}' }} 1;\n"),
        )
        .ok()?;
        let launcher = root.join("exiftool");
        let module_root_text = module_root.to_str()?;
        let attacker_home_text = attacker_home.to_str()?;
        let script = format!(
            "#!{}\nuse strict; use warnings; BEGIN {{ unshift @INC, \"{}\"; }} use Image::ExifTool;\ndie q{{unsafe inherited Perl environment}} if defined($ENV{{PERL5OPT}}) || defined($ENV{{PERL5LIB}}) || defined($ENV{{PERLLIB}}) || defined($ENV{{DYLD_INSERT_LIBRARIES}}) || defined($ENV{{LD_PRELOAD}}) || defined($ENV{{PATH}});\ndie q{{attacker HOME reached launcher}} if defined($ENV{{HOME}}) && $ENV{{HOME}} eq q{{{}}};\ndie q{{ExifTool config was not disabled}} unless @ARGV >= 2 && $ARGV[0] eq q{{-config}} && $ARGV[1] eq q{{}}; splice @ARGV, 0, 2;\nif (@ARGV && $ARGV[0] eq q{{-ver}}) {{ print Image::ExifTool::scanstudio_marker(), qq{{\\n}}; exit 0; }}\nprint Image::ExifTool::scanstudio_marker(), qq{{\\n}};\n",
            perl.display(),
            module_root_text,
            attacker_home_text,
        );
        std::fs::write(&launcher, script).ok()?;
        std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o755)).ok()?;
        Some((launcher, module))
    }

    #[cfg(unix)]
    #[test]
    fn probe_then_execute_rewinds_the_same_held_script_descriptor() {
        let root = temp_root("probe-then-execute");
        let detection = metadata_writer_fixture(&root, "metadata-writer.sh", "");
        let output = execute_exiftool(&detection, &["-ver".to_string()])
            .expect("the descriptor consumed by probe must be rewound before every exec");
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "99.0");
        drop(detection);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn perl_distribution_is_snapshotted_and_ambient_code_and_config_are_removed() {
        let root = temp_root("perl-distribution-snapshot");
        let attacker_home = root.join("attacker-home");
        let attacker_lib = root.join("attacker-lib");
        std::fs::create_dir_all(&attacker_home).unwrap();
        std::fs::create_dir_all(&attacker_lib).unwrap();
        std::fs::write(
            attacker_home.join(".ExifTool_config"),
            b"die q{attacker user config executed};\n",
        )
        .unwrap();
        std::fs::write(
            attacker_lib.join("Injected.pm"),
            b"package Injected; die q{PERL5OPT executed}; 1;\n",
        )
        .unwrap();
        let Some((launcher, module)) =
            perl_distribution_fixture(&root, "approved-module", &attacker_home)
        else {
            eprintln!("root-owned Perl interpreter unavailable; skipping distribution regression");
            let _ = std::fs::remove_dir_all(root);
            return;
        };

        set_exiftool_env_injection_hook(
            std::fs::canonicalize(&launcher).unwrap(),
            vec![
                (OsString::from("PERL5OPT"), OsString::from("-MInjected")),
                (
                    OsString::from("PERL5LIB"),
                    attacker_lib.as_os_str().to_os_string(),
                ),
                (
                    OsString::from("PERLLIB"),
                    attacker_lib.as_os_str().to_os_string(),
                ),
                (
                    OsString::from("HOME"),
                    attacker_home.as_os_str().to_os_string(),
                ),
                (
                    OsString::from("DYLD_INSERT_LIBRARIES"),
                    OsString::from("/attacker/dylib"),
                ),
                (OsString::from("LD_PRELOAD"), OsString::from("/attacker/so")),
                (
                    OsString::from("PATH"),
                    attacker_lib.as_os_str().to_os_string(),
                ),
            ],
        );
        let detection = probe_candidate(launcher.to_str().unwrap())
            .expect("sanitized private distribution must probe successfully");
        assert_eq!(detection.version.as_deref(), Some("approved-module"));
        let private_path = detection
            .executable_binding
            .as_ref()
            .and_then(|binding| binding.approved.distribution.as_ref())
            .expect("Perl fixture has a private distribution")
            .path
            .clone();
        assert!(
            String::from_utf8_lossy(&std::fs::read(private_path.join("exiftool")).unwrap())
                .contains(private_path.join("lib").to_str().unwrap())
        );
        assert!(String::from_utf8_lossy(
            &std::fs::read(private_path.join("lib/Image/ExifTool.pm")).unwrap()
        )
        .contains("approved-module"));

        std::fs::write(
            &module,
            b"package Image::ExifTool; sub scanstudio_marker { 'attacker-module' } 1;\n",
        )
        .unwrap();
        let approved = execute_exiftool(&detection, &["-ver".to_string()])
            .expect("approved invocation must use its private module snapshot");
        assert!(approved.status.success());
        assert_eq!(
            String::from_utf8_lossy(&approved.stdout).trim(),
            "approved-module"
        );

        let fresh = probe_candidate(launcher.to_str().unwrap())
            .expect("fresh approval observes the changed source distribution");
        assert_eq!(fresh.version.as_deref(), Some("attacker-module"));
        assert_ne!(
            metadata_approval_fingerprint(&["-ver".to_string()], &detection),
            metadata_approval_fingerprint(&["-ver".to_string()], &fresh),
            "adjacent module bytes must participate in preview authority"
        );
        drop((detection, fresh));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn private_distribution_rejects_an_unapproved_injected_module() {
        let root = temp_root("private-distribution-injection");
        let attacker_home = root.join("attacker-home");
        std::fs::create_dir_all(&attacker_home).unwrap();
        let Some((launcher, _)) =
            perl_distribution_fixture(&root, "approved-module", &attacker_home)
        else {
            eprintln!("root-owned Perl interpreter unavailable; skipping distribution regression");
            let _ = std::fs::remove_dir_all(root);
            return;
        };
        let detection = probe_candidate(launcher.to_str().unwrap()).unwrap();
        let distribution = detection
            .executable_binding
            .as_ref()
            .and_then(|binding| binding.approved.distribution.as_ref())
            .expect("Perl fixture must have a private distribution");
        let private_path = distribution.path.clone();
        std::fs::write(private_path.join("lib/Image/Injected.pm"), b"1;\n").unwrap();
        let error = execute_exiftool(&detection, &["-ver".to_string()])
            .expect_err("an unapproved private module must fail closed");
        assert!(error.message.contains("namespace changed"), "{error}");
        drop(detection);
        let _ = std::fs::remove_dir_all(private_path);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn metadata_transaction_writes_only_private_copies_then_publishes_bound_inodes() {
        let root = temp_root("private-transaction");
        let archive_dir = root.join("Archive");
        let positive_dir = root.join("Positive");
        std::fs::create_dir_all(&archive_dir).unwrap();
        std::fs::create_dir_all(&positive_dir).unwrap();
        let archive = archive_dir.join("frame.tif");
        let sidecar = archive_dir.join("frame.xmp");
        let positive = positive_dir.join("frame.tif");
        std::fs::write(&archive, b"immutable-archive").unwrap();
        std::fs::write(&positive, b"positive-before").unwrap();
        let bindings =
            bind_metadata_outputs(&root, Some(&archive), None, Some(&positive), None).unwrap();
        let outputs = WrittenOutputs {
            archive_path: Some(archive.display().to_string()),
            positive_path: Some(positive.display().to_string()),
            preview_path: None,
            raw_negative_path: None,
            raw_negative_ir_path: None,
            metadata_bindings: Some(bindings),
            derivative_transform: crate::domain::DerivativeTransform::default(),
        };
        let detection = metadata_writer_fixture(&root, "metadata-writer.sh", "");
        let execution = execute_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            &outputs,
        )
        .expect("private transaction succeeds");
        assert!(execution.output.status.success());
        assert_eq!(std::fs::read(&archive).unwrap(), b"immutable-archive");
        assert_eq!(
            std::fs::read(&positive).unwrap(),
            b"positive-before\nmetadata-applied"
        );
        assert_eq!(std::fs::read(&sidecar).unwrap(), b"\nmetadata-applied");

        let rebound = execution
            .bindings
            .expect("successful publication binds outputs");
        let mut rebound_outputs = outputs;
        rebound_outputs.metadata_bindings = Some(rebound);
        verified_output_paths(&root, &rebound_outputs)
            .expect("returned bindings identify the files actually published");
        assert!(
            std::fs::read_dir(&root).unwrap().all(|entry| !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".scanstudio-metadata-")),
            "private attempt must be removed"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn project_attempt_path_swap_cannot_redirect_exiftool_or_touch_outside_sentinel() {
        let root = temp_root("attempt-path-swap");
        let positive_dir = root.join("Positive");
        std::fs::create_dir_all(&positive_dir).unwrap();
        let positive = positive_dir.join("frame.tif");
        std::fs::write(&positive, b"positive-before").unwrap();
        let outside = temp_root("attempt-path-swap-outside");
        let outside_target = outside.join("target-0.tif");
        std::fs::write(&outside_target, b"outside-sentinel").unwrap();
        let bindings = bind_metadata_outputs(&root, None, None, Some(&positive), None).unwrap();
        let outputs = WrittenOutputs {
            archive_path: None,
            positive_path: Some(positive.display().to_string()),
            preview_path: None,
            raw_negative_path: None,
            raw_negative_ir_path: None,
            metadata_bindings: Some(bindings),
            derivative_transform: crate::domain::DerivativeTransform::default(),
        };
        // Swap only the project-root durable attempt. The fake writer appends
        // to the paths it actually receives; those must now be in the separate
        // engine-private workspace, never below this replacement symlink.
        let before_write = format!(
            "attempt=''; for candidate in '{root}'/.scanstudio-metadata-*.attempt; do if [ -d \"$candidate\" ]; then attempt=\"$candidate\"; break; fi; done; [ -n \"$attempt\" ] || exit 91; mv \"$attempt\" \"${{attempt}}.displaced\"; ln -s '{outside}' \"$attempt\"",
            root = root.display(),
            outside = outside.display(),
        );
        let detection = metadata_writer_fixture(&root, "attempt-swap-writer.sh", &before_write);
        let error = execute_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            &outputs,
        )
        .expect_err("a swapped durable attempt namespace must fail closed before publication");

        assert!(
            error
                .message
                .contains("durable metadata transaction attempt"),
            "{error}"
        );
        assert_eq!(std::fs::read(&positive).unwrap(), b"positive-before");
        assert_eq!(std::fs::read(&outside_target).unwrap(), b"outside-sentinel");
        for entry in std::fs::read_dir(&root).unwrap().filter_map(Result::ok) {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with(METADATA_ATTEMPT_PREFIX) {
                if entry.file_type().unwrap().is_symlink() {
                    std::fs::remove_file(entry.path()).unwrap();
                } else {
                    std::fs::remove_dir_all(entry.path()).unwrap();
                }
            }
        }
        let _ = std::fs::remove_dir_all(outside);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn metadata_transaction_refuses_a_raced_first_use_sidecar_without_overwriting_it() {
        let root = temp_root("raced-sidecar");
        let archive_dir = root.join("Archive");
        std::fs::create_dir_all(&archive_dir).unwrap();
        let archive = archive_dir.join("frame.tif");
        let sidecar = archive_dir.join("frame.xmp");
        std::fs::write(&archive, b"immutable-archive").unwrap();
        let bindings = bind_metadata_outputs(&root, Some(&archive), None, None, None).unwrap();
        let outputs = WrittenOutputs {
            archive_path: Some(archive.display().to_string()),
            positive_path: None,
            preview_path: None,
            raw_negative_path: None,
            raw_negative_ir_path: None,
            metadata_bindings: Some(bindings),
            derivative_transform: crate::domain::DerivativeTransform::default(),
        };
        let before_write = format!(
            "printf 'raced-authoritative-sidecar' > '{}'",
            sidecar.display()
        );
        let detection = metadata_writer_fixture(&root, "sidecar-racer.sh", &before_write);
        let error = execute_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            &outputs,
        )
        .expect_err("create-only publication must reject a raced sidecar");
        assert!(
            error.message.contains("changed before atomic publication"),
            "{error}"
        );
        assert_eq!(
            std::fs::read(&sidecar).unwrap(),
            b"raced-authoritative-sidecar"
        );
        assert_eq!(std::fs::read(&archive).unwrap(), b"immutable-archive");
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    fn persisted_metadata_fixture(
        label: &str,
    ) -> (
        PathBuf,
        ScanProject,
        ScanReceipt,
        ExifToolDetection,
        PathBuf,
        PathBuf,
    ) {
        let root = temp_root(label);
        let positive_dir = root.join("Positive");
        let preview_dir = root.join("Preview");
        std::fs::create_dir_all(&positive_dir).unwrap();
        std::fs::create_dir_all(&preview_dir).unwrap();
        let positive = positive_dir.join("frame.tif");
        let preview = preview_dir.join("frame.jpg");
        std::fs::write(&positive, b"positive-before").unwrap();
        std::fs::write(&preview, b"preview-before").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, None, Some(&positive), Some(&preview));
        crate::manifest::write_manifest_atomically(&root, &project)
            .expect("persist transaction fixture manifest");
        let receipt = project.frames[0].receipts[0].clone();
        let detection = metadata_writer_fixture(&root, "metadata-writer.sh", "");
        (root, project, receipt, detection, positive, preview)
    }

    #[cfg(unix)]
    fn metadata_attempts(root: &Path) -> Vec<PathBuf> {
        std::fs::read_dir(root)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(METADATA_ATTEMPT_PREFIX)
            })
            .map(|entry| entry.path())
            .collect()
    }

    #[cfg(unix)]
    #[test]
    fn planted_first_use_journal_cannot_delete_or_alias_the_immutable_archive() {
        use std::os::unix::fs::MetadataExt as _;

        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let root = temp_root("planted-journal-archive-gadget");
        let archive_dir = root.join("Archive");
        std::fs::create_dir_all(&archive_dir).unwrap();
        let archive = archive_dir.join("frame.tif");
        std::fs::write(&archive, b"immutable-archive-sentinel").unwrap();
        let before_metadata = std::fs::metadata(&archive).unwrap();

        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, Some(&archive), None, None);
        crate::manifest::write_manifest_atomically(&root, &project).unwrap();
        let expected_receipt = project.frames[0].receipts[0].clone();
        let old_bindings = expected_receipt
            .outputs
            .as_ref()
            .and_then(|outputs| outputs.metadata_bindings.as_ref())
            .unwrap();
        let archive_binding = old_bindings.archive.clone().unwrap();

        let attempt_name = format!(
            "{METADATA_ATTEMPT_PREFIX}{}{}",
            random_metadata_token().unwrap(),
            METADATA_ATTEMPT_SUFFIX
        );
        let attempt = root.join(&attempt_name);
        std::fs::create_dir(&attempt).unwrap();
        let mut forged_new = old_bindings.clone();
        forged_new.archive_xmp = Some(archive_binding.clone());
        let forged = MetadataTransactionJournal {
            version: METADATA_JOURNAL_VERSION,
            transaction_id: attempt_name,
            frame_index: 1,
            expected_receipt,
            new_bindings: forged_new,
            targets: vec![MetadataJournalTarget {
                role: MetadataTargetRole::ArchiveXmp,
                relative_path: archive_binding.relative_path.clone(),
                old_binding: None,
                new_binding: archive_binding,
                staged_name: "target-0.tif".into(),
            }],
        };
        std::fs::write(
            attempt.join(METADATA_JOURNAL_FILE),
            serde_json::to_vec_pretty(&forged).unwrap(),
        )
        .unwrap();

        let error = crate::manifest::read_manifest(&root)
            .expect_err("self-authenticating planted journal must be rejected");
        assert_eq!(error.code, ErrorCode::ManifestInvalid, "{error}");
        assert_eq!(
            std::fs::read(&archive).unwrap(),
            b"immutable-archive-sentinel"
        );
        let after_metadata = std::fs::metadata(&archive).unwrap();
        assert_eq!(
            (after_metadata.dev(), after_metadata.ino()),
            (before_metadata.dev(), before_metadata.ino()),
            "archive identity must remain untouched"
        );
        assert!(attempt.join(METADATA_JOURNAL_FILE).is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn persisted_first_use_rollback_preserves_an_existing_exact_sidecar() {
        use std::os::unix::fs::MetadataExt as _;

        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let root = temp_root("persisted-first-use-existing-sidecar");
        let archive_dir = root.join("Archive");
        std::fs::create_dir_all(&archive_dir).unwrap();
        let archive = archive_dir.join("frame.tif");
        let sidecar = archive_dir.join("frame.xmp");
        std::fs::write(&archive, b"immutable-archive").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, Some(&archive), None, None);
        crate::manifest::write_manifest_atomically(&root, &project).unwrap();
        let expected_receipt = project.frames[0].receipts[0].clone();
        let old_bindings = expected_receipt
            .outputs
            .as_ref()
            .and_then(|outputs| outputs.metadata_bindings.as_ref())
            .unwrap();

        std::fs::write(&sidecar, b"outside-sidecar-sentinel").unwrap();
        let sidecar_before = std::fs::metadata(&sidecar).unwrap();
        let sidecar_binding = bind_written_path(&root, &sidecar).unwrap();
        let mut new_bindings = old_bindings.clone();
        new_bindings.archive_xmp = Some(sidecar_binding.clone());
        let attempt_name = format!(
            "{METADATA_ATTEMPT_PREFIX}{}{}",
            random_metadata_token().unwrap(),
            METADATA_ATTEMPT_SUFFIX
        );
        let attempt = root.join(&attempt_name);
        std::fs::create_dir(&attempt).unwrap();
        let journal = MetadataTransactionJournal {
            version: METADATA_JOURNAL_VERSION,
            transaction_id: attempt_name,
            frame_index: 1,
            expected_receipt,
            new_bindings,
            targets: vec![MetadataJournalTarget {
                role: MetadataTargetRole::ArchiveXmp,
                relative_path: "Archive/frame.xmp".into(),
                old_binding: None,
                new_binding: sidecar_binding,
                staged_name: "target-0.xmp".into(),
            }],
        };
        std::fs::write(
            attempt.join(METADATA_JOURNAL_FILE),
            serde_json::to_vec_pretty(&journal).unwrap(),
        )
        .unwrap();

        let error = crate::manifest::read_manifest(&root)
            .expect_err("persisted null-old journal cannot delete an existing leaf");
        assert_eq!(error.code, ErrorCode::ManifestInvalid, "{error}");
        assert_eq!(
            std::fs::read(&sidecar).unwrap(),
            b"outside-sidecar-sentinel"
        );
        let sidecar_after = std::fs::metadata(&sidecar).unwrap();
        assert_eq!(
            (sidecar_after.dev(), sidecar_after.ino()),
            (sidecar_before.dev(), sidecar_before.ino())
        );
        assert_eq!(std::fs::read(&archive).unwrap(), b"immutable-archive");
        assert!(attempt.join(METADATA_JOURNAL_FILE).is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn prepublication_first_use_crash_with_absent_sidecar_auto_cleans() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let root = temp_root("prepublication-first-use-absent-sidecar");
        let archive_dir = root.join("Archive");
        std::fs::create_dir_all(&archive_dir).unwrap();
        let archive = archive_dir.join("frame.tif");
        let sidecar = archive_dir.join("frame.xmp");
        std::fs::write(&archive, b"immutable-archive").unwrap();
        let mut project = project_with_one_frame();
        add_bound_outputs(&mut project, &root, Some(&archive), None, None);
        crate::manifest::write_manifest_atomically(&root, &project).unwrap();
        let expected_receipt = project.frames[0].receipts[0].clone();
        let old_bindings = expected_receipt
            .outputs
            .as_ref()
            .and_then(|outputs| outputs.metadata_bindings.as_ref())
            .unwrap();

        let attempt_name = format!(
            "{METADATA_ATTEMPT_PREFIX}{}{}",
            random_metadata_token().unwrap(),
            METADATA_ATTEMPT_SUFFIX
        );
        let attempt = root.join(&attempt_name);
        std::fs::create_dir(&attempt).unwrap();
        let staged_path = attempt.join("target-0.xmp");
        std::fs::write(&staged_path, b"private-staged-sidecar").unwrap();
        let mut staged = File::open(&staged_path).unwrap();
        let staged_binding = binding_from_open_file(&mut staged, "Archive/frame.xmp").unwrap();
        let mut new_bindings = old_bindings.clone();
        new_bindings.archive_xmp = Some(staged_binding.clone());
        let journal = MetadataTransactionJournal {
            version: METADATA_JOURNAL_VERSION,
            transaction_id: attempt_name,
            frame_index: 1,
            expected_receipt,
            new_bindings,
            targets: vec![MetadataJournalTarget {
                role: MetadataTargetRole::ArchiveXmp,
                relative_path: "Archive/frame.xmp".into(),
                old_binding: None,
                new_binding: staged_binding,
                staged_name: "target-0.xmp".into(),
            }],
        };
        std::fs::write(
            attempt.join(METADATA_JOURNAL_FILE),
            serde_json::to_vec_pretty(&journal).unwrap(),
        )
        .unwrap();
        drop(staged);

        let opened = crate::manifest::read_manifest(&root)
            .expect("absent first-use target makes rollback non-destructive");
        assert_eq!(opened, project);
        assert!(!sidecar.exists());
        assert_eq!(std::fs::read(&archive).unwrap(), b"immutable-archive");
        assert!(!attempt.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn committed_metadata_transaction_updates_files_and_manifest_as_one_authority() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let (root, _before, receipt, detection, positive, preview) =
            persisted_metadata_fixture("committed-transaction");
        let execution = execute_and_persist_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            1,
            &receipt,
        )
        .expect("metadata transaction commits");
        assert!(execution.output.status.success());
        assert_eq!(
            std::fs::read(&positive).unwrap(),
            b"positive-before\nmetadata-applied"
        );
        assert_eq!(
            std::fs::read(&preview).unwrap(),
            b"preview-before\nmetadata-applied"
        );
        let on_disk = crate::manifest::read_manifest(&root).unwrap();
        assert_eq!(
            on_disk.frames[0].receipts[0]
                .outputs
                .as_ref()
                .unwrap()
                .metadata_bindings,
            execution.bindings
        );
        assert!(metadata_attempts(&root).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn attempt_parent_sync_failure_precedes_journal_and_publication() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let (root, before, receipt, detection, positive, preview) =
            persisted_metadata_fixture("attempt-root-sync-order");
        set_metadata_transaction_failpoint(50);
        let error = execute_and_persist_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            1,
            &receipt,
        )
        .expect_err("an unsynced attempt parent entry must stop before journaling");
        set_metadata_transaction_failpoint(0);

        assert!(error.message.contains("attempt directory"), "{error}");
        assert_eq!(crate::manifest::read_manifest(&root).unwrap(), before);
        assert_eq!(std::fs::read(&positive).unwrap(), b"positive-before");
        assert_eq!(std::fs::read(&preview).unwrap(), b"preview-before");
        assert!(
            metadata_attempts(&root).is_empty(),
            "failed empty attempt must be removed before any journal exists"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn post_commit_cleanup_failure_returns_committed_success_and_recovers_later() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let (root, before, receipt, detection, positive, preview) =
            persisted_metadata_fixture("post-commit-cleanup-failure");
        set_metadata_transaction_failpoint(425);
        let execution = execute_and_persist_metadata_transaction(
            &detection,
            &["-Subject+=one-time-keyword".to_string()],
            &root,
            1,
            &receipt,
        )
        .expect("cleanup failure after commit must remain semantic success");
        set_metadata_transaction_failpoint(0);

        assert!(execution.output.status.success());
        assert!(
            String::from_utf8_lossy(&execution.output.stderr).contains("committed"),
            "committed cleanup debt must be surfaced as a warning"
        );
        let committed = execution.project.expect("committed project returned");
        assert_ne!(committed, before);
        assert_eq!(
            crate::manifest::read_manifest_unrecovered(&root).unwrap(),
            committed
        );
        assert_eq!(
            std::fs::read(&positive).unwrap(),
            b"positive-before\nmetadata-applied"
        );
        assert_eq!(
            std::fs::read(&preview).unwrap(),
            b"preview-before\nmetadata-applied"
        );
        assert!(!metadata_attempts(&root).is_empty());

        let recovered = crate::manifest::read_manifest(&root)
            .expect("committed recovery marker is finalized on reopen");
        assert_eq!(recovered, committed);
        assert!(metadata_attempts(&root).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn recovery_rolls_back_a_crash_after_the_first_file_publication() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let (root, before, receipt, detection, positive, preview) =
            persisted_metadata_fixture("crash-after-first-publication");
        set_metadata_transaction_failpoint(100);
        let error = execute_and_persist_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            1,
            &receipt,
        )
        .expect_err("simulated crash interrupts before manifest commit");
        set_metadata_transaction_failpoint(0);
        assert!(error.message.contains("simulated crash"));
        assert!(!metadata_attempts(&root).is_empty());

        let recovered = crate::manifest::read_manifest(&root).expect("startup recovery succeeds");
        assert_eq!(recovered, before);
        assert_eq!(std::fs::read(&positive).unwrap(), b"positive-before");
        assert_eq!(std::fs::read(&preview).unwrap(), b"preview-before");
        assert!(metadata_attempts(&root).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn manifest_failure_performs_checked_rollback_before_deleting_old_inodes() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let (root, before, receipt, detection, positive, preview) =
            persisted_metadata_fixture("manifest-failure-rollback");
        set_metadata_transaction_failpoint(300);
        let error = execute_and_persist_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            1,
            &receipt,
        )
        .expect_err("injected manifest failure rolls files back");
        set_metadata_transaction_failpoint(0);
        assert!(error.message.contains("manifest write failure"));
        assert_eq!(crate::manifest::read_manifest(&root).unwrap(), before);
        assert_eq!(std::fs::read(&positive).unwrap(), b"positive-before");
        assert_eq!(std::fs::read(&preview).unwrap(), b"preview-before");
        assert!(metadata_attempts(&root).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn post_rename_manifest_sync_failure_keeps_new_authority_and_recovery_journal() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let (root, before, receipt, detection, positive, preview) =
            persisted_metadata_fixture("manifest-post-rename-sync-failure");
        set_metadata_transaction_failpoint(375);
        let error = execute_and_persist_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            1,
            &receipt,
        )
        .expect_err("post-rename sync ambiguity must retain recovery authority");
        set_metadata_transaction_failpoint(0);

        assert!(error.message.contains("durability is uncertain"), "{error}");
        let committed = crate::manifest::read_manifest_unrecovered(&root)
            .expect("renamed manifest remains exactly readable");
        assert_ne!(committed, before);
        assert!(committed.frames[0].receipts[0]
            .outputs
            .as_ref()
            .and_then(|outputs| outputs.metadata_bindings.as_ref())
            .is_some());
        assert_eq!(
            std::fs::read(&positive).unwrap(),
            b"positive-before\nmetadata-applied"
        );
        assert_eq!(
            std::fs::read(&preview).unwrap(),
            b"preview-before\nmetadata-applied"
        );
        let attempts = metadata_attempts(&root);
        assert_eq!(attempts.len(), 1);
        assert!(attempts[0].join(METADATA_JOURNAL_FILE).is_file());
        assert!(
            std::fs::read_dir(&attempts[0]).unwrap().count() > 1,
            "displaced old inodes must remain beside the journal"
        );

        let recovered = crate::manifest::read_manifest(&root)
            .expect("held journal resolves the ambiguous commit to new authority");
        assert_eq!(recovered, committed);
        assert_eq!(
            std::fs::read(&positive).unwrap(),
            b"positive-before\nmetadata-applied"
        );
        assert_eq!(
            std::fs::read(&preview).unwrap(),
            b"preview-before\nmetadata-applied"
        );
        assert!(metadata_attempts(&root).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn uncertain_rollback_retains_journal_and_displaced_old_inodes_for_recovery() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let (root, before, receipt, detection, positive, preview) =
            persisted_metadata_fixture("uncertain-rollback-retention");
        set_metadata_transaction_failpoint(350);
        let error = execute_and_persist_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            1,
            &receipt,
        )
        .expect_err("injected rollback uncertainty must retain recovery authority");
        set_metadata_transaction_failpoint(0);

        assert!(
            error.message.contains("rollback could not complete"),
            "{error}"
        );
        assert!(
            error.message.contains("displaced inodes were retained"),
            "{error}"
        );
        assert_eq!(
            crate::manifest::read_manifest_unrecovered(&root).unwrap(),
            before
        );
        assert_eq!(
            std::fs::read(&positive).unwrap(),
            b"positive-before\nmetadata-applied"
        );
        assert_eq!(
            std::fs::read(&preview).unwrap(),
            b"preview-before\nmetadata-applied"
        );
        assert!(!metadata_attempts(&root).is_empty());

        let recovered = crate::manifest::read_manifest(&root)
            .expect("retained displaced inodes permit deterministic recovery");
        assert_eq!(recovered, before);
        assert_eq!(std::fs::read(&positive).unwrap(), b"positive-before");
        assert_eq!(std::fs::read(&preview).unwrap(), b"preview-before");
        assert!(metadata_attempts(&root).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn recovery_finalizes_files_when_manifest_commit_was_already_durable() {
        let _serial = METADATA_TRANSACTION_FAILPOINT_LOCK.lock().unwrap();
        let (root, before, receipt, detection, positive, preview) =
            persisted_metadata_fixture("crash-after-manifest-commit");
        set_metadata_transaction_failpoint(400);
        let error = execute_and_persist_metadata_transaction(
            &detection,
            &["-Artist=ScanStudio".to_string()],
            &root,
            1,
            &receipt,
        )
        .expect_err("simulated crash leaves a committed recovery journal");
        set_metadata_transaction_failpoint(0);
        assert!(error.message.contains("simulated crash"));
        assert_ne!(
            crate::manifest::read_manifest_unrecovered(&root).unwrap(),
            before
        );
        assert!(!metadata_attempts(&root).is_empty());

        let recovered = crate::manifest::read_manifest(&root).expect("committed recovery succeeds");
        assert_ne!(recovered, before);
        assert_eq!(
            std::fs::read(&positive).unwrap(),
            b"positive-before\nmetadata-applied"
        );
        assert_eq!(
            std::fs::read(&preview).unwrap(),
            b"preview-before\nmetadata-applied"
        );
        assert!(metadata_attempts(&root).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    // Test 8 (real-binary integration, gated): skips gracefully when
    // ExifTool is not installed on the machine running the test suite —
    // never hard-fails cargo test in an environment without it. Runs for
    // real (not mocked) whenever it is available.
    #[test]
    fn build_exiftool_arguments_round_trips_through_the_real_installed_binary() {
        let detection = detect_exiftool();
        if !detection.available {
            eprintln!(
                "exiftool not found on this machine (no candidate spawned -ver successfully) — skipping the real-binary integration test"
            );
            return;
        }
        let exiftool_path = detection.path.expect("available implies a resolved path");

        let temp_dir = std::env::temp_dir().join(format!(
            "scanstudio-exiftool-test-{}",
            crate::manifest::generate_project_id()
        ));
        std::fs::create_dir_all(&temp_dir).expect("create temp dir for exiftool integration test");

        // Exact date + keywords, written to a brand-new sidecar. ExifTool
        // can create a new .xmp file from nothing, so no existing file is
        // overwritten here and `-overwrite_original` is not needed.
        let exact_sidecar = temp_dir.join("exact.xmp");
        let exact_metadata = MetadataSet {
            date: Some(PartialDate::Exact {
                date: "2026-07-22".to_string(),
            }),
            keywords: vec!["family".to_string(), "vacation".to_string()],
            ..MetadataSet::default()
        };
        let write = std::process::Command::new(&exiftool_path)
            .args(build_exiftool_arguments(&exact_metadata))
            .arg(&exact_sidecar)
            .output()
            .expect("spawn exiftool to write the exact-date sidecar");
        assert!(
            write.status.success(),
            "exiftool exact-date write failed: {}",
            String::from_utf8_lossy(&write.stderr)
        );

        let read = std::process::Command::new(&exiftool_path)
            .arg("-j")
            .arg(&exact_sidecar)
            .output()
            .expect("spawn exiftool -j to read back the exact-date sidecar");
        assert!(read.status.success());
        let parsed: serde_json::Value =
            serde_json::from_slice(&read.stdout).expect("parse exiftool -j JSON output");
        // ExifTool normalizes the hyphenated input to its own
        // colon-separated convention on read-back (verified against the
        // real 13.55 binary) — the calendar date round-trips exactly, just
        // not byte-identical to the hyphenated argument that was written.
        assert_eq!(
            parsed[0]["DateCreated"],
            serde_json::json!("2026:07:22"),
            "exact date must round-trip to the same calendar date: {parsed}"
        );
        assert_eq!(
            parsed[0]["Subject"],
            serde_json::json!(["family", "vacation"]),
            "keywords must round-trip as a list: {parsed}"
        );

        // Month-only date, a second brand-new sidecar — the load-bearing
        // assertion for META-02: no day component anywhere in the
        // read-back.
        let month_only_sidecar = temp_dir.join("month-only.xmp");
        let month_only_metadata = MetadataSet {
            date: Some(PartialDate::MonthOnly {
                year: 2026,
                month: 7,
            }),
            ..MetadataSet::default()
        };
        let write = std::process::Command::new(&exiftool_path)
            .args(build_exiftool_arguments(&month_only_metadata))
            .arg(&month_only_sidecar)
            .output()
            .expect("spawn exiftool to write the month-only sidecar");
        assert!(
            write.status.success(),
            "exiftool month-only write failed: {}",
            String::from_utf8_lossy(&write.stderr)
        );

        let read = std::process::Command::new(&exiftool_path)
            .arg("-j")
            .arg(&month_only_sidecar)
            .output()
            .expect("spawn exiftool -j to read back the month-only sidecar");
        assert!(read.status.success());
        let parsed: serde_json::Value =
            serde_json::from_slice(&read.stdout).expect("parse exiftool -j JSON output");
        assert_eq!(
            parsed[0]["DateCreated"],
            serde_json::json!("2026:07"),
            "month-only date must round-trip with no day component: {parsed}"
        );

        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
