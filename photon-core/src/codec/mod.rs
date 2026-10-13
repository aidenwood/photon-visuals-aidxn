//! Container and codec logic — the **portable** half.
//!
//! Containers are demuxed by a shell-side libavformat adapter, not a
//! handwritten MOV parser. FFmpeg linkage stays outside this crate: an
//! Apple-enabled FFmpeg build would otherwise pull Apple frameworks in
//! transitively and quietly break the Windows port.
//!
//! What lives here is the part that is genuinely ours and genuinely portable:
//! given a frame payload, work out **what texture format it is and what decode
//! work it implies** — and, for DXV, actually do that work. No I/O, and no
//! pixel data is ever produced; the output is GPU blocks.
//!
//! ## 🔶 [DECISION, amended] Decompression *does* live here now
//!
//! This header used to read "No I/O, no decompression", and that was a real
//! decision, not an oversight — it kept the crate to pure description and left
//! every byte-shuffling pass to the shell. [`dxv`] breaks it deliberately, and
//! the reason is the same reason this crate exists at all:
//!
//! - The DXV LZ layer is **pure CPU work over a byte slice**. It touches no
//!   platform API, allocates one `Vec<u8>`, and compiles for wasm32 — so
//!   nothing about it was keeping the crate portable by being absent.
//! - Nothing can decode it for us. FFmpeg's DXV decoder exists but emits RGBA,
//!   which throws away the one property that makes DXV cheap to play; we need
//!   the BC blocks, so the code has to be written by hand either way.
//! - Shell-side, it would be written **twice** — once in Swift, once again for
//!   Windows — and the second copy would drift from the first. Two divergent
//!   implementations of one byte-exact format is precisely the failure
//!   `photon-core` is here to prevent.
//!
//! The boundary that still holds, and the one that actually mattered, is
//! **I/O and containers**: no file handles, no demuxing, no libavformat. The
//! shell hands in a frame buffer and the visible dimensions; the core hands
//! back blocks.

pub mod dxv;
pub mod hap;

/// GPU block-compressed texture formats carried by HAP and DXV.
///
/// These are **fixed-rate** — a 4×4 block costs the same whether it is flat
/// black or noise. That is what makes the memory budgets in
/// [`crate::budget`] predictable, and it is why these formats are
/// bandwidth-friendly in a way ordinary video codecs are not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextureFormat {
    /// BC1 / DXT1, RGB. 0.5 bytes per pixel.
    Bc1Rgb,
    /// BC3 / DXT5, RGBA. 1.0 byte per pixel.
    Bc3Rgba,
    /// BC3 / DXT5 carrying scaled YCoCg — HapQ. Needs a matrix conversion when
    /// sampled.
    Bc3YCoCg,
    /// BC4 / RGTC1, single channel. Hap Alpha-only.
    Bc4Alpha,
    /// BC6H unsigned float, HDR RGB.
    Bc6hUnsigned,
    /// BC6H signed float, HDR RGB.
    Bc6hSigned,
    /// BC7 RGBA.
    Bc7Rgba,
}

impl TextureFormat {
    /// Maps a HAP type-byte low nibble to a format.
    ///
    /// Values transcribed from the Vidvox HAP specification.
    #[must_use]
    pub const fn from_hap_nibble(n: u8) -> Option<Self> {
        match n {
            0xB => Some(Self::Bc1Rgb),
            0xE => Some(Self::Bc3Rgba),
            0xF => Some(Self::Bc3YCoCg),
            0xC => Some(Self::Bc7Rgba),
            0x1 => Some(Self::Bc4Alpha),
            0x2 => Some(Self::Bc6hUnsigned),
            0x3 => Some(Self::Bc6hSigned),
            _ => None,
        }
    }

    /// Bytes per pixel, doubled so it stays an integer.
    ///
    /// BC1 and BC4 are 0.5 B/px, which is why this is halved rather than whole.
    #[must_use]
    pub const fn bytes_per_px_x2(self) -> u64 {
        match self {
            Self::Bc1Rgb | Self::Bc4Alpha => 1,
            Self::Bc3Rgba | Self::Bc3YCoCg | Self::Bc6hUnsigned | Self::Bc6hSigned
            | Self::Bc7Rgba => 2,
        }
    }

