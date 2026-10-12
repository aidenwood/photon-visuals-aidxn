//! Memory budgets — R0 #8.
//!
//! **Every budget is derived from the machine at runtime. Nothing is compiled in.**
//!
//! That rule (C8 in `V3-merged.md` §2.9) exists because a build tuned to
//! constants that suit a 32 GB base M4 leaves half of a larger machine idle,
//! and *that failure is silent* — no error, no warning, just throughput nobody
//! knows is missing. Deriving budgets costs one capability query at startup.
//!
//! Budgets are **separate pools, not one number** (Codex §9.4): read-ahead,
//! decoded blocks, native frames, persistent textures, transient targets and
//! thumbnails each have their own ceiling, so one of them cannot quietly eat
//! another's headroom.
//!
//! ## What is deliberately *not* here
//!
//! The OS file cache. Looping clips are frequently served from it, which means
//! measured disk throughput is lower than block throughput — one of the
//! corrections in `docs/scaffold.md` §5. We do not try to model it; we leave it
//! headroom and measure the real rate.

use crate::doc::Rational;

/// Facts about the machine, queried once at startup by the shell.
///
/// The shell fills this in from platform APIs; the core never queries anything
/// itself, which is what keeps it portable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceCapabilities {
    /// Total unified memory in bytes.
    pub total_memory: u64,
    /// Cores the OS will schedule latency-sensitive work on.
    pub performance_cores: u32,
    /// Efficiency cores.
    pub efficiency_cores: u32,
    /// GPU core count, where the platform reports it.
    pub gpu_cores: u32,
    /// Whether the GPU shares memory with the CPU. True on Apple Silicon.
    pub unified_memory: bool,
}

impl DeviceCapabilities {
    /// The R0 acceptance target: base M4, 32 GB.
    ///
    /// Used as a conservative fallback when the shell cannot determine real
    /// capabilities — **under**-estimating is safe, over-estimating is not.
    #[must_use]
    pub const fn base_m4_32gb() -> Self {
        Self {
            total_memory: 32 * GIB,
            performance_cores: 4,
            efficiency_cores: 6,
            gpu_cores: 10,
            unified_memory: true,
        }
    }
}

const MIB: u64 = 1024 * 1024;
const GIB: u64 = 1024 * MIB;

/// Fraction of total memory this process will not touch.
///
/// Leaves room for the OS, the window server, the file cache and other apps. A
/// media server that triggers memory pressure mid-show has failed regardless of
/// its frame rate, so this is deliberately generous.
const RESERVED_FRACTION: f64 = 0.45;

/// Smallest total we will plan against, whatever the machine reports.
const MIN_WORKING_SET: u64 = 2 * GIB;

/// Per-pool memory ceilings, in bytes.
///
/// Derived via [`Budgets::derive`]. Each pool is independent and enforced
/// separately.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Budgets {
    /// Total this process plans to use.
    pub working_set: u64,
    /// Compressed packets read ahead of playback.
    pub read_ahead: u64,
    /// Decompressed GPU-ready blocks awaiting upload.
    pub decoded_blocks: u64,
    /// Frames decoded by the platform decoder (H.264/HEVC/ProRes).
    pub native_frames: u64,
    /// Long-lived GPU textures: live sources and cached static resources.
    pub persistent_textures: u64,
    /// Render targets and intermediates.
    pub transient_targets: u64,
    /// Grid thumbnails and preview surfaces.
    pub thumbnails: u64,
}

impl Budgets {
    /// Derives budgets from the machine.
    ///
    /// Proportions are a starting point to be tuned against R1/R2 measurements,
    /// not a result. They are recorded here so the numbers in use are always
    /// visible and always logged, rather than scattered as literals.
    #[must_use]
    pub fn derive(caps: DeviceCapabilities) -> Self {
        let working_set = ((caps.total_memory as f64 * (1.0 - RESERVED_FRACTION)) as u64)
            .max(MIN_WORKING_SET);

        // Unified memory means uploads do not need a second CPU-side staging
        // copy, so block and texture pools can be smaller for the same depth.
        let (blocks_share, tex_share) = if caps.unified_memory {
            (0.22, 0.34)
        } else {
            (0.30, 0.26)
        };

        Self {
            working_set,
            read_ahead: scale(working_set, 0.14),
            decoded_blocks: scale(working_set, blocks_share),
            native_frames: scale(working_set, 0.12),
            persistent_textures: scale(working_set, tex_share),
            transient_targets: scale(working_set, 0.10),
            thumbnails: scale(working_set, 0.04),
        }
    }

    /// Sum of the individual pools.
    #[must_use]
    pub const fn allocated(self) -> u64 {
        self.read_ahead
            + self.decoded_blocks
            + self.native_frames
            + self.persistent_textures
            + self.transient_targets
            + self.thumbnails
    }

    /// Working set not assigned to any pool.
    ///
    /// Absorbs allocator overhead and transient spikes. If this reaches zero
    /// the proportions are wrong — the pools should not be able to sum past the
    /// working set.
    #[must_use]
    pub const fn headroom(self) -> u64 {
        self.working_set.saturating_sub(self.allocated())
    }

