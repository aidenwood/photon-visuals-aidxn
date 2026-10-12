//! HAP frame parsing.
//!
//! Layout per the Vidvox HAP specification (`HapVideoDRAFT.md`). Constants here
//! are transcribed from that spec, not inferred.
//!
//! ## Why this matters more than it looks
//!
//! HAP does not store *video*. It stores **GPU-ready block-compressed texture
//! data** (BC1/BC3/BC4/BC6/BC7) wrapped in an optional lossless second stage
//! (snappy). So the GPU never decodes video — it receives texture blocks, and
//! the only CPU work in the whole playback path is the snappy pass.
//!
//! ## The chunk tables are the performance story
//!
//! A frame may carry a **Decode Instructions Container** splitting it into
//! independently-compressed chunks, each with its own compressor, size and
//! offset. That is what lets several cores decode *one frame* in parallel
//! instead of being stuck at one-core-per-layer — which on a 4-performance-core
//! target is the difference between hitting the tiers and not.
//!
//! This module is pure parsing: no I/O, no allocation of pixel data, no
//! decompression. It tells the scheduler *what work exists*; the shell-side
//! adapter supplies the packets and performs the snappy pass.
//!
//! ## ⚠️ Status: spec-conformant, **not yet verified against real media**
//!
//! Every constant here is transcribed from the published specification and
//! exercised by synthetic fixtures. **No real HAP file has been parsed yet** —
//! the installed FFmpeg cannot encode HAP (no `--enable-libsnappy`, and it
//! exits 0 while failing), so no corpus exists.
//!
//! Treat this as a hypothesis until a real file round-trips. First real frame
//! parsed should be asserted against a known-good fixture and that test kept.

use super::{CodecError, TextureFormat};

/// Second-stage (lossless) compressor applied to a chunk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Compressor {
    /// Blocks are stored verbatim.
    None,
    /// Snappy — LZ77-family, ~1.5–2× ratio at ~1–2 GB/s per core.
    Snappy,
}

impl Compressor {
    /// From a second-stage compressor table entry.
    const fn from_table_byte(b: u8) -> Option<Self> {
        match b {
            0x0A => Some(Self::None),
            0x0B => Some(Self::Snappy),
            _ => None,
        }
    }
}

/// One independently decodable chunk of a frame.
///
/// Chunks have no data dependency on each other, so they can be dispatched to
/// separate workers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chunk {
    /// Byte offset of this chunk's payload, relative to the frame buffer.
    pub offset: usize,
    /// Compressed byte length.
    pub len: usize,
    /// How to decompress it.
    pub compressor: Compressor,
}

/// A parsed HAP frame: everything needed to schedule its decode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// GPU texture format the decompressed blocks are in.
    pub format: TextureFormat,
    /// Independently decodable chunks, in order. Always at least one.
    pub chunks: Vec<Chunk>,
}

impl Frame {
    /// Whether this frame can be decoded across multiple workers.
    #[must_use]
    pub fn is_parallel(&self) -> bool {
        self.chunks.len() > 1
    }

    /// Whether any chunk needs CPU decompression.
    ///
    /// If false, blocks can go straight to the GPU with no CPU pass at all.
    #[must_use]
    pub fn needs_decompression(&self) -> bool {
        self.chunks.iter().any(|c| c.compressor == Compressor::Snappy)
    }

    /// Total compressed bytes across all chunks.
    #[must_use]
    pub fn compressed_len(&self) -> usize {
        self.chunks.iter().map(|c| c.len).sum()
    }
}

/// A section header: 4 bytes normally, 8 when the short size field is zero.
struct Header {
    size: usize,
    kind: u8,
    header_len: usize,
}