    /// Encoded size of one frame at this resolution.
    ///
    /// Rounded up to whole 4×4 blocks — an edge narrower than a block still
    /// occupies a full one.
    #[must_use]
    pub const fn frame_bytes(self, width: u32, height: u32) -> u64 {
        let bw = width.div_ceil(4) as u64;
        let bh = height.div_ceil(4) as u64;
        // 16 px per block × bytes-per-px, kept integral via the x2 trick.
        (bw * bh * 16 * self.bytes_per_px_x2()) / 2
    }

    /// Whether sampling requires a YCoCg→RGB conversion.
    #[must_use]
    pub const fn needs_color_conversion(self) -> bool {
        matches!(self, Self::Bc3YCoCg)
    }

    /// Whether the format carries alpha.
    ///
    /// Feeds occlusion culling: a layer only occludes what is beneath it if it
    /// geometrically covers **and** cannot be transparent. Full opacity alone
    /// is not sufficient.
    #[must_use]
    pub const fn has_alpha(self) -> bool {
        matches!(self, Self::Bc3Rgba | Self::Bc7Rgba | Self::Bc4Alpha)
    }
}

/// Why a frame could not be parsed.
///
/// Malformed media is **expected input**, not an exceptional condition — a VJ
/// tool that panics on a bad file during a show has failed. Every one of these
/// is recoverable by holding the last valid frame and surfacing operator status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum CodecError {
    /// Buffer ended before the structure said it would.
    #[error("truncated: needed {need} bytes, got {got}")]
    Truncated {
        /// Bytes the structure requires.
        need: usize,
        /// Bytes actually present.
        got: usize,
    },
    /// Structurally invalid in a way the format forbids.
    #[error("malformed: {0}")]
    Malformed(&'static str),
    /// Texture format nibble is not one we know.
    #[error("unknown texture format nibble 0x{0:X}")]
    UnknownTextureFormat(u8),
    /// Second-stage compressor is not one we know.
    #[error("unknown compressor 0x{0:X}")]
    UnknownCompressor(u8),
    /// An LZ back-reference pointed before the start of the output produced so
    /// far. Always a corrupt or misparsed stream — never a recoverable state.
    #[error("bad back-reference: distance {dist} with only {available} units decoded")]
    BadDistance {
        /// Distance the stream asked to look back, in units.
        dist: usize,
        /// Units actually decoded so far.
        available: usize,
    },
    /// The compression scheme for this variant has not been reverse-engineered.
    ///
    /// Returned rather than guessing. Plausible-looking wrong pixels in a live
    /// show are worse than a source that refuses to load and says why.
    #[error("decompression not derived for this variant")]
    NotDerived,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_sizes_match_the_tier_arithmetic() {
        // The numbers the whole performance spec is built on.
        assert_eq!(TextureFormat::Bc1Rgb.frame_bytes(1920, 1080), 1_036_800);
        assert_eq!(TextureFormat::Bc3Rgba.frame_bytes(1920, 1080), 2_073_600);
        assert_eq!(TextureFormat::Bc3Rgba.frame_bytes(3840, 2160), 8_294_400);
    }

    #[test]
    fn non_block_aligned_sizes_round_up_to_whole_blocks() {
        // 1918x1078 still occupies 480x270 blocks, same as 1920x1080.
        assert_eq!(
            TextureFormat::Bc1Rgb.frame_bytes(1918, 1078),
            TextureFormat::Bc1Rgb.frame_bytes(1920, 1080)
        );
    }

    #[test]
    fn hapq_is_flagged_for_color_conversion() {
        assert!(TextureFormat::Bc3YCoCg.needs_color_conversion());
        assert!(!TextureFormat::Bc3Rgba.needs_color_conversion());
    }

    #[test]
    fn alpha_capable_formats_cannot_be_assumed_to_occlude() {
        assert!(TextureFormat::Bc3Rgba.has_alpha());
        assert!(TextureFormat::Bc7Rgba.has_alpha());
        assert!(!TextureFormat::Bc1Rgb.has_alpha());
        assert!(!TextureFormat::Bc3YCoCg.has_alpha());
    }

    #[test]
    fn every_spec_nibble_maps() {
        for n in [0xB, 0xE, 0xF, 0xC, 0x1, 0x2, 0x3] {
            assert!(TextureFormat::from_hap_nibble(n).is_some(), "nibble {n:X}");
        }
        assert!(TextureFormat::from_hap_nibble(0x9).is_none());
    }
}
