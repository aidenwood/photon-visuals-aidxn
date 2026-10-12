//! DXV frame parsing (Resolume's codec).
//!
//! Structure taken from FFmpeg's public `libavcodec/dxv.c` decoder and
//! **verified byte-for-byte against a real DXV file** generated locally — see
//! the tests. Not inferred, not disassembled.
//!
//! ## Why DXV support is required
//!
//! The performance tiers are specified in DXV, so a HAP-only engine cannot
//! claim them. DXV is also what every existing Resolume library is encoded in,
//! which makes read support the difference between "import your show" and
//! "re-encode everything first".
//!
//! ## 🔴 The difference from HAP that matters for scheduling
//!
//! **DXV has no chunk table.** HAP deliberately splits a frame into several
//! independently-compressed chunks so multiple cores can decode *one frame* in
//! parallel. DXV's payload is a **single contiguous LZ stream** — it must be
//! decompressed by one worker, start to finish.
//!
//! ## ⚠️ Decompression is NOT implemented
//!
//! The compression is a **DXV-specific LZ variant**, proven by feeding a real
//! DXV3 payload to a stock LZF decoder — it returns `InvalidData`. FFmpeg
//! implements its own `dxv_decompress_*` routines rather than calling a generic
//! LZF. So this module **parses** DXV (header, format, version, payload
//! location) but cannot yet **decode** it.
//!
//! Note also that FFmpeg's DXV decoder outputs RGBA — CPU-decoded — which
//! destroys the GPU-blocks advantage, so simply linking it is not a solution
//! for the playback path. We need block-level extraction either way.
//!
//! So decode parallelism for DXV exists only *across layers*, never within a
//! frame. At the 4–12 layer tiers that is fine (each layer is an independent
//! work item), but it means a single large DXV layer cannot be split, and the
//! scheduler must not assume otherwise.

use super::{CodecError, TextureFormat};

/// Second-stage compression applied to the texture payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Compression {
    /// Blocks stored verbatim — no CPU pass, straight to the GPU.
    Raw,
    /// A **DXV-specific LZ variant**, not stock LZF and not snappy.
    ///
    /// ⚠️ **Verified by falsification:** a stock LZF decoder fed a real DXV3
    /// payload returns `InvalidData`. FFmpeg calls the mode "LZF" loosely but
    /// implements codec-specific decompressors (`dxv_decompress_dxt1` and
    /// friends). **Decompression is therefore unimplemented** — see the module
    /// note. Parsing identifies the work; it does not yet perform it.
    DxvLz,
}

/// A parsed DXV frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// GPU texture format of the decompressed blocks.
    pub format: TextureFormat,
    /// How the payload is compressed.
    pub compression: Compression,
    /// DXV version (1 = DXV, 3 = DXV3, 4 = DXV4).
    pub version: u8,
    /// Byte offset of the payload within the frame buffer.
    pub payload_offset: usize,
    /// Payload length in bytes.
    pub payload_len: usize,
}

impl Frame {
    /// Always `false` for DXV — there is no chunk table to split.
    ///
    /// Present so the scheduler can ask the same question of any codec.
    #[must_use]
    pub const fn is_parallel(&self) -> bool {
        false
    }

    /// Whether a CPU decompression pass is needed before upload.
    #[must_use]
    pub const fn needs_decompression(&self) -> bool {
        matches!(self.compression, Compression::DxvLz)
    }
}

// Tags are stored REVERSED in the file: "DXT1" appears as bytes `31 54 58 44`
// ("1TXD"). Reading those little-endian yields the big-endian value of the
// ASCII, hence from_be_bytes here. Verified against a real file.
const TAG_DXT1: u32 = u32::from_be_bytes(*b"DXT1");
const TAG_DXT5: u32 = u32::from_be_bytes(*b"DXT5");
const TAG_YCG6: u32 = u32::from_be_bytes(*b"YCG6");
const TAG_YG10: u32 = u32::from_be_bytes(*b"YG10");

