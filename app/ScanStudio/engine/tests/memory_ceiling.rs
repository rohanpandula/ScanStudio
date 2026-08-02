//! Memory ceiling test for a full 36-frame simulated roll.
//!
//! This file proves, via a process-global byte counter backed by the
//! system allocator, that a 36-frame batch scan never accumulates more than
//! a small documented multiple of one frame's own pixel-buffer size in live
//! heap at once. It lives under `tests/` (not `src/`) so Cargo compiles it
//! as its own binary; the `#[global_allocator]` declared here therefore only
//! instruments this test process, not the 241 library tests.

use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use scanstudio_engine::domain::{
    CaptureRecipe, Channels, MediaCarrier, OutputRecipe, ProcessingRecipe, ScannerBackend,
};
use scanstudio_engine::manifest::generate_project_id;
use scanstudio_engine::protocol::{ConnectOptions, FaultInjection};
use scanstudio_engine::render::frame_dimensions;
use scanstudio_engine::sim::SimulatedLs5000;

/// Running total of currently live bytes, as measured by this allocator.
static CURRENT: AtomicUsize = AtomicUsize::new(0);

/// Highest value `CURRENT` has ever reached.
static PEAK: AtomicUsize = AtomicUsize::new(0);

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

struct CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc(layout);
        if !ptr.is_null() {
            let new_current = CURRENT.fetch_add(layout.size(), Ordering::SeqCst) + layout.size();
            PEAK.fetch_max(new_current, Ordering::SeqCst);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
        CURRENT.fetch_sub(layout.size(), Ordering::SeqCst);
    }

    // `realloc` uses the default trait implementation, which calls this
    // type's own `alloc`/`dealloc` and therefore keeps the counters correct.
}

/// Serializes the two tests below against each other. `cargo test` runs
/// `#[test]` functions within one binary concurrently by default, and both
/// tests read the same global counters, so concurrent execution would
/// contaminate their peak readings.
///
/// This mutex only brackets each `#[test]` function's own body, though --
/// it says nothing about a thread that a test spawned and moved on
/// without waiting for. `sim_batch_scan_peak_memory_...` below drives its
/// scan through `SimulatedLs5000::scan_start`, which (src/sim.rs) hands
/// back a job id and finishes the work on a detached `thread::spawn` with
/// no `JoinHandle` kept anywhere, so nothing outside that module can block
/// on the worker thread's exit. The `scan.completed` event on the channel
/// means the job's results are final, not that the thread is gone: it
/// still has a trailing "scanner.status" event to serialize and send, then
/// its locals to drop, before it actually exits. All of that goes through
/// this file's global allocator, so `CURRENT` keeps moving briefly after
/// `scan.completed` arrives. If this test's guard were released the
/// moment that event was seen, the worker thread's remaining frees could
/// still land while `counting_allocator_tracks_a_known_allocation` is
/// mid-flight through its own two narrow reads -- an order-dependent
/// contamination that has nothing to do with either test's own logic.
/// `wait_for_allocator_quiescence` closes that gap by polling `CURRENT`
/// for a stretch of silence before a guard holder proceeds or returns, so
/// the counter is only ever read as a clean baseline.
static SERIALIZE: Mutex<()> = Mutex::new(());

/// Acquires `SERIALIZE`, recovering the guard even if a previous holder
/// panicked while it was held, instead of propagating that as a
/// `PoisonError` here. `SERIALIZE` protects mutual exclusion between these
/// two tests' bodies only (see its own doc comment) -- it guards no shared
/// data of its own (`Mutex<()>`, not e.g. `Mutex<Vec<...>>`), so a poisoned
/// lock here reflects a previous TEST failing its own assertions, never
/// data left in an inconsistent state by a panic mid-mutation. Propagating
/// the poison anyway is exactly how one test's panic used to cascade into
/// a second, unrelated failure for whichever test happened to run next in
/// the same process (confirmed empirically: `cargo test --release
/// --test-threads=1` before this fix failed BOTH tests, the second one
/// only on `PoisonError`, never reaching its own logic at all).
fn acquire_serialize() -> std::sync::MutexGuard<'static, ()> {
    SERIALIZE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// How often to sample `CURRENT` while waiting for it to go quiet.
