//! DXV3 (Resolume) decompressor — clean-room, derived from observed I/O behaviour only.
//!
//! # Frame header (12 bytes)
//! ```text
//! 0..4   four-cc, stored byte-reversed on disk ("DXT1" -> 31 54 58 44)
//! 4      version major, stored +1 (0x04 => DXV3)
//! 5      version minor
//! 6      compression flag — NONZERO = raw/uncompressed, ZERO = compressed
//! 7      reserved
//! 8..12  payload size, little-endian u32
//! ```
//! Tags: `DXT1` -> BC1 (8 B/block), `DXT5` -> BC3 (16 B/block),
//! `YCG6`/`YG10` -> BC3-shaped YCoCg.
//!
//! # Compressed stream (VERIFIED for DXT1)
//!
//! Output is a sequence of 4-byte little-endian **units**. A BC1 block is 2 units:
//! `[colour-pair word][index word]`. Even units are colour words, odd units are index
//! words; every expressible back-reference distance is even, so references never cross
//! planes.
//!
//! * The output buffer is zero-initialised (observable: unwritten blocks decode as
//!   all-zero, and no 4-byte zero runs ever appear in a payload).
//! * The first 8 bytes of the payload are an **unconditional literal** (block 0, units
//!   0 and 1). No flag bits are spent on it; the op loop starts at unit 2.
//! * A 32-bit little-endian **mask word** is pulled from the stream lazily — whenever
//!   the op loop needs bits and the current mask is spent, the next 4 bytes become the
//!   new mask. That is why mask words sit *interleaved* with literal/offset bytes.
//! * Mask bits are consumed **LSB-first**, two at a time. With `b0` = low bit and
//!   `b1` = next bit, the code value is `b0 | (b1 << 1)`:
//!
//! | code | op | extra bytes | effect |
//! |------|----|-------------|--------|
//! | `0b01` | COPY  | 0           | copy 2 units from distance 2 units (previous block) |
//! | `0b10` | SHORT | 1 (`u8 b`)  | copy 2 units from distance `2*b + 4` units |
//! | `0b11` | LONG  | 2 (`u16 v`) | copy 2 units from distance `2*(v + 256) + 4` units |
//! | `0b00` | SPLIT | —           | read two more 2-bit sub-ops, one per unit |
//!
//! A SPLIT still emits exactly 2 units (one block) but codes the colour word and the
//! index word independently. Sub-ops use the same alphabet on a **single** unit:
//!
//! | sub-code | op | extra bytes | effect |
//! |----------|----|-------------|--------|
//! | `0b01` | COPY    | 0           | 1 unit from distance 2 units |
//! | `0b10` | SHORT   | 1 (`u8 b`)  | 1 unit from distance `2*b + 4` |
//! | `0b11` | LONG    | 2 (`u16 v`) | 1 unit from distance `2*(v + 256) + 4` |
//! | `0b00` | LITERAL | 4           | 1 unit read verbatim |
//!
//! The minimum explicit distance is 4 units (2 blocks back) because distance 2 is
//! already free via COPY. The encoder may emit a trailing mask word that is never
//! consumed — stop as soon as the output is full.
//!
//! # Texture dimensions (measured on ffmpeg-produced files)
//! `texture_w = align(frame_w, 16)`, `texture_h = align(frame_h, 4)`; the visible frame
//! is the top-left crop.

#![allow(dead_code)] // spike: module is a reference impl, not all of it is wired to main

use std::fmt;

#[derive(Debug)]
pub enum Error {
    Truncated,
    BadDistance { dist: usize, available: usize },
    UnsupportedTag([u8; 4]),
    ShortPayload,
    /// The format for this tag has not been reverse-engineered. See `decompress_dxt5`.
    NotDerived,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Truncated => write!(f, "payload truncated"),
            Error::BadDistance { dist, available } => {
                write!(f, "back-reference {dist} beyond {available} written units")
            }
            Error::UnsupportedTag(t) => write!(f, "unsupported tag {:?}", std::str::from_utf8(t)),
            Error::ShortPayload => write!(f, "payload shorter than header"),
            Error::NotDerived => write!(
                f,
                "DXT5/YCoCg compressed layout not derived - see dxv::decompress_dxt5"
            ),
        }
    }
}
impl std::error::Error for Error {}

