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
//! So decode parallelism for DXV exists only *across layers*, never within a
//! frame. At the 4–12 layer tiers that is fine (each layer is an independent
//! work item), but it means a single large DXV layer cannot be split, and the
//! scheduler must not assume otherwise.
//!
//! ## Decompression — derived, and deliberately **here** rather than shell-side
//!
//! The compression is a **DXV-specific LZ variant**: a stock LZF decoder fed a
//! real DXV3 payload returns `InvalidData`, and FFmpeg implements its own
//! `dxv_decompress_*` routines rather than calling a generic LZF. It has now
//! been derived clean-room from observed I/O and lives in
//! [`decompress_dxt1`] / [`decompress_dxt5`].
//!
//! FFmpeg's DXV decoder outputs **RGBA**, CPU-decoded, which throws away the one
//! property that makes DXV worth playing — the frames are *already* GPU
//! block-compressed. So linking FFmpeg is not a solution for the playback path.
//! What we do instead is undo only the LZ layer and hand the BC1/BC3 blocks
//! straight to a compressed GPU texture.
//!
//! ### ⚠️ Premultiplied alpha (DXT5 only)
//!
//! DXV stores RGB **premultiplied by alpha**. Recovering ordinary RGBA is
//! `out = min(255, c * 255 / a)`, with `c` passed through unchanged when
//! `a == 0`. That undo cannot happen here — the blocks are never expanded to
//! pixels on this side — so the **sampler must do it**. Skip it and every real
//! Resolume DXT5 asset renders visibly dark. See [`unpremultiply`], which is the
//! reference the shader is checked against.
//!
//! ### Not derived
//!
//! `YCG6` / `YG10` are a genuinely different scheme — FFmpeg names them
//! `YOCOCG6` and `YAOCOCG10` against `DXTR5` for DXT5, and both carry a 16-byte
//! four-`u32` header that DXT5 does not. Feeding the bytes after that header to
//! [`decompress_dxt5`] desyncs within ~30 bytes on every frame tried, so "same
//! scheme plus a header" is ruled out, not merely untested. They return
//! [`CodecError::NotDerived`] rather than a guess.
//!
//! ### Padding
//!
//! Measured on ffmpeg-produced files: `texture_w = align(frame_w, 16)`,
//! `texture_h = align(frame_h, 4)`. The visible frame is the top-left crop, so
//! the shell must sample `width/texture_width` of the texture, not all of it.

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
    /// friends). Ours are [`decompress_dxt1`] and [`decompress_dxt5`], derived
    /// clean-room and verified byte-exact against FFmpeg. `YCG6`/`YG10` carry
    /// this flag too but use a different scheme and are still
    /// [`CodecError::NotDerived`].
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

// ───────────────────────────── decompression ────────────────────────────────
//
// Clean-room, derived from observed I/O behaviour only. Verified byte-exact
// against FFmpeg's own decoder on 52,407 frames across 147 real Resolume files
// at 1080p and 4K, zero mismatches.
//
// # Stream shape, common to both schemes
//
// Output is a sequence of 4-byte little-endian **units**, zero-initialised —
// that is load-bearing, not hygiene: unwritten blocks must decode as zero.
// Flag bits arrive as 32-bit LE **mask words** pulled from the stream *lazily*,
// whenever the op loop needs bits and the current word is spent, which is why
// mask words sit interleaved with the literal and offset bytes rather than in a
// header. Bits are consumed LSB-first, two at a time.
//
// The encoder may emit a trailing mask word that is never consumed — stop as
// soon as the output is full, do not treat the leftover as an error.

/// Largest texture edge we will allocate for, in pixels.
///
/// A corrupt header can claim any dimensions. 16384 is the largest 2-D texture
/// current GPUs accept, so anything past it could never be displayed; honouring
/// it would be a memory-exhaustion bug wearing a decode's clothes.
const MAX_EDGE: u32 = 16_384;

/// Padded texture dimensions for a visible frame of `width` x `height`.
///
/// Measured on ffmpeg-produced files: width aligns to 16, height to 4. The
/// visible frame is the **top-left crop** of the result, so a sampler must
/// scale by `width / texture_width`, not assume they are equal.
#[must_use]
pub const fn texture_dims(width: u32, height: u32) -> (u32, u32) {
    (
        width.div_ceil(16).saturating_mul(16),
        height.div_ceil(4).saturating_mul(4),
    )
}

