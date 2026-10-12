//! Platform capability **traits** — no implementations.
//!
//! This is the seam that makes the Windows shell a port rather than a rewrite.
//! Every OS-specific capability is declared here and implemented in the shells:
//!
//! | Capability | macOS | Windows |
//! |---|---|---|
//! | Inter-app video | Syphon | Spout |
//! | Screen capture | ScreenCaptureKit | Windows Graphics Capture |
//! | Camera / UVC | AVFoundation | Media Foundation |
//! | H.264/HEVC decode | VideoToolbox | Media Foundation / NVDEC |
//! | Display control | CGDirectDisplay | DXGI |
//!
//! ## Rules
//!
//! - **Nothing here blocks.** A source is asked for a frame at a deadline and
//!   answers immediately with what it has. A late source must never stall the
//!   render path or every other output with it.
//! - **Frames are leased, not owned.** A consumer holds a [`FrameLease`] and
//!   the slot is reused only after every GPU and sink consumer is done.
//! - **No Apple or Windows types cross this boundary** — only plain data.

use crate::doc::{ColorDescriptor, Rational};

/// Opaque handle to a shell-side GPU resource.
///
/// The core schedules and reasons about frames without knowing what a texture
/// actually is. `generation` invalidates stale references when a slot is
/// recycled, so a late completion can be discarded rather than painting a
/// recycled frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ResourceId {
    /// Shell-assigned slot index.
    pub slot: u32,
    /// Incremented each time the slot is reused.
    pub generation: u32,
}

/// A frame ready for use, plus everything needed to interpret it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FrameDescriptor {
    /// The shell-side resource holding the pixels.
    pub resource: ResourceId,
    /// Pixel width.
    pub width: u32,
    /// Pixel height.
    pub height: u32,
    /// Presentation timestamp in `timebase` units.
    pub pts: i64,
    /// Units for `pts`.
    pub timebase: Rational,
    /// How to interpret the pixels. Never inferred.
    pub color: ColorDescriptor,
    /// True if this frame was repeated because no new one arrived in time.
    ///
    /// Counted separately from a dropped frame: a repeat means the *source*
    /// was late; a drop means *we* missed a deadline. Conflating them hides
    /// which half of the pipeline is at fault.
    pub repeated: bool,
}

/// A borrow of a frame's resource.
///
/// Held for as long as any GPU or sink consumer might read it. The slot is
/// recycled only once every lease is released.
#[derive(Debug)]
pub struct FrameLease {
    /// The leased resource.
    pub resource: ResourceId,
}

/// Why a frame wasn't available.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameMiss {
    /// Decode hasn't produced this timestamp yet. Previous frame should be held.
    NotReady,
    /// Source has ended and does not loop.
    EndOfStream,
    /// Device disconnected or file became unreadable. Hold last valid frame and
    /// surface operator status — never black the output implicitly.
    Unavailable,
}

/// A source of video frames.
///
/// Implemented per platform for files, Syphon/Spout, NDI, capture devices and
/// screen capture.
pub trait VideoSource {
    /// Asks for the frame at `pts`, **without blocking**.
    ///
    /// Returns [`FrameMiss::NotReady`] rather than waiting. The caller holds
    /// the previous frame; it does not stall.
    fn frame_at(&mut self, pts: i64, timebase: Rational) -> Result<FrameDescriptor, FrameMiss>;

    /// Hints that playback is heading toward `pts`, so decode can run ahead.
    fn prefetch(&mut self, pts: i64, timebase: Rational);

    /// Native cadence, if the source has a fixed one.
    fn native_rate(&self) -> Option<Rational>;

    /// Invalidates in-flight work after a seek.
    ///
    /// Completions tagged with an older generation are discarded rather than
    /// displayed — otherwise a slow decode from before the seek lands after it.
    fn seek_generation(&self) -> u32;
}

/// A destination for composited frames.
///
/// Sinks run at **their own rates**: a projector at 60 or 120 Hz, Art-Net at
/// 30–44 Hz because DMX512 cannot go faster. A slow sink degrades itself; it
/// never gates the engine.
pub trait VideoSink {
    /// Presentation rate this sink wants.
    fn rate(&self) -> Rational;

    /// Colour behaviour this sink expects.
    fn color(&self) -> ColorDescriptor;

    /// Whether this sink needs CPU-visible pixel data.
    ///
    /// True for NDI (its send API takes linear frame memory) and for Art-Net
    /// (DMX packets are CPU data). Those require a bounded **asynchronous**
    /// readback whose cost is counted — which is why "pixels never touch the
    /// CPU" was the wrong invariant.
    fn needs_cpu_readback(&self) -> bool;

    /// Presents a frame. Must not block the render thread.
    fn present(&mut self, frame: &FrameDescriptor);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recycled_slot_does_not_match_stale_reference() {
        // The bug this prevents: a late decode completing into a slot that has
        // since been reused, painting the wrong frame.
        let stale = ResourceId {
            slot: 3,
            generation: 1,
        };
        let current = ResourceId {
            slot: 3,
            generation: 2,
        };
        assert_ne!(stale, current);
    }

    #[test]
    fn frame_miss_variants_are_distinct() {
        // NotReady must never be treated as EndOfStream: one holds the last
        // frame and keeps going, the other stops the clip.
        assert_ne!(FrameMiss::NotReady, FrameMiss::EndOfStream);
        assert_ne!(FrameMiss::NotReady, FrameMiss::Unavailable);
    }
}