fn format_for_tag(tag: u32) -> Option<TextureFormat> {
    match tag {
        TAG_DXT1 => Some(TextureFormat::Bc1Rgb),
        // DXT5 here carries premultiplied alpha (FFmpeg decodes it as DXT4).
        TAG_DXT5 => Some(TextureFormat::Bc3Rgba),
        // YCoCg variants ride in a BC3-shaped container and need the colour
        // matrix applied when sampled.
        TAG_YCG6 | TAG_YG10 => Some(TextureFormat::Bc3YCoCg),
        _ => None,
    }
}

/// Parses one DXV frame.
///
/// Handles both the modern 12-byte header and the legacy packed form.
///
/// # Errors
/// [`CodecError`] if truncated, or if the tag is not a known DXV texture format.
pub fn parse_frame(buf: &[u8]) -> Result<Frame, CodecError> {
    if buf.len() < 12 {
        return Err(CodecError::Truncated {
            need: 12,
            got: buf.len(),
        });
    }
    let tag = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);

    if let Some(format) = format_for_tag(tag) {
        // Modern header:
        //   0..4  tag
        //   4     version major (stored +1)
        //   5     version minor
        //   6     compression flag — non-zero means RAW
        //   7     reserved
        //   8..12 payload size, LE
        let version = buf[4].saturating_sub(1);
        let compression = if buf[6] != 0 {
            Compression::Raw
        } else {
            Compression::DxvLz
        };
        let payload_len = u32::from_le_bytes([buf[8], buf[9], buf[10], buf[11]]) as usize;

        if payload_len > buf.len().saturating_sub(12) {
            return Err(CodecError::Truncated {
                need: 12 + payload_len,
                got: buf.len(),
            });
        }
        return Ok(Frame {
            format,
            compression,
            version,
            payload_offset: 12,
            payload_len,
        });
    }

    // Legacy packed form: low 24 bits are the size, high 8 bits are flags.
    let size = (tag & 0x00FF_FFFF) as usize;
    let flags = (tag >> 24) as u8;
    if size == 0 {
        return Err(CodecError::UnknownTextureFormat((tag & 0xFF) as u8));
    }
    let compression = if flags & 0x80 != 0 {
        Compression::Raw
    } else {
        Compression::DxvLz
    };
    let format = if flags & 0x40 != 0 {
        TextureFormat::Bc3Rgba
    } else {
        TextureFormat::Bc1Rgb
    };
    if size > buf.len().saturating_sub(4) {
        return Err(CodecError::Truncated {
            need: 4 + size,
            got: buf.len(),
        });
    }
    Ok(Frame {
        format,
        compression,
        version: 1,
        payload_offset: 4,
        payload_len: size,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The first 12 bytes of frame 0 from a real file produced by
    /// `ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 2 -c:v dxv`,
    /// read out of the MOV's `mdat`. ffprobe reported `codec_tag_string=DXD3`.
    const REAL_DXV3_HEADER: [u8; 12] = [
        0x31, 0x54, 0x58, 0x44, // "1TXD" -> tag DXT1 little-endian
        0x04, // version major, stored +1 -> DXV3
        0x00, // version minor
        0x00, // compression flag 0 -> LZF
        0x00, // reserved
        0x59, 0x33, 0x01, 0x00, // payload = 78,681 bytes
    ];

    /// Builds a frame, writing the real payload length into the size field so
    /// the header stays self-consistent when a test varies the payload.
    fn frame_with_payload(header: [u8; 12], payload_len: usize) -> Vec<u8> {
        let mut v = header.to_vec();
        v[8..12].copy_from_slice(&(payload_len as u32).to_le_bytes());
        v.extend(std::iter::repeat_n(0u8, payload_len));
        v
    }

    /// The untouched real header, for the fixture test that must not be altered.
    fn real_frame() -> Vec<u8> {
        let mut v = REAL_DXV3_HEADER.to_vec();
        v.extend(std::iter::repeat_n(0u8, 78_681));
        v
    }

    #[test]
    fn parses_a_real_dxv3_frame_header() {
        let buf = real_frame();
        let f = parse_frame(&buf).expect("parse");

        assert_eq!(f.format, TextureFormat::Bc1Rgb);
        assert_eq!(f.compression, Compression::DxvLz);
        assert_eq!(f.version, 3, "DXD3 == DXV3; version byte is stored +1");
        assert_eq!(f.payload_offset, 12);
        assert_eq!(f.payload_len, 78_681);
        assert!(f.needs_decompression());
    }

    #[test]
    fn dxv_frames_are_never_internally_parallel() {
        // The scheduling consequence: unlike HAP, one DXV frame is one work
        // item. Parallelism comes from having several layers, not from
        // splitting a frame.
        assert!(!parse_frame(&real_frame()).unwrap().is_parallel());
    }

    #[test]
    fn raw_flag_means_no_cpu_pass() {
        let mut h = REAL_DXV3_HEADER;
        h[6] = 1; // compression flag set -> raw
        let f = parse_frame(&frame_with_payload(h, 1024)).expect("parse");
        assert_eq!(f.compression, Compression::Raw);
        assert!(!f.needs_decompression(), "raw blocks go straight to the GPU");
    }

    #[test]
    fn recognises_every_documented_tag() {
        for (tag, want) in [
            (*b"DXT1", TextureFormat::Bc1Rgb),
            (*b"DXT5", TextureFormat::Bc3Rgba),
            (*b"YCG6", TextureFormat::Bc3YCoCg),
            (*b"YG10", TextureFormat::Bc3YCoCg),
        ] {
            let mut h = REAL_DXV3_HEADER;
            // Tags are stored reversed in the file, so the fixture must be too.
            let mut rev = tag;
            rev.reverse();
            h[..4].copy_from_slice(&rev);
            let f = parse_frame(&frame_with_payload(h, 64)).expect("parse");
            assert_eq!(f.format, want, "tag {:?}", std::str::from_utf8(&tag));
        }
    }

    #[test]
    fn ycocg_variants_are_flagged_for_colour_conversion() {
        let mut h = REAL_DXV3_HEADER;
        h[..4].copy_from_slice(b"6GCY"); // "YCG6" reversed, as stored on disk
        let f = parse_frame(&frame_with_payload(h, 64)).unwrap();
        assert!(
            f.format.needs_color_conversion(),
            "YCoCg must be converted when sampled, or colours are wrong"
        );
    }

    #[test]
    fn truncated_payload_is_an_error_not_a_panic() {
        // Malformed media is expected input, never a crash during a show.
        let mut buf = REAL_DXV3_HEADER.to_vec();      // header claims 78,681
        buf.extend(std::iter::repeat_n(0u8, 100)); // but only 100 supplied
        let buf = buf;
        assert!(matches!(
            parse_frame(&buf),
            Err(CodecError::Truncated { .. })
        ));
        assert!(parse_frame(&[]).is_err());
        assert!(parse_frame(&[0u8; 11]).is_err());
    }

    #[test]
    fn legacy_packed_header_is_handled() {
        // Low 24 bits = size, high 8 = flags. 0x80 = raw, 0x40 = DXT5.
        let packed: u32 = (0xC0 << 24) | 256;
        let mut v = packed.to_le_bytes().to_vec();
        v.extend(std::iter::repeat_n(0u8, 256));
        let f = parse_frame(&v).expect("parse");
        assert_eq!(f.payload_offset, 4);
        assert_eq!(f.payload_len, 256);
        assert_eq!(f.compression, Compression::Raw);
        assert_eq!(f.format, TextureFormat::Bc3Rgba);
    }
}
