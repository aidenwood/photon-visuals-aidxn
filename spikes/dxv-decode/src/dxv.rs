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
//! `DXT1` and `DXT5` are both derived and verified byte-exact against ffmpeg.
//! They are **two different schemes**, not one scheme with two block sizes:
//! DXT1 codes whole blocks with a SPLIT escape, DXT5 (ffmpeg calls it `DXTR5`)
//! codes two independent planes — see `decompress_dxt5`. `YCG6`/`YG10` are
//! still `NotDerived`.
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
    BadDistance {
        dist: usize,
        available: usize,
    },
    UnsupportedTag([u8; 4]),
    ShortPayload,
    /// The format for this tag has not been reverse-engineered. `YCG6`/`YG10` only;
    /// `DXT1` and `DXT5` are both derived.
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
            Error::NotDerived => write!(f, "YCoCg (YCG6/YG10) compressed layout not derived"),
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
        Reader {
            b,
            p: 0,
            mask: 0,
            nbits: 0,
        }
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
    /// DXT5 length code: `u8`, and if it is 0xFF keep adding `u16`s while each is
    /// 0xFFFF. Used by both alpha-plane run ops.
    #[inline]
    fn varint(&mut self) -> Result<usize, Error> {
        let mut n = self.u8()? as usize;
        if n == 0xff {
            loop {
                let w = self.u16()? as usize;
                n += w;
                if w != 0xffff {
                    break;
                }
            }
        }
        Ok(n)
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
        return Err(Error::BadDistance {
            dist,
            available: pos,
        });
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

/// DXV3 `DXT5` — ffmpeg calls the scheme `DXTR5` ("DXTR5 compression with DXT5
/// texture" in its own trace). **VERIFIED byte-exact against ffmpeg on real Resolume
/// assets, 1080p and 4K.**
///
/// It is a genuinely different codepath from the DXT1 one above, not a
/// reparameterisation of it. The structural insight that unlocks it:
///
/// # Two planes, one flag stream
///
/// A BC3 block is `[8 B alpha half][8 B colour half]`. The compressor treats those as
/// **two independent LZ planes**. Each has its own block cursor — `ap` for alpha,
/// `cp` for colour — and before every op the decoder picks **whichever plane is
/// behind** (alpha wins ties). They therefore alternate A,C,A,C… in the common case,
/// but an alpha-plane run can push `ap` far ahead, after which a long stretch of
/// colour ops runs back to back. That is why a single position-dependent table
/// appeared to contradict itself: the "position" is not the output cursor's parity,
/// it is which plane is currently behind.
///
/// Distances are expressed in **u32 units over the whole interleaved texture**, so a
/// plane's back-reference always lands on the same half of an earlier block.
///
/// # Stream layout
///
/// * The payload opens with a **16-byte unconditional literal** = block 0 (both
///   halves). `ap = cp = 1` after it. Proved by byte mutation on a real frame: byte 0
///   moves the alpha of pixel 0, bytes 8..12 move its RGB.
/// * Flag bits are read exactly like DXT1: 32-bit LE mask words pulled lazily from
///   the stream, consumed LSB-first, two bits per op, so mask words sit interleaved
///   with the data bytes.
/// * Output is zero-initialised.
///
/// # Length encoding (`varint`)
///
/// `n = u8; if n == 0xFF { loop { w = u16_le; n += w; if w != 0xFFFF { break } } }`.
/// Both run ops use it. Provenance: the first op of
/// `6 Surreal Creatures 4K_DXV.mov` frame 0 is `ff ff ff ff ff ff ff 28 c7` =
/// 255 + 0xFFFF*3 + 0xC728 = 247844, and ffmpeg's first non-transparent block in that
/// frame is exactly 247846 = 1 + 247844 + 1. The simpler "each 0xFF adds 255" reading
/// gives 1825 and desyncs immediately.
///
/// # Alpha-plane ops (write the 8-byte alpha half of block `ap`)
///
/// | code | op | extra bytes | effect |
/// |------|----|-------------|--------|
/// | `00` | BLOCK RUN | varint `n` | copy `n+1` **whole blocks** (all 4 units) from 1 block back; advances **both** `ap` and `cp` |
/// | `01` | ALPHA RUN | varint `n` | copy `n+1` **alpha halves** from 1 block back; advances `ap` only |
/// | `10` | MATCH     | 2 (`u16 v`) | copy one alpha half from distance `4*v + 8` units |
/// | `11` | LITERAL   | 8           | one alpha half verbatim |
///
/// Note the alpha plane has no short/long split: one match op with a full u16
/// distance. Measuring it as a 1-byte op is the trap — every lab probe happened to
/// have a zero second byte, and the two readings only diverge on real data.
///
/// # Colour-plane ops (write the 8-byte colour half of block `cp`)
///
/// | code | op | extra bytes | effect |
/// |------|----|-------------|--------|
/// | `00` | SPLIT   | —            | two sub-ops, one per u32 unit (see below) |
/// | `01` | COPY    | 0            | copy the colour half from 1 block back |
/// | `10` | SHORT   | 1 (`u8 b`)   | copy from distance `4*b + 8` units |
/// | `11` | LONG    | 2 (`u16 v`)  | copy from distance `4*(v + 256) + 8` units |
///
/// SPLIT sub-ops use the same alphabet on a **single** unit, and `00` is the literal
/// that lets a brand-new colour word enter the stream at all:
///
/// | sub | op | extra bytes | effect |
/// |-----|----|-------------|--------|
/// | `00` | LITERAL | 4           | one unit verbatim |
/// | `01` | COPY    | 0           | one unit from 1 block back |
/// | `10` | SHORT   | 1 (`u8 b`)  | one unit from `4*b + 8` |
/// | `11` | LONG    | 2 (`u16 v`) | one unit from `4*(v + 256) + 8` |
///
/// # Not derived
///
/// `YCG6` / `YG10` still return `NotDerived`, and they are **not** this scheme with a
/// header bolted on — ffmpeg names them differently in its own trace: `YOCOCG6` and
/// `YAOCOCG10`, versus `DXTR5` here. Both carry a 16-byte header of four u32s that
/// `DXT5` does not (`YCG6`: `11612, 2922, 0, 0` on a 12803-byte frame; `YG10`:
/// `10270, 2391, 2081, 0` on a 20074-byte frame), consistent with sub-stream sizes
/// for separate Y/Co/Cg(/A) planes. Feeding the bytes after that header to
/// `decompress_dxt5` desyncs within ~30 bytes on every frame tried, so the
/// "same scheme, extra header" shortcut is ruled out, not merely untested.
///
/// # Provenance
///
/// Tools in `tools/`: `d5lab.py` builds payloads op-by-op with explicit control of the
/// data byte stream, `d5trace.py` single-steps the cursor, `d5dec.py` is the reference
/// model that was scored against ffmpeg frame by frame. ffmpeg must be run at
/// `-v trace` for DXT5 — its `idx N > M` diagnostic (N = computed distance,
/// M = colour cursor) is suppressed at `-v error`, and only the colour plane prints
/// it; an out-of-range alpha reference fails silently.
///
/// The model is proven in **both** directions, not merely permissive: an encoder
/// built from this table was used to compress three synthetic 1920x1080 BC3
/// textures, chosen to exercise every op and sub-op, and ffmpeg decoded all three to
/// the intended texture with 0 of 2,073,600 texels wrong each time.
pub fn decompress_dxt5(payload: &[u8], n_units: usize) -> Result<Vec<u8>, Error> {
    // A BC3 block is exactly 4 units; a non-multiple would leave a partial block the
    // plane cursors cannot address, so refuse rather than silently zero-fill it.
    if payload.len() < 16 || n_units < 4 || n_units % 4 != 0 {
        return Err(Error::ShortPayload);
    }
    let nb = n_units / 4;
    let mut out = vec![0u32; n_units];
    let mut r = Reader::new(payload);

    for u in out.iter_mut().take(4) {
        *u = r.u32()?;
    }
    let (mut ap, mut cp) = (1usize, 1usize);

    while ap < nb || cp < nb {
        let c = r.op()?;
        if ap <= cp && ap < nb {
            match c {
                0 => {
                    // whole-block run: advances both planes
                    let n = r.varint()? + 1;
                    for _ in 0..n {
                        if ap >= nb {
                            break;
                        }
                        for k in 0..4 {
                            copy_unit(&mut out, ap * 4 + k, 4)?;
                        }
                        ap += 1;
                    }
                    if cp < ap {
                        cp = ap;
                    }
                }
                1 => {
                    let n = r.varint()? + 1;
                    for _ in 0..n {
                        if ap >= nb {
                            break;
                        }
                        copy_half(&mut out, ap * 4, 4)?;
                        ap += 1;
                    }
                }
                2 => {
                    let d = 4 * r.u16()? as usize + 8;
                    copy_half(&mut out, ap * 4, d)?;
                    ap += 1;
                }
                _ => {
                    out[ap * 4] = r.u32()?;
                    out[ap * 4 + 1] = r.u32()?;
                    ap += 1;
                }
            }
        } else {
            let base = cp * 4 + 2;
            match c {
                0 => {
                    for k in 0..2 {
                        match r.op()? {
                            0 => out[base + k] = r.u32()?,
                            1 => copy_unit(&mut out, base + k, 4)?,
                            2 => {
                                let d = 4 * r.u8()? as usize + 8;
                                copy_unit(&mut out, base + k, d)?;
                            }
                            _ => {
                                let d = 4 * (r.u16()? as usize + 256) + 8;
                                copy_unit(&mut out, base + k, d)?;
                            }
                        }
                    }
                }
                1 => copy_half(&mut out, base, 4)?,
                2 => {
                    let d = 4 * r.u8()? as usize + 8;
                    copy_half(&mut out, base, d)?;
                }
                _ => {
                    let d = 4 * (r.u16()? as usize + 256) + 8;
                    copy_half(&mut out, base, d)?;
                }
            }
            cp += 1;
        }
    }
    Ok(units_to_bytes(&out))
}

#[inline]
fn copy_half(out: &mut [u32], base: usize, dist: usize) -> Result<(), Error> {
    copy_unit(out, base, dist)?;
    copy_unit(out, base + 1, dist)
}

fn units_to_bytes(units: &[u32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(units.len() * 4);
    for u in units {
        out.extend_from_slice(&u.to_le_bytes());
    }
    out
}

/// Core DXT1 loop. `upb` = units per block, always 2 here.
///
/// It once took `upb == 4` as a candidate DXT5 path. **That hypothesis is disproven:**
/// DXT5 is not this loop with a bigger block — it is a two-plane scheme with a
/// different code table (see `decompress_dxt5`). The parameter is kept only because
/// it names the invariant the distance formulas rest on.
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
            return Err(Error::BadDistance {
                dist,
                available: pos,
            });
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
        Tag::Dxt5 => decompress_dxt5(frame.payload, n_units),
        _ => Err(Error::NotDerived),
    }
}