const QUIESCENCE_POLL_INTERVAL: Duration = Duration::from_millis(2);

/// Consecutive unchanged samples required before the counter counts as
/// settled -- a 30ms window of silence at the poll interval above. The
/// trailing work a scan job's worker thread does after sending
/// `scan.completed` (one more event serialization, then dropping a
/// handful of Strings/Vecs/a HashMap) has been observed to finish in
/// well under a millisecond; this leaves an order of magnitude of margin
/// for scheduler jitter under load without the wait becoming noticeable
/// against the scan itself.
const QUIESCENCE_STABLE_READS: u32 = 15;

/// Hard ceiling on the wait, so a genuinely stuck background thread can
/// never hang the suite. If this fires, the helper PANICS with the
/// counter's movement history rather than silently proceeding on a dirty
/// baseline (adversarial-review finding, 2026-07-25): five seconds of a
/// still-moving allocator counter means some thread is continuously
/// allocating outside any test's own body -- every assertion this file
/// would make after that point is meaningless, and a loud failure naming
/// the movement is strictly more diagnosable than whichever downstream
/// delta assertion would otherwise fail mysteriously.
const QUIESCENCE_MAX_WAIT: Duration = Duration::from_secs(5);

/// Blocks until `CURRENT` has stopped changing. Panics if
/// `QUIESCENCE_MAX_WAIT` elapses first -- see its doc comment. See the
/// `SERIALIZE` doc comment above for why this is necessary: the mutex
/// alone only covers each test's own body, not a worker thread that
/// outlives it.
fn wait_for_allocator_quiescence() {
    let start = Instant::now();
    let initial = CURRENT.load(Ordering::SeqCst);
    let mut last = initial;
    let mut changes = 0u32;
    let mut stable_reads = 0;
    while stable_reads < QUIESCENCE_STABLE_READS {
        assert!(
            start.elapsed() <= QUIESCENCE_MAX_WAIT,
            "allocator counter never went quiet: still moving after {:?} \
             (initial {initial}, last {last}, {changes} observed changes) -- \
             some thread is allocating outside any test body, so every \
             baseline this file could take now is untrustworthy",
            start.elapsed(),
        );
        std::thread::sleep(QUIESCENCE_POLL_INTERVAL);
        let now = CURRENT.load(Ordering::SeqCst);
        if now == last {
            stable_reads += 1;
        } else {
            stable_reads = 0;
            changes += 1;
            last = now;
        }
    }
}

#[test]
fn counting_allocator_tracks_a_known_allocation() {
    let _guard = acquire_serialize();

    // Whichever test acquires SERIALIZE first, treat the shared counter as
    // untrustworthy until it has held still for a while -- see the
    // SERIALIZE doc comment for why a fresh guard is not on its own proof
    // that nothing else is still touching CURRENT.
    wait_for_allocator_quiescence();

    let baseline = CURRENT.load(Ordering::SeqCst);
    let known_size: usize = 10_000_000;
    let layout = Layout::from_size_align(known_size, 1).unwrap();
    let ptr = unsafe { std::alloc::alloc(layout) };
    assert!(!ptr.is_null(), "known-size allocation should succeed");

    // In `--release`, a raw alloc/dealloc pair with nothing observably done
    // to the memory in between is exactly the "dead allocation" pattern
    // LLVM is free to remove outright, regardless of what the registered
    // `#[global_allocator]` does on the side -- confirmed empirically: this
    // probe's 10 MB `alloc` produced zero movement in `CURRENT` under
    // `--release` before this write/read existed (`baseline == current`).
    // A volatile write followed by a `black_box`ed volatile read is a real,
    // non-elidable use of `ptr` sitting between the alloc and dealloc
    // calls, so the compiler can no longer prove the pair has no effect --
    // in both profiles, not just debug.
    unsafe { std::ptr::write_volatile(ptr, 0xABu8) };
    let observed = std::hint::black_box(unsafe { std::ptr::read_volatile(ptr) });
    assert_eq!(observed, 0xAB, "the volatile probe write must read back before the counter check below");

    let current = CURRENT.load(Ordering::SeqCst);
    assert!(
        current >= baseline.saturating_add(known_size),
        "counter should have grown by at least {known_size} bytes (baseline {baseline}, current {current})"
    );

    unsafe { std::alloc::dealloc(ptr, layout) };
    let after_drop = CURRENT.load(Ordering::SeqCst);
    assert!(
        after_drop < current,
        "counter should drop after deallocation (current {current}, after_drop {after_drop})"
    );
}

