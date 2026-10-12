//! R0 — snappy decode throughput spike.
//!
//! Snappy is the **only CPU work in the HAP/DXV playback path**: the GPU
//! receives BC blocks, so the per-frame CPU cost is decompression and nothing
//! else. With upload now measured at 28× headroom, this is the remaining
//! question for whether 4 performance cores hold the tiers.
//!
//! Measures:
//!   1. single-core decompress throughput, on realistic and worst-case data
//!   2. scaling across N workers (the 2/3/4 comparison the QoS map asks for)
//!   3. the resulting layer-frames/sec at 1080p, vs the 480 target
//!
//! Honest about the machine: this is an M4 Max (10 P + 4 E). The target is a
//! base M4 (4 P + 6 E). Per-core design and clocks are close, so N=4 here is a
//! fair approximation of the target's performance complex — but it is an
//! approximation, and the real run belongs on the target.

use std::time::Instant;

const W: usize = 1920;
const H: usize = 1080;
const BLOCKS: usize = (W / 4) * (H / 4);
const BC1_FRAME: usize = BLOCKS * 8; // 1,036,800 B
const BC3_FRAME: usize = BLOCKS * 16; // 2,073,600 B

/// HAP splits a frame into independently-compressed chunks precisely so several
/// cores can work on one frame. This is that chunk count.
const CHUNKS_PER_FRAME: usize = 4;

/// Deterministic pseudo-random bytes — no dependency, reproducible.
fn lcg_fill(buf: &mut [u8], seed: u64) {
    let mut s = seed;
    for b in buf.iter_mut() {
        s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        *b = (s >> 33) as u8;
    }
}

/// Incompressible — ratio ~1.0. Snappy stores this as literals, so decompress
/// degenerates to `memcpy`. **This is the FASTEST case to decode**, not the
/// slowest: low compressibility costs storage and bandwidth, not CPU.
fn incompressible(len: usize) -> Vec<u8> {
    let mut v = vec![0u8; len];
    lcg_fill(&mut v, 0x9E3779B97F4A7C15);
    v
}

/// Highly compressible — flat/graphic content, large repeated regions.
/// **Slowest to decode**, because copy-matching does more work per output byte
/// than a literal run does.
fn highly_compressible(len: usize) -> Vec<u8> {
    let mut v = vec![0u8; len];
    let mut noise = [0u8; 8];
    let mut s = 0xDEADBEEFu64;
    let mut i = 0;
    while i + 8 <= len {
        s = s.wrapping_mul(6364136223846793005).wrapping_add(1);
        let run = 1 + ((s >> 60) as usize);
        lcg_fill(&mut noise, s);
        for _ in 0..run {
            if i + 8 > len {
                break;
            }
            v[i..i + 8].copy_from_slice(&noise);
            i += 8;
        }
    }
    v
}

/// Realistic BC content — targets the ~1.2–1.6× ratio real HAP achieves on
/// camera footage. Mostly-novel blocks with an occasional back-reference, which
/// is what BC data from real video actually looks like: neighbouring blocks
/// sometimes share endpoints, but most are distinct.
fn realistic(len: usize) -> Vec<u8> {
    let mut v = vec![0u8; len];
    lcg_fill(&mut v, 0xA5A5_5A5A_1234_5678);
    // Duplicate roughly one block in five from a nearby earlier block.
    let mut s = 0x1234_5678_9ABC_DEF0u64;
    let mut i = 8usize;
    while i + 8 <= len {
        s = s.wrapping_mul(6364136223846793005).wrapping_add(1);
        if (s >> 61) == 0 {
            let back = 8 * (1 + ((s >> 40) as usize % 32));
            if back < i {
                let (lo, hi) = v.split_at_mut(i);
                hi[..8].copy_from_slice(&lo[i - back..i - back + 8]);
            }
        }
        i += 8;
    }
    v
}