fn read_header(buf: &[u8]) -> Result<Header, CodecError> {
    if buf.len() < 4 {
        return Err(CodecError::Truncated {
            need: 4,
            got: buf.len(),
        });
    }
    let short = u32::from(buf[0]) | (u32::from(buf[1]) << 8) | (u32::from(buf[2]) << 16);
    let kind = buf[3];

    if short == 0 {
        // Extended header: the 32-bit size follows the 4-byte prefix.
        if buf.len() < 8 {
            return Err(CodecError::Truncated {
                need: 8,
                got: buf.len(),
            });
        }
        let size = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]) as usize;
        Ok(Header {
            size,
            kind,
            header_len: 8,
        })
    } else {
        Ok(Header {
            size: short as usize,
            kind,
            header_len: 4,
        })
    }
}

/// Splits a type byte into its compressor (high nibble) and format (low nibble).
const fn split_type(kind: u8) -> (u8, u8) {
    (kind >> 4, kind & 0x0F)
}

const COMP_NONE: u8 = 0xA;
const COMP_SNAPPY: u8 = 0xB;
const COMP_DECODE_INSTRUCTIONS: u8 = 0xC;

const SECTION_DECODE_INSTRUCTIONS: u8 = 0x01;
const SECTION_COMPRESSOR_TABLE: u8 = 0x02;
const SECTION_SIZE_TABLE: u8 = 0x03;
const SECTION_OFFSET_TABLE: u8 = 0x04;

/// Parses one HAP frame.
///
/// `buf` is a complete frame payload as delivered by the container demuxer —
/// one sample from the MOV track.
///
/// # Errors
/// Returns [`CodecError`] if the frame is truncated, uses an unknown texture
/// format or compressor, or carries inconsistent chunk tables.
pub fn parse_frame(buf: &[u8]) -> Result<Frame, CodecError> {
    let h = read_header(buf)?;
    let body_start = h.header_len;
    let body_end = body_start
        .checked_add(h.size)
        .ok_or(CodecError::Malformed("section size overflows"))?;
    if body_end > buf.len() {
        return Err(CodecError::Truncated {
            need: body_end,
            got: buf.len(),
        });
    }

    let (comp, fmt) = split_type(h.kind);
    let format = TextureFormat::from_hap_nibble(fmt)
        .ok_or(CodecError::UnknownTextureFormat(fmt))?;

    match comp {
        COMP_NONE | COMP_SNAPPY => {
            // Single chunk covering the whole body.
            let compressor = if comp == COMP_SNAPPY {
                Compressor::Snappy
            } else {
                Compressor::None
            };
            Ok(Frame {
                format,
                chunks: vec![Chunk {
                    offset: body_start,
                    len: h.size,
                    compressor,
                }],
            })
        }
        COMP_DECODE_INSTRUCTIONS => {
            let chunks = parse_decode_instructions(&buf[body_start..body_end], body_start)?;
            Ok(Frame { format, chunks })
        }
        other => Err(CodecError::UnknownCompressor(other)),
    }
}