    /// How many frames of a given size the decoded-block pool holds.
    ///
    /// The number that actually matters operationally: at 1080p DXV4
    /// (~2.07 MB/frame) a 32 GB machine caches thousands of frames; at 4K
    /// (~8.29 MB) it caches a quarter as many, which is why the ring cache has
    /// to be **cue-aware** rather than simply large.
    #[must_use]
    pub const fn block_frames_held(self, bytes_per_frame: u64) -> u64 {
        if bytes_per_frame == 0 {
            return 0;
        }
        self.decoded_blocks / bytes_per_frame
    }

    /// Seconds of a single layer the block pool holds at a given rate.
    #[must_use]
    pub fn block_seconds_held(self, bytes_per_frame: u64, rate: Rational) -> f64 {
        let frames = self.block_frames_held(bytes_per_frame) as f64;
        let fps = rate.to_f64();
        if fps <= 0.0 {
            0.0
        } else {
            frames / fps
        }
    }
}

fn scale(total: u64, fraction: f64) -> u64 {
    (total as f64 * fraction) as u64
}

/// Bytes per frame for a block-compressed format.
///
/// BC1-class (DXV3 opaque, HAP) is 0.5 bytes/pixel; BC3/BC7-class (DXV4,
/// HapQ, alpha variants) is 1.0. Block formats are **fixed-rate** — a frame
/// costs the same whether it is flat black or noise, which is what makes these
/// budgets predictable in the first place.
#[must_use]
pub const fn block_frame_bytes(width: u32, height: u32, bytes_per_px_x2: u64) -> u64 {
    (width as u64 * height as u64 * bytes_per_px_x2) / 2
}

/// BC1-class: 0.5 bytes per pixel.
pub const BC1_CLASS: u64 = 1;
/// BC3/BC7-class: 1.0 byte per pixel.
pub const BC7_CLASS: u64 = 2;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pools_never_exceed_the_working_set() {
        for total in [8, 16, 32, 36, 64, 128] {
            let caps = DeviceCapabilities {
                total_memory: total * GIB,
                ..DeviceCapabilities::base_m4_32gb()
            };
            let b = Budgets::derive(caps);
            assert!(
                b.allocated() <= b.working_set,
                "{total}GB: pools {} exceed working set {}",
                b.allocated(),
                b.working_set
            );
        }
    }

    #[test]
    fn budgets_scale_with_the_machine() {
        // C8: the same build must use more of a bigger machine, with no recompile.
        let small = Budgets::derive(DeviceCapabilities::base_m4_32gb());
        let big = Budgets::derive(DeviceCapabilities {
            total_memory: 128 * GIB,
            ..DeviceCapabilities::base_m4_32gb()
        });
        assert!(big.decoded_blocks > small.decoded_blocks * 3);
    }

    #[test]
    fn tiny_machines_still_get_a_usable_floor() {
        let b = Budgets::derive(DeviceCapabilities {
            total_memory: 2 * GIB,
            ..DeviceCapabilities::base_m4_32gb()
        });
        assert_eq!(b.working_set, MIN_WORKING_SET);
        assert!(b.headroom() > 0);
    }

    #[test]
    fn frame_sizes_match_the_published_arithmetic() {
        // These are the numbers the tier analysis is built on; if they drift,
        // every budget downstream is wrong.
        assert_eq!(block_frame_bytes(1920, 1080, BC1_CLASS), 1_036_800);
        assert_eq!(block_frame_bytes(1920, 1080, BC7_CLASS), 2_073_600);
        assert_eq!(block_frame_bytes(3840, 2160, BC7_CLASS), 8_294_400);
    }

    #[test]
    fn cache_depth_collapses_at_4k_which_is_why_it_must_be_cue_aware() {
        let b = Budgets::derive(DeviceCapabilities::base_m4_32gb());
        let hd = b.block_seconds_held(block_frame_bytes(1920, 1080, BC7_CLASS), Rational::FPS_60);
        let uhd = b.block_seconds_held(block_frame_bytes(3840, 2160, BC7_CLASS), Rational::FPS_60);

        // 1080p holds a comfortable amount; 4K holds a quarter of it.
        assert!(hd > 30.0, "1080p should hold >30s, held {hd:.1}s");
        assert!(
            (hd / uhd - 4.0).abs() < 0.01,
            "4K frames are 4x larger so depth should be 1/4"
        );
    }

    #[test]
    fn unified_memory_shifts_share_toward_textures() {
        let unified = Budgets::derive(DeviceCapabilities::base_m4_32gb());
        let discrete = Budgets::derive(DeviceCapabilities {
            unified_memory: false,
            ..DeviceCapabilities::base_m4_32gb()
        });
        // No staging copy needed, so more goes to resident textures.
        assert!(unified.persistent_textures > discrete.persistent_textures);
        assert!(unified.decoded_blocks < discrete.decoded_blocks);
    }
}