// ---------------------------------------------------------------------------

pub const OP_SPLIT: u32 = 0b00;
pub const OP_COPY: u32 = 0b01;
pub const OP_SHORT: u32 = 0b10;
pub const OP_LONG: u32 = 0b11;

struct Reader<'a> {
    b: &'a [u8],
    p: usize,
    mask: u32,
    nbits: u32,
}

impl<'a> Reader<'a> {
    #[inline]
    fn new(b: &'a [u8]) -> Self {
        Reader { b, p: 0, mask: 0, nbits: 0 }
    }
    #[inline]
    fn u8(&mut self) -> Result<u32, Error> {
        let v = *self.b.get(self.p).ok_or(Error::Truncated)?;
        self.p += 1;
        Ok(v as u32)
    }
    #[inline]
    fn u16(&mut self) -> Result<u32, Error> {
        if self.p + 2 > self.b.len() {
            return Err(Error::Truncated);
        }
        let v = u16::from_le_bytes([self.b[self.p], self.b[self.p + 1]]) as u32;
        self.p += 2;
        Ok(v)
    }
    #[inline]
    fn u32(&mut self) -> Result<u32, Error> {
        if self.p + 4 > self.b.len() {
            return Err(Error::Truncated);
        }
        let v = u32::from_le_bytes([
            self.b[self.p],
            self.b[self.p + 1],
            self.b[self.p + 2],
            self.b[self.p + 3],
        ]);
        self.p += 4;
        Ok(v)
    }
    /// Next 2-bit op code, LSB-first, refilling the 32-bit mask from the stream.
    #[inline]
    fn op(&mut self) -> Result<u32, Error> {
        if self.nbits == 0 {
            self.mask = self.u32()?;
            self.nbits = 32;
        }
        let c = self.mask & 3;
        self.mask >>= 2;
        self.nbits -= 2;
        Ok(c)
    }
}

#[inline]
fn copy_unit(out: &mut [u32], pos: usize, dist: usize) -> Result<(), Error> {
    if dist == 0 || dist > pos {
        return Err(Error::BadDistance { dist, available: pos });
    }
    out[pos] = out[pos - dist];
    Ok(())
}

/// Decompress a DXV3 `DXT1` payload into `n_units` little-endian u32 units
/// (`n_units = blocks_wide * blocks_high * 2`). Returns the raw BC1 byte stream.
///
/// VERIFIED byte-exact against ffmpeg's decoder on every probe in `probes/`.
pub fn decompress_dxt1(payload: &[u8], n_units: usize) -> Result<Vec<u8>, Error> {
    let units = decompress_units(payload, n_units, 2)?;
    Ok(units_to_bytes(&units))
}