/// Parses the Decode Instructions Container and resolves it to chunks.
fn parse_decode_instructions(body: &[u8], body_abs: usize) -> Result<Vec<Chunk>, CodecError> {
    let h = read_header(body)?;
    if h.kind != SECTION_DECODE_INSTRUCTIONS {
        return Err(CodecError::Malformed(
            "expected a Decode Instructions Container",
        ));
    }
    let start = h.header_len;
    let end = start
        .checked_add(h.size)
        .filter(|e| *e <= body.len())
        .ok_or(CodecError::Truncated {
            need: start + h.size,
            got: body.len(),
        })?;

    let mut compressors: Vec<u8> = Vec::new();
    let mut sizes: Vec<u32> = Vec::new();
    let mut offsets: Vec<u32> = Vec::new();

    // Walk child sections.
    let mut p = start;
    while p < end {
        let ch = read_header(&body[p..end])?;
        let d0 = p + ch.header_len;
        let d1 = d0
            .checked_add(ch.size)
            .filter(|e| *e <= end)
            .ok_or(CodecError::Truncated {
                need: d0 + ch.size,
                got: end,
            })?;
        let data = &body[d0..d1];

        match ch.kind {
            SECTION_COMPRESSOR_TABLE => compressors = data.to_vec(),
            SECTION_SIZE_TABLE => sizes = read_u32_table(data)?,
            SECTION_OFFSET_TABLE => offsets = read_u32_table(data)?,
            // Unknown child sections are skipped, per the spec's forward-
            // compatibility intent.
            _ => {}
        }
        p = d1;
    }

    if compressors.is_empty() || sizes.is_empty() {
        return Err(CodecError::Malformed(
            "decode instructions missing compressor or size table",
        ));
    }
    if compressors.len() != sizes.len() {
        return Err(CodecError::Malformed(
            "compressor and size tables disagree on chunk count",
        ));
    }
    if !offsets.is_empty() && offsets.len() != sizes.len() {
        return Err(CodecError::Malformed(
            "offset table disagrees on chunk count",
        ));
    }

    // The offset table is optional: without it chunks are contiguous from the
    // end of the container.
    let mut running = body_abs + end;
    let mut chunks = Vec::with_capacity(sizes.len());
    for (i, &size) in sizes.iter().enumerate() {
        let compressor = Compressor::from_table_byte(compressors[i])
            .ok_or(CodecError::UnknownCompressor(compressors[i]))?;
        let offset = if offsets.is_empty() {
            let o = running;
            running += size as usize;
            o
        } else {
            body_abs + end + offsets[i] as usize
        };
        chunks.push(Chunk {
            offset,
            len: size as usize,
            compressor,
        });
    }
    Ok(chunks)
}