#[test]
fn sim_batch_scan_peak_memory_stays_within_a_few_frames_worth_not_the_whole_roll() {
    let _guard = acquire_serialize();

    let dir = std::env::temp_dir().join(format!(
        "scanstudio-memtest-{}-{}",
        std::process::id(),
        generate_project_id()
    ));

    let sim = Arc::new(SimulatedLs5000::new());
    let options = ConnectOptions {
        time_scale: 0.01,
        fault_injection: FaultInjection::NoFault,
    };
    let device_id = sim.device_info().device_id;
    sim.connect(&device_id, &options).expect("connect");
    sim.load_media(MediaCarrier::Roll36).expect("load media");

    let recipe = CaptureRecipe {
        resolution_dpi: 400,
        bit_depth: 16,
        multisample_passes: 1,
        channels: Channels::Rgbi,
    };

    let mut output = OutputRecipe::default();
    output.archive.destination = dir.join("Archive").display().to_string();
    output.positive.destination = dir.join("Positive").display().to_string();
    output.preview.destination = dir.join("Preview").display().to_string();

    let (tx, rx): (mpsc::Sender<String>, mpsc::Receiver<String>) = mpsc::channel();

    // Start measuring from the moment the scan job begins, so directory and
    // struct construction done above do not count toward the scan peak.
    PEAK.store(CURRENT.load(Ordering::SeqCst), Ordering::SeqCst);

    SimulatedLs5000::scan_start(
        &sim,
        (1..=36).collect(),
        recipe,
        ProcessingRecipe::default(),
        output,
        HashMap::new(),
        None,
        tx,
    )
    .expect("scan start");

    loop {
        let line = rx
            .recv_timeout(Duration::from_secs(30))
            .expect("scan.completed event");
        let value: serde_json::Value = serde_json::from_str(&line).expect("event json");
        if value["event"] == "scan.completed" {
            break;
        }
    }

    // scan_start's worker thread is still alive here (see the SERIALIZE
    // doc comment): `scan.completed` on the channel is not the same event
    // as the thread exiting. Wait it out to quiescence before this guard
    // is released, so its trailing frees land on CURRENT while this test
    // still holds SERIALIZE, not while the next one is mid-read.
    wait_for_allocator_quiescence();

    let (w, h) = frame_dimensions(MediaCarrier::Roll36, 400);
    let one_frame_bytes = (w as u64) * (h as u64) * 3 * 8;

    // The simulator pipeline can legitimately hold several same-order buffers
    // alive at once inside render_and_write_frame (raw archive, positive,
    // cropped copy, quantized u16/u8 derivative). Budget 6x for that single-
    // frame multi-buffer peak, then 4x headroom on top.
    const SINGLE_FRAME_PIPELINE_PEAK_ESTIMATE: u64 = 6;
    const HEADROOM_FACTOR: u64 = 4;
    const CEILING_MULTIPLIER: u64 = SINGLE_FRAME_PIPELINE_PEAK_ESTIMATE * HEADROOM_FACTOR;
    let ceiling_bytes = one_frame_bytes * CEILING_MULTIPLIER;

    let peak = PEAK.load(Ordering::SeqCst) as u64;
    assert!(
        peak > 0,
        "peak memory should be > 0 (the counting allocator should have measured something)"
    );
    assert!(
        peak < ceiling_bytes,
        "peak live memory {peak} bytes exceeded ceiling {ceiling_bytes} bytes (one_frame={one_frame_bytes}, multiplier={CEILING_MULTIPLIER})"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