/// Un-premultiplies one colour channel against alpha.
///
/// DXV stores RGB premultiplied. This is the exact operation FFmpeg's DXV path
/// performs, including the `a == 0` pass-through, and it is reproduced here as
/// the **reference the GPU sampler is checked against** — the blocks themselves
/// are never expanded to pixels on this side of the boundary.
#[must_use]
pub const fn unpremultiply(c: u8, a: u8) -> u8 {
    if a == 0 {
        c
    } else {
        let v = (c as u32 * 255) / a as u32;
        if v > 255 {
            255
        } else {
            v as u8
        }
    }
}

/// Bit-and-byte reader over a DXV payload.
///
/// Every accessor is bounds-checked and returns [`CodecError::Truncated`] with
/// the real figures rather than panicking. This reads files off the internet.
struct Reader<'a> {
    b: &'a [u8],
    p: usize,
    mask: u32,
    nbits: u32,
}

impl<'a> Reader<'a> {
    const fn new(b: &'a [u8]) -> Self {
        Self {
            b,
            p: 0,
            mask: 0,
            nbits: 0,
        }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], CodecError> {
        let end = self.p.checked_add(n).ok_or(CodecError::Truncated {
            need: usize::MAX,
            got: self.b.len(),
        })?;
        let s = self.b.get(self.p..end).ok_or(CodecError::Truncated {
            need: end,
            got: self.b.len(),
        })?;
        self.p = end;
        Ok(s)
    }

    fn u8(&mut self) -> Result<u32, CodecError> {
        Ok(u32::from(self.take(1)?[0]))
    }

    fn u16(&mut self) -> Result<u32, CodecError> {
        let s = self.take(2)?;
        Ok(u32::from(u16::from_le_bytes([s[0], s[1]])))
    }

    fn u32(&mut self) -> Result<u32, CodecError> {
        let s = self.take(4)?;
        Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }

    /// DXT5 length code: a `u8`, and if that is `0xFF` keep **adding** `u16`s
    /// while each is `0xFFFF`.
    ///
    /// Provenance: the first op of `6 Surreal Creatures 4K_DXV.mov` frame 0 is
    /// `ff ff ff ff ff ff ff 28 c7` = 255 + 0xFFFF*3 + 0xC728 = 247,844, and
    /// FFmpeg's first non-transparent block in that frame is exactly
    /// 247,846 = 1 + 247,844 + 1. The simpler "each 0xFF adds 255" reading
    /// gives 1,825 and desyncs immediately.
    fn varint(&mut self) -> Result<usize, CodecError> {
        let mut n = self.u8()? as usize;
        if n == 0xFF {
            loop {
                let w = self.u16()? as usize;
                // Each iteration consumes 2 bytes, so the payload length bounds
                // the loop; no overflow guard beyond usize is reachable.
                n += w;
                if w != 0xFFFF {
                    break;
                }
            }
        }
        Ok(n)
    }