fn read_u32_table(data: &[u8]) -> Result<Vec<u32>, CodecError> {
    if !data.len().is_multiple_of(4) {
        return Err(CodecError::Malformed("u32 table is not 4-byte aligned"));
    }
    Ok(data
        .chunks_exact(4)
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a 4-byte section header.
    fn hdr(size: u32, kind: u8) -> Vec<u8> {
        vec![
            (size & 0xFF) as u8,
            ((size >> 8) & 0xFF) as u8,
            ((size >> 16) & 0xFF) as u8,
            kind,
        ]
    }

    #[test]
    fn parses_single_chunk_snappy_dxt1() {
        let payload = vec![0u8; 16];
        let mut f = hdr(16, 0xBB); // snappy + DXT1
        f.extend_from_slice(&payload);

        let frame = parse_frame(&f).expect("parse");
        assert_eq!(frame.format, TextureFormat::Bc1Rgb);
        assert_eq!(frame.chunks.len(), 1);
        assert_eq!(frame.chunks[0].compressor, Compressor::Snappy);
        assert_eq!(frame.chunks[0].offset, 4);
        assert_eq!(frame.chunks[0].len, 16);
        assert!(frame.needs_decompression());
        assert!(!frame.is_parallel());
    }

    #[test]
    fn uncompressed_frame_needs_no_cpu_pass() {
        // 0xAE = no second stage + DXT5. These go straight to the GPU.
        let mut f = hdr(8, 0xAE);
        f.extend_from_slice(&[0u8; 8]);

        let frame = parse_frame(&f).expect("parse");
        assert_eq!(frame.format, TextureFormat::Bc3Rgba);
        assert!(!frame.needs_decompression());
    }

    #[test]
    fn extended_header_is_used_when_short_size_is_zero() {
        // Frames over 16MB, and the trap: the first three bytes being zero is
        // the *signal*, not a zero-length section.
        let mut f = vec![0x00, 0x00, 0x00, 0xBF];
        f.extend_from_slice(&32u32.to_le_bytes());
        f.extend_from_slice(&[0u8; 32]);

        let frame = parse_frame(&f).expect("parse");
        assert_eq!(frame.format, TextureFormat::Bc3YCoCg);
        assert_eq!(frame.chunks[0].offset, 8, "payload follows an 8-byte header");
        assert_eq!(frame.chunks[0].len, 32);
    }

    #[test]
    fn parses_multi_chunk_decode_instructions() {
        // This is the case that makes multi-core single-frame decode possible.
        let compressors = [0x0B_u8, 0x0B, 0x0A, 0x0B]; // snappy, snappy, none, snappy
        let sizes = [10u32, 20, 30, 40];

        let mut di = Vec::new();
        di.extend_from_slice(&hdr(compressors.len() as u32, SECTION_COMPRESSOR_TABLE));
        di.extend_from_slice(&compressors);
        di.extend_from_slice(&hdr((sizes.len() * 4) as u32, SECTION_SIZE_TABLE));
        for s in sizes {
            di.extend_from_slice(&s.to_le_bytes());
        }

        let mut container = hdr(di.len() as u32, SECTION_DECODE_INSTRUCTIONS);
        container.extend_from_slice(&di);

        let total: u32 = sizes.iter().sum();
        let mut frame_buf = hdr(container.len() as u32 + total, 0xCE); // DI + DXT5
        frame_buf.extend_from_slice(&container);
        frame_buf.extend_from_slice(&vec![0u8; total as usize]);

        let frame = parse_frame(&frame_buf).expect("parse");
        assert_eq!(frame.chunks.len(), 4);
        assert!(frame.is_parallel(), "4 chunks can go to 4 workers");
        assert_eq!(frame.compressed_len(), 100);

        // Without an offset table, chunks are contiguous.
        let first = frame.chunks[0].offset;
        assert_eq!(frame.chunks[1].offset, first + 10);
        assert_eq!(frame.chunks[2].offset, first + 30);
        assert_eq!(frame.chunks[3].offset, first + 60);

        // Mixed compressors within one frame are legal.
        assert_eq!(frame.chunks[2].compressor, Compressor::None);
        assert_eq!(frame.chunks[3].compressor, Compressor::Snappy);
    }

    #[test]
    fn truncated_frame_is_an_error_not_a_panic() {
        // Malformed media must never crash a live show.
        assert!(parse_frame(&[]).is_err());
        assert!(parse_frame(&[0x10]).is_err());
        assert!(parse_frame(&hdr(999, 0xBB)).is_err(), "size exceeds buffer");
        assert!(parse_frame(&[0x00, 0x00, 0x00, 0xBB]).is_err(), "extended header cut short");
    }

    #[test]
    fn mismatched_chunk_tables_are_rejected() {
        // 3 compressors, 2 sizes — would otherwise index out of bounds.
        let mut di = Vec::new();
        di.extend_from_slice(&hdr(3, SECTION_COMPRESSOR_TABLE));
        di.extend_from_slice(&[0x0B, 0x0B, 0x0B]);
        di.extend_from_slice(&hdr(8, SECTION_SIZE_TABLE));
        di.extend_from_slice(&10u32.to_le_bytes());
        di.extend_from_slice(&20u32.to_le_bytes());

        let mut container = hdr(di.len() as u32, SECTION_DECODE_INSTRUCTIONS);
        container.extend_from_slice(&di);
        let mut f = hdr(container.len() as u32, 0xCE);
        f.extend_from_slice(&container);

        assert!(matches!(parse_frame(&f), Err(CodecError::Malformed(_))));
    }

    #[test]
    fn unknown_format_and_compressor_are_reported_distinctly() {
        // 0x09 is not a defined texture format nibble.
        let mut f = hdr(0, 0xB9);
        f.extend_from_slice(&[]);
        // Short size 0 triggers the extended header path, so build it properly.
        let mut g = vec![0x01, 0x00, 0x00, 0xB9, 0x00];
        g.truncate(5);
        assert!(matches!(
            parse_frame(&g),
            Err(CodecError::UnknownTextureFormat(0x09))
        ));

        // 0xD is not a defined compressor nibble.
        let mut h = vec![0x01, 0x00, 0x00, 0xDB, 0x00];
        h.truncate(5);
        assert!(matches!(
            parse_frame(&h),
            Err(CodecError::UnknownCompressor(0xD))
        ));
        let _ = f;
    }
}