/// DXV3 `DXT5` / `YCG6` / `YG10` — **INCOMPLETE, deliberately refuses.**
///
/// ffmpeg calls this scheme `DXTR5` (its own trace output: "DXTR5 compression with
/// DXT5 texture"), and it is a genuinely different codepath from the DXT1 one above —
/// not a reparameterisation of it. Everything below was measured against real
/// Resolume assets plus crafted payloads fed to ffmpeg's decoder; enough is known to
/// finish it, but not enough to decode a real frame, so this returns an error rather
/// than plausible-looking wrong pixels.
///
/// ## Verified
/// * Texture layout is ordinary BC3: 16-byte blocks, 8 B alpha + 8 B BC1-style
///   colour. RAW mode (compression flag != 0) decodes correctly — see `bc3.rs`.
/// * The payload opens with a **16-byte unconditional literal** = block 0. Proved by
///   byte mutation on a real frame: byte 0 moves the alpha of pixel 0, bytes 8..12
///   move its RGB.
/// * Flag bits are read exactly like DXT1: 32-bit LE mask words pulled lazily from
///   the stream, consumed LSB-first, two bits per op.
/// * Op granularity is the **8-byte half-block**, and the code table is
///   **position-dependent**: a different table applies when the output cursor is
///   block-aligned ("alpha half") versus mid-block ("colour half"). A single table
///   cannot explain the measurements — e.g. code `11` consumes 8 bytes at a
///   block-aligned cursor and 2 bytes one op later.
/// * Distances are the DXT1 formulas scaled to 8-byte units, in u32 units:
///   `SHORT = 4*b + 8`, `LONG = 4*(v + 256) + 8`. Confirmed by sweeping b and v.
/// * Block-aligned `00` = RUN. Reads a 0xFF-continuation varint N (each 0xFF adds
///   255, first byte < 0xFF terminates) and copies **N+1 whole blocks** from 16 bytes
///   back. Confirmed with marker literals for N = 0,1,2,3,5,10: the next literal
///   lands at block N+2 every time. This is what makes a 37-byte 4K frame possible.
/// * Block-aligned `11` = LITERAL, 8 bytes (the alpha half). Confirmed by encoding a
///   chosen alpha sequence and reading it back out of ffmpeg unchanged.
/// * Mid-block `01` = COPY, 8 bytes from 16 bytes back. Same round-trip proof.
/// * Mid-block `10` = SHORT match. Mid-block `00` and `11` both behave as LONG
///   matches with identical distances — they must differ in some way (emit count or a
///   trailing run length) that an out-of-range-distance probe cannot reveal.
///
/// ## Not resolved
/// * Block-aligned codes `01` and `10`.
/// * What separates mid-block `00` from mid-block `11`.
/// * Consequently no end-to-end decode: the best partial model consumed 316 of
///   106,242 bytes of a real frame before desyncing.
/// * `YG10` additionally carries a 16-byte header of four u32s before the stream
///   (observed `618, 69, 69, 0` on a 761-byte frame) that `DXT5` does not have.
///   Probably sub-stream sizes for the Y/Co/Cg/A planes. Unanalysed.
///
/// The probing tools that produced all of the above are in `tools/` — `d5.py` is the
/// readable 64x64 DXT5 harness, `mutate.py` does byte-mutation mapping against real
/// files, and ffmpeg must be run at `-v trace` for DXT5 (its `idx N > M` diagnostic
/// is suppressed at `-v error`, which is what hid the oracle at first).
pub fn decompress_dxt5(_payload: &[u8], _n_units: usize) -> Result<Vec<u8>, Error> {
    Err(Error::NotDerived)
}

/// The verified DXT1 op loop, generalised over units-per-block. Exposed so the DXT5
/// work can be picked up without re-deriving the DXT1 half. `units_per_block == 2`
/// is the verified path; anything else is a guess.
pub fn decompress_block_stream(
    payload: &[u8],
    n_units: usize,
    units_per_block: usize,
) -> Result<Vec<u8>, Error> {
    let units = decompress_units(payload, n_units, units_per_block)?;
    Ok(units_to_bytes(&units))
}