    /// Next 2-bit op code, LSB-first, refilling the 32-bit mask from the stream.
    fn op(&mut self) -> Result<u32, CodecError> {
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

/// Writes one unit, bounds-checked.
fn put(out: &mut [u32], pos: usize, v: u32) -> Result<(), CodecError> {
    *out.get_mut(pos)
        .ok_or(CodecError::Malformed("write past end of texture"))? = v;
    Ok(())
}

/// Copies one unit from `dist` units back, bounds-checked both ends.
fn copy_unit(out: &mut [u32], pos: usize, dist: usize) -> Result<(), CodecError> {
    if dist == 0 || dist > pos {
        return Err(CodecError::BadDistance {
            dist,
            available: pos,
        });
    }
    let v = out[pos - dist];
    put(out, pos, v)
}

/// Copies the two units of one half-block from `dist` units back.
fn copy_half(out: &mut [u32], base: usize, dist: usize) -> Result<(), CodecError> {
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

/// Decompresses a DXV `DXT1` payload into `n_units` units of BC1 blocks.
///
/// A BC1 block is 2 units: `[colour-pair word][index word]`. Even units are
/// colour words, odd units index words; every expressible distance is even, so
/// a back-reference never crosses between the two.
///
/// | code | op | extra | effect |
/// |---|---|---|---|
/// | `01` | COPY  | —          | 2 units from distance 2 units (previous block) |
/// | `10` | SHORT | `u8 b`     | 2 units from distance `2b + 4` |
/// | `11` | LONG  | `u16 v`    | 2 units from distance `2(v + 256) + 4` |
/// | `00` | SPLIT | —          | two sub-ops, one per unit |
///
/// SPLIT sub-ops use the same alphabet on a single unit, with `00` meaning a
/// 4-byte literal. The first 8 bytes of the payload are an unconditional
/// literal (block 0) costing no flag bits; the op loop starts at unit 2.
///
/// The minimum explicit distance is 4 units because distance 2 is already free
/// via COPY.
///
/// # Errors
/// [`CodecError::Truncated`] if the payload ends mid-op,
/// [`CodecError::BadDistance`] if a back-reference points before the start of
/// what has been decoded.
pub fn decompress_dxt1(payload: &[u8], n_units: usize) -> Result<Vec<u8>, CodecError> {
    Ok(units_to_bytes(&decompress_units(payload, n_units, 2)?))
}

/// Decompresses a DXV `DXT5` payload into `n_units` units of BC3 blocks.
///
/// FFmpeg calls this scheme `DXTR5`. It is **not** [`decompress_dxt1`] with a
/// bigger block — it is a genuinely different code table.
///
/// # Two planes, one flag stream
///
/// A BC3 block is `[8 B alpha half][8 B colour half]`, and the compressor
/// treats those as two independent LZ planes with their own block cursors —
/// `ap` for alpha, `cp` for colour. Before every op the decoder picks
/// **whichever plane is behind**, alpha winning ties. They alternate A,C,A,C…
/// in the common case, but an alpha run can push `ap` far ahead, after which a
/// long stretch of colour ops runs back to back. A single position-dependent
/// table appeared to contradict itself for exactly this reason: the "position"
/// is not the output cursor's parity, it is which plane is currently behind.
///
/// Distances are in units over the **whole interleaved texture**, so a plane's
/// back-reference always lands on the same half of an earlier block.
///
/// The payload opens with a 16-byte unconditional literal — block 0, both
/// halves — after which `ap = cp = 1`.
///
/// Alpha-plane ops, writing the alpha half of block `ap`:
///
/// | code | op | extra | effect |
/// |---|---|---|---|
/// | `00` | BLOCK RUN | varint `n` | `n+1` whole blocks from 1 block back; advances **both** cursors |
/// | `01` | ALPHA RUN | varint `n` | `n+1` alpha halves from 1 block back; advances `ap` |
/// | `10` | MATCH     | `u16 v`    | one alpha half from distance `4v + 8` |
/// | `11` | LITERAL   | 8 bytes    | one alpha half verbatim |
///
/// Note the alpha plane has no short/long split — one match op with a full
/// `u16` distance. Reading it as a 1-byte op is the trap: every synthetic probe
/// happened to have a zero second byte, and the two readings diverge only on
/// real data.
///
/// Colour-plane ops, writing the colour half of block `cp`, match
/// [`decompress_dxt1`]'s alphabet with distances scaled to 4-unit blocks:
/// `00` SPLIT (two sub-ops), `01` COPY, `10` SHORT `4b + 8`,
/// `11` LONG `4(v + 256) + 8`; SPLIT sub-op `00` is a 4-byte literal.
///
/// # Errors
/// [`CodecError::Truncated`] on a short payload, [`CodecError::Malformed`] if
/// `n_units` is not a whole number of 4-unit blocks, [`CodecError::BadDistance`]
/// on an out-of-range back-reference.
pub fn decompress_dxt5(payload: &[u8], n_units: usize) -> Result<Vec<u8>, CodecError> {
    if payload.len() < 16 {
        return Err(CodecError::Truncated {
            need: 16,
            got: payload.len(),
        });
    }
    // A BC3 block is exactly 4 units; a non-multiple would leave a partial
    // block the plane cursors cannot address, so refuse rather than zero-fill.
    if n_units < 4 || !n_units.is_multiple_of(4) {
        return Err(CodecError::Malformed(
            "BC3 texture is not a whole number of 4-unit blocks",
        ));
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
                    // Whole-block run: advances both planes.
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
                    let (lo, hi) = (r.u32()?, r.u32()?);
                    put(&mut out, ap * 4, lo)?;
                    put(&mut out, ap * 4 + 1, hi)?;
                    ap += 1;
                }
            }
        } else {
            let base = cp * 4 + 2;
            match c {
                0 => {
                    for k in 0..2 {
                        match r.op()? {
                            0 => {
                                let v = r.u32()?;
                                put(&mut out, base + k, v)?;
                            }
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

/// Core DXT1 loop. `upb` = units per block, always 2.
///
/// The parameter once carried a candidate `upb == 4` DXT5 path. **That
/// hypothesis is disproven** — see [`decompress_dxt5`]. It is kept only because
/// it names the invariant the distance formulas rest on.
fn decompress_units(payload: &[u8], n_units: usize, upb: usize) -> Result<Vec<u32>, CodecError> {
    if payload.len() < upb * 4 {
        return Err(CodecError::Truncated {
            need: upb * 4,
            got: payload.len(),
        });
    }
    let mut out = vec![0u32; n_units];
    let mut r = Reader::new(payload);

    // Block 0 is an unconditional literal, costing no flag bits.
    let seed = upb.min(n_units);
    for i in 0..seed {
        let v = r.u32()?;
        put(&mut out, i, v)?;
    }
    let mut pos = seed;

    // Explicit distances are measured in units and are always a multiple of
    // `upb`, so a reference always lands on the same word-of-block.
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
                            copy_unit(&mut out, pos, d)?;
                        }
                        OP_LONG => {
                            let d = step * (r.u16()? as usize + 256) + base;
                            copy_unit(&mut out, pos, d)?;
                        }
                        _ => {
                            let v = r.u32()?;
                            put(&mut out, pos, v)?;
                        }
                    }
                    pos += 1;
                }
                continue;
            }
        };
        if dist > pos {
            return Err(CodecError::BadDistance {
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

// Op codes for the colour-plane alphabet. `0b00` is SPLIT and falls out of the
// `_` arm in both loops, so it is spelled there rather than named here.
const OP_COPY: u32 = 0b01;
const OP_SHORT: u32 = 0b10;
const OP_LONG: u32 = 0b11;

/// Decodes a parsed frame to its **block-compressed** texture bytes.
///
/// `buf` is the frame buffer [`parse_frame`] was given; the payload is sliced
/// out of it using the frame's own offsets. `width`/`height` are the visible
/// frame size — the returned texture is the padded size from [`texture_dims`].
///
/// The output is BC1 or BC3 blocks ready for a compressed GPU texture. It is
/// **never** expanded to RGBA: doing that is exactly what throws away DXV's
/// advantage.
///
/// # Errors
/// - [`CodecError::Malformed`] if the dimensions are zero or absurd.
/// - [`CodecError::Truncated`] if the payload is shorter than the frame claims.
/// - [`CodecError::BadDistance`] if the LZ stream is corrupt.
/// - [`CodecError::NotDerived`] for `YCG6`/`YG10`, which are a different scheme.
pub fn decode_texture(
    frame: &Frame,
    buf: &[u8],
    width: u32,
    height: u32,
) -> Result<Vec<u8>, CodecError> {
    if width == 0 || height == 0 || width > MAX_EDGE || height > MAX_EDGE {
        return Err(CodecError::Malformed("frame dimensions out of range"));
    }
    let (tw, th) = texture_dims(width, height);
    let n_units = usize::try_from(frame.format.frame_bytes(tw, th) / 4)
        .map_err(|_| CodecError::Malformed("texture larger than this machine's address space"))?;

    let end = frame
        .payload_offset
        .checked_add(frame.payload_len)
        .ok_or(CodecError::Malformed("payload offset overflows"))?;
    let payload = buf.get(frame.payload_offset..end).ok_or(CodecError::Truncated {
        need: end,
        got: buf.len(),
    })?;

    if frame.compression == Compression::Raw {
        let need = n_units * 4;
        if payload.len() < need {
            return Err(CodecError::Truncated {
                need,
                got: payload.len(),
            });
        }
        return Ok(payload[..need].to_vec());
    }

    // DXV1/DXV2 predate the scheme below. Their payloads will happily start
    // decoding and then run off a back-reference a few units in, so refusing up
    // front is the difference between "this clip needs re-encoding" and a
    // puzzling corruption error. Three files in a real 99-clip library were
    // DXV1 (`DXDI`); they are unverified, so they are not attempted.
    if frame.version < 3 {
        return Err(CodecError::NotDerived);
    }

    match frame.format {
        TextureFormat::Bc1Rgb => decompress_dxt1(payload, n_units),
        TextureFormat::Bc3Rgba => decompress_dxt5(payload, n_units),
        // YCG6 / YG10. Returned rather than guessed — plausible-looking wrong
        // pixels in a live show are worse than a clip that refuses to load.
        _ => Err(CodecError::NotDerived),
    }
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

    // ───────────────────────── decompression ────────────────────────────
    //
    // The byte-exactness of the full scheme is established against FFmpeg on
    // real files by `photon-ffi`'s `dxv_verify` tool — 56 of Aiden's Resolume
    // clips, every frame identical. What these tests pin is the *op table*,
    // one op at a time, so a regression names which op broke instead of
    // reporting "a 4K frame differs".

    const U0: u32 = 0x1111_1111;
    const U1: u32 = 0x2222_2222;

    /// An 8-byte DXT1 seed literal: block 0 as units `U0`, `U1`.
    fn dxt1_seed() -> Vec<u8> {
        let mut v = U0.to_le_bytes().to_vec();
        v.extend_from_slice(&U1.to_le_bytes());
        v
    }

    fn units(bytes: &[u8]) -> Vec<u32> {
        bytes
            .chunks_exact(4)
            .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect()
    }

    #[test]
    fn dxt1_seed_block_is_an_unconditional_literal() {
        // Block 0 costs no flag bits. If it ever did, every stream would be
        // off by two bits and nothing would decode.
        let out = decompress_dxt1(&dxt1_seed(), 2).unwrap();
        assert_eq!(units(&out), vec![U0, U1]);
    }

    #[test]
    fn dxt1_copy_repeats_the_previous_block() {
        let mut p = dxt1_seed();
        p.extend_from_slice(&0b01u32.to_le_bytes()); // one COPY, rest unused
        assert_eq!(units(&decompress_dxt1(&p, 4).unwrap()), vec![U0, U1, U0, U1]);
    }

    #[test]
    fn dxt1_split_codes_the_two_units_independently() {
        // op SPLIT(00), sub LITERAL(00), sub COPY(01) — consumed LSB-first, so
        // the mask word reads 0b01_00_00.
        let mut p = dxt1_seed();
        p.extend_from_slice(&0b01_00_00u32.to_le_bytes());
        p.extend_from_slice(&0xDEAD_BEEFu32.to_le_bytes());
        assert_eq!(
            units(&decompress_dxt1(&p, 4).unwrap()),
            vec![U0, U1, 0xDEAD_BEEF, U1],
            "the literal must land on the colour word and the copy on the index word"
        );
    }

    #[test]
    fn dxt1_short_distance_is_two_units_per_step_from_a_four_unit_base() {
        // SHORT(10) with b = 0 means distance 4 — two blocks back, which is the
        // smallest distance that is not already free via COPY.
        // ops COPY(01) then SHORT(10), consumed LSB-first -> mask 0b10_01.
        let mut p = dxt1_seed();
        p.extend_from_slice(&0b10_01u32.to_le_bytes());
        p.push(0); // SHORT's b
        assert_eq!(
            units(&decompress_dxt1(&p, 6).unwrap()),
            vec![U0, U1, U0, U1, U0, U1]
        );
    }

    #[test]
    fn dxt1_back_reference_past_the_start_is_an_error_not_a_panic() {
        // LONG(11) with v = 0 asks for distance 2*(0+256)+4 = 516 units, with
        // only 2 decoded. A corrupt file must say so, never crash a show.
        let mut p = dxt1_seed();
        p.extend_from_slice(&0b11u32.to_le_bytes());
        p.extend_from_slice(&[0, 0]);
        assert!(matches!(
            decompress_dxt1(&p, 4),
            Err(CodecError::BadDistance {
                dist: 516,
                available: 2
            })
        ));
    }

    #[test]
    fn dxt1_payload_ending_mid_op_is_truncated() {
        let mut p = dxt1_seed();
        p.extend_from_slice(&0b11u32.to_le_bytes()); // LONG, but its u16 is missing
        assert!(matches!(
            decompress_dxt1(&p, 4),
            Err(CodecError::Truncated { .. })
        ));
        assert!(matches!(
            decompress_dxt1(&[0, 0, 0], 4),
            Err(CodecError::Truncated { need: 8, got: 3 })
        ));
    }

    #[test]
    fn dxt5_alternates_between_the_alpha_and_colour_planes() {
        // 16-byte seed = block 0, both halves. Then ALPHA RUN(01) with a varint
        // of 0 (one half), then colour COPY(01). Mask reads 0b01_01.
        let mut p: Vec<u8> = Vec::new();
        for u in [0xAAAA_AAAAu32, 0xBBBB_BBBB, 0xCCCC_CCCC, 0xDDDD_DDDD] {
            p.extend_from_slice(&u.to_le_bytes());
        }
        p.extend_from_slice(&0b01_01u32.to_le_bytes());
        p.push(0); // ALPHA RUN length
        let out = units(&decompress_dxt5(&p, 8).unwrap());
        assert_eq!(
            out,
            vec![
                0xAAAA_AAAA,
                0xBBBB_BBBB,
                0xCCCC_CCCC,
                0xDDDD_DDDD,
                0xAAAA_AAAA,
                0xBBBB_BBBB,
                0xCCCC_CCCC,
                0xDDDD_DDDD
            ],
            "alpha half then colour half, each from one block back"
        );
    }

    #[test]
    fn dxt5_refuses_a_texture_that_is_not_whole_blocks() {
        // A partial block is unaddressable by the plane cursors, so zero-filling
        // it would be inventing pixels.
        let p = vec![0u8; 32];
        assert!(matches!(
            decompress_dxt5(&p, 6),
            Err(CodecError::Malformed(_))
        ));
        assert!(matches!(
            decompress_dxt5(&[0; 4], 8),
            Err(CodecError::Truncated { need: 16, got: 4 })
        ));
    }

    #[test]
    fn texture_is_padded_to_16_wide_and_4_high() {
        assert_eq!(texture_dims(1920, 1080), (1920, 1080));
        assert_eq!(texture_dims(1366, 768), (1376, 768));
        assert_eq!(texture_dims(1, 1), (16, 4));
    }

    #[test]
    fn premultiplied_colour_is_divided_back_out() {
        // The exact operation the sampler performs. Without it every real
        // Resolume DXT5 asset renders visibly dark.
        assert_eq!(unpremultiply(128, 255), 128);
        assert_eq!(unpremultiply(64, 128), 127);
        assert_eq!(unpremultiply(200, 100), 255, "clamps rather than wrapping");
        assert_eq!(unpremultiply(37, 0), 37, "a == 0 passes the colour through");
    }

    #[test]
    fn raw_frames_skip_the_lz_pass_entirely() {
        let mut h = REAL_DXV3_HEADER;
        h[6] = 1; // raw
        // 16x4 visible -> 4x1 blocks -> 32 bytes of BC1.
        let buf = frame_with_payload(h, 32);
        let f = parse_frame(&buf).unwrap();
        let tex = decode_texture(&f, &buf, 16, 4).unwrap();
        assert_eq!(tex.len(), 32);
    }

    #[test]
    fn ycocg_variants_refuse_rather_than_guess() {
        // Plausible-looking wrong pixels in a live show are worse than a clip
        // that will not load and says why.
        for tag in [b"YCG6", b"YG10"] {
            let mut h = REAL_DXV3_HEADER;
            let mut rev = *tag;
            rev.reverse();
            h[..4].copy_from_slice(&rev);
            let buf = frame_with_payload(h, 4096);
            let f = parse_frame(&buf).unwrap();
            assert!(matches!(
                decode_texture(&f, &buf, 64, 64),
                Err(CodecError::NotDerived)
            ));
        }
    }

    #[test]
    fn dxv1_refuses_rather_than_decoding_the_wrong_scheme() {
        // Legacy packed header, compressed. Three files in a real 99-clip
        // library were DXV1; the scheme predates the derived one and would
        // decode a few units then fail confusingly.
        // High byte 0 = flags clear: compressed, and BC1 rather than BC3.
        let packed: u32 = 256;
        let mut v = packed.to_le_bytes().to_vec();
        v.extend(std::iter::repeat_n(0u8, 256));
        let f = parse_frame(&v).unwrap();
        assert_eq!(f.version, 1);
        assert!(matches!(
            decode_texture(&f, &v, 64, 64),
            Err(CodecError::NotDerived)
        ));
    }

    #[test]
    fn absurd_dimensions_are_refused_before_allocating() {
        let buf = frame_with_payload(REAL_DXV3_HEADER, 64);
        let f = parse_frame(&buf).unwrap();
        for (w, h) in [(0, 1080), (1920, 0), (100_000, 1080), (1920, 100_000)] {
            assert!(matches!(
                decode_texture(&f, &buf, w, h),
                Err(CodecError::Malformed(_))
            ));
        }
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        // This decodes files from the internet. Every path must return.
        let mut seed = 0x2545_F491_4F6C_DD1Du64;
        for _ in 0..2000 {
            let mut buf = Vec::with_capacity(96);
            for _ in 0..96 {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                buf.push((seed >> 24) as u8);
            }
            if let Ok(f) = parse_frame(&buf) {
                let _ = decode_texture(&f, &buf, 64, 16);
            }
            let _ = decompress_dxt1(&buf, 32);
            let _ = decompress_dxt5(&buf, 32);
        }
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