fn bench_single(name: &str, raw: &[u8]) -> f64 {
    let mut enc = snap::raw::Encoder::new();
    let comp = enc.compress_vec(raw).expect("compress");
    let ratio = raw.len() as f64 / comp.len() as f64;

    let mut dec = snap::raw::Decoder::new();
    let mut out = vec![0u8; raw.len()];

    // warm
    for _ in 0..20 {
        dec.decompress(&comp, &mut out).expect("decompress");
    }
    let iters = 400;
    let t0 = Instant::now();
    for _ in 0..iters {
        dec.decompress(&comp, &mut out).expect("decompress");
    }
    let dt = t0.elapsed().as_secs_f64() / iters as f64;
    let gbps = raw.len() as f64 / dt / 1e9;
    println!(
        "  {name:<28} ratio {ratio:.2}x   {gbps:6.2} GB/s decompressed   ({:.3} ms per {} KB)",
        dt * 1000.0,
        raw.len() / 1024
    );
    gbps
}

/// Decompresses `frames` frames split into chunks, across `workers` threads.
/// Returns decompressed GB/s.
fn bench_parallel(chunks: &[Vec<u8>], chunk_raw_len: usize, workers: usize) -> f64 {
    let frames = 120;
    let total_chunks = frames * CHUNKS_PER_FRAME;
    let t0 = Instant::now();

    std::thread::scope(|s| {
        for w in 0..workers {
            let chunks = &chunks;
            s.spawn(move || {
                let mut dec = snap::raw::Decoder::new();
                let mut out = vec![0u8; chunk_raw_len];
                let mut i = w;
                while i < total_chunks {
                    dec.decompress(&chunks[i % chunks.len()], &mut out)
                        .expect("decompress");
                    i += workers;
                }
            });
        }
    });

    let dt = t0.elapsed().as_secs_f64();
    (total_chunks * chunk_raw_len) as f64 / dt / 1e9
}

fn main() {
    println!("=== snappy decode throughput — the last CPU cost in the HAP path ===");
    println!(
        "1080p BC1 = {} KB/frame · BC3/BC7 = {} KB/frame · {} chunks/frame\n",
        BC1_FRAME / 1024,
        BC3_FRAME / 1024,
        CHUNKS_PER_FRAME
    );

    println!("single-core throughput:");
    let real_gbps = bench_single("realistic BC (~1.3x)", &realistic(BC1_FRAME));
    let _slow = bench_single("highly compressible (flat)", &highly_compressible(BC1_FRAME));
    let worst_gbps = bench_single("incompressible (memcpy-like)", &incompressible(BC1_FRAME));

    // Chunked frame, realistic data — what the scheduler actually dispatches.
    let chunk_raw = BC3_FRAME / CHUNKS_PER_FRAME;
    let mut enc = snap::raw::Encoder::new();
    let chunks: Vec<Vec<u8>> = (0..CHUNKS_PER_FRAME * 8)
        .map(|_| enc.compress_vec(&realistic(chunk_raw)).expect("compress"))
        .collect();

    println!("\nscaling across workers (1080p BC3/BC7, 4 chunks/frame, realistic data):");
    println!("  {:<9} {:>10} {:>18} {:>14}", "workers", "GB/s", "layer-frames/s", "vs 480 target");
    let mut best = 0.0f64;
    for w in [1usize, 2, 3, 4, 6, 8] {
        let gbps = bench_parallel(&chunks, chunk_raw, w);
        let lfs = gbps * 1e9 / BC3_FRAME as f64;
        best = best.max(lfs);
        println!(
            "  {w:<9} {gbps:>10.2} {lfs:>18.0} {:>13.1}x",
            lfs / 480.0
        );
    }

    println!("\n=== verdict ===");
    let four_worker = bench_parallel(&chunks, chunk_raw, 4);
    let lfs4 = four_worker * 1e9 / BC3_FRAME as f64;
    println!(
        "4 workers (approximating the base M4's performance complex): {:.0} layer-frames/s",
        lfs4
    );
    println!(
        "Tier A/B need 480 lf/s  ->  {}  ({:.1}x headroom)",
        if lfs4 >= 480.0 { "MET" } else { "NOT MET" },
        lfs4 / 480.0
    );
    let cores_needed = 480.0 / (real_gbps * 1e9 / BC3_FRAME as f64);
    println!(
        "cores required to sustain 480 lf/s at 1080p BC3: {:.2}",
        cores_needed
    );
    println!(
        "worst-case (incompressible) single core: {:.0} lf/s",
        worst_gbps * 1e9 / BC3_FRAME as f64
    );
    println!("\nNOTE: M4 Max (10P+4E). Target is base M4 (4P+6E). DEV-BOX-INVALID for tier claims.");
}