fn units_to_bytes(units: &[u32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(units.len() * 4);
    for u in units {
        out.extend_from_slice(&u.to_le_bytes());
    }
    out
}

/// Core loop. `upb` = units per block (2 for BC1, 4 for BC3-shaped).
///
/// For `upb == 2` every rule here is measured. For `upb == 4` the distance scaling
/// (`2*b + 4` -> `upb*b + 2*upb`) is a hypothesis; see `decompress_dxt5`.
fn decompress_units(payload: &[u8], n_units: usize, upb: usize) -> Result<Vec<u32>, Error> {
    if payload.len() < upb * 4 {
        return Err(Error::ShortPayload);
    }
    // Output is zero-initialised; this is load-bearing, not just hygiene.
    let mut out = vec![0u32; n_units];
    let mut r = Reader::new(payload);

    // Block 0 is an unconditional literal, costing no flag bits.
    let seed = upb.min(n_units);
    for i in 0..seed {
        out[i] = r.u32()?;
    }
    let mut pos = seed;

    // Explicit distances are measured in units and are always a multiple of `upb`,
    // so a reference always lands on the same word-of-block as the destination.
    let step = upb;
    let base = 2 * upb; // smallest explicit distance: two blocks back

    while pos < n_units {
        let dist = match r.op()? {
            OP_COPY => step,
            OP_SHORT => step * r.u8()? as usize + base,
            OP_LONG => step * (r.u16()? as usize + 256) + base,
            _ => {
                // SPLIT: one sub-op per unit of the block.
                for _ in 0..upb {
                    if pos >= n_units {
                        break;
                    }
                    match r.op()? {
                        OP_COPY => copy_unit(&mut out, pos, step)?,
                        OP_SHORT => {
                            let d = step * r.u8()? as usize + base;
                            copy_unit(&mut out, pos, d)?
                        }
                        OP_LONG => {
                            let d = step * (r.u16()? as usize + 256) + base;
                            copy_unit(&mut out, pos, d)?
                        }
                        _ => out[pos] = r.u32()?,
                    }
                    pos += 1;
                }
                continue;
            }
        };
        if dist > pos {
            return Err(Error::BadDistance { dist, available: pos });
        }
        // LZ-style forward copy, unit by unit, so overlapping sources work.
        for _ in 0..upb {
            if pos >= n_units {
                break;
            }
            out[pos] = out[pos - dist];
            pos += 1;
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Frame-level helpers

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    Dxt1,
    Dxt5,
    Ycg6,
    Yg10,
}

impl Tag {
    pub fn units_per_block(self) -> usize {
        match self {
            Tag::Dxt1 => 2,
            _ => 4,
        }
    }
    pub fn bytes_per_block(self) -> usize {
        self.units_per_block() * 4
    }
}

#[derive(Debug, Clone)]
pub struct Frame<'a> {
    pub tag: Tag,
    pub version_major: u8,
    pub version_minor: u8,
    /// NONZERO means the payload is raw (uncompressed) texture data.
    pub raw: bool,
    pub payload: &'a [u8],
}

pub fn parse_frame(buf: &[u8]) -> Result<(Frame<'_>, usize), Error> {
    if buf.len() < 12 {
        return Err(Error::ShortPayload);
    }
    // On disk the four-cc is byte-reversed.
    let mut fourcc = [buf[3], buf[2], buf[1], buf[0]];
    let tag = match &fourcc {
        b"DXT1" => Tag::Dxt1,
        b"DXT5" => Tag::Dxt5,
        b"YCG6" => Tag::Ycg6,
        b"YG10" => Tag::Yg10,
        _ => {
            fourcc = [buf[0], buf[1], buf[2], buf[3]];
            return Err(Error::UnsupportedTag(fourcc));
        }
    };
    let size = u32::from_le_bytes([buf[8], buf[9], buf[10], buf[11]]) as usize;
    if 12 + size > buf.len() {
        return Err(Error::Truncated);
    }
    Ok((
        Frame {
            tag,
            version_major: buf[4],
            version_minor: buf[5],
            raw: buf[6] != 0,
            payload: &buf[12..12 + size],
        },
        12 + size,
    ))
}

#[inline]
pub fn align(v: usize, a: usize) -> usize {
    v.div_ceil(a) * a
}

/// Padded texture dimensions for a frame of `w x h`.
pub fn texture_dims(w: usize, h: usize) -> (usize, usize) {
    (align(w, 16), align(h, 4))
}

/// Decompress a parsed frame to its raw block-compressed texture bytes.
pub fn decode_texture(frame: &Frame<'_>, w: usize, h: usize) -> Result<Vec<u8>, Error> {
    let (tw, th) = texture_dims(w, h);
    let n_units = (tw / 4) * (th / 4) * frame.tag.units_per_block();
    if frame.raw {
        let need = n_units * 4;
        if frame.payload.len() < need {
            return Err(Error::Truncated);
        }
        return Ok(frame.payload[..need].to_vec());
    }
    match frame.tag {
        Tag::Dxt1 => decompress_dxt1(frame.payload, n_units),
        _ => Err(Error::NotDerived),
    }
}
