//! BC3 (DXT5) -> RGBA8 for Resolume DXV, matching ffmpeg's decoder bit-for-bit.
//!
//! Two things make this different from a textbook BC3 decode, both measured against
//! ffmpeg via DXV RAW mode (compression flag != 0) and verified on 200 random blocks:
//!
//! 1. The 565 -> 888 expansion is the same non-standard table as the DXT1 path
//!    (see `bc1::EXP5` / `bc1::EXP6`), not bit replication.
//! 2. **DXV stores premultiplied RGB.** The decoder divides the colour back out by
//!    alpha: `out = min(255, c * 255 / a)`, and passes `c` through unchanged when
//!    `a == 0`. Skipping this step gives a visibly dark, wrong image on every real
//!    Resolume DXT5 asset.
//!
//! Block layout is ordinary BC3: 8 bytes alpha (a0, a1, then 16 x 3-bit indices,
//! little-endian 48-bit field) followed by 8 bytes of BC1-style colour.

use crate::bc1::{EXP5, EXP6};

#[inline]
fn expand(c: u16) -> [u8; 3] {
    [
        EXP5[((c >> 11) & 0x1F) as usize],
        EXP6[((c >> 5) & 0x3F) as usize],
        EXP5[(c & 0x1F) as usize],
    ]
}

/// The eight alpha levels for a BC3 alpha pair.
#[inline]
pub fn alpha_table(a0: u8, a1: u8) -> [u8; 8] {
    let mut t = [0u8; 8];
    t[0] = a0;
    t[1] = a1;
    let (x, y) = (a0 as u32, a1 as u32);
    if a0 > a1 {
        for i in 0..6 {
            t[2 + i] = (((6 - i as u32) * x + (1 + i as u32) * y) / 7) as u8;
        }
    } else {
        for i in 0..4 {
            t[2 + i] = (((4 - i as u32) * x + (1 + i as u32) * y) / 5) as u8;
        }
        t[6] = 0;
        t[7] = 255;
    }
    t
}

/// Un-premultiply one channel against alpha, the way ffmpeg's DXV path does.
#[inline]
pub fn unpremultiply(c: u8, a: u8) -> u8 {
    if a == 0 {
        c
    } else {
        let v = (c as u32 * 255) / a as u32;
        if v > 255 { 255 } else { v as u8 }
    }
}

/// Decode a BC3 texture of `tex_w x tex_h` and crop to the visible `w x h` RGBA frame.
pub fn to_rgba(bc3: &[u8], tex_w: usize, _tex_h: usize, w: usize, h: usize) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 4];
    let bw = tex_w / 4;
    for by in 0..h.div_ceil(4) {
        for bx in 0..w.div_ceil(4) {
            let o = (by * bw + bx) * 16;
            let at = alpha_table(bc3[o], bc3[o + 1]);
            let mut abits: u64 = 0;
            for i in 0..6 {
                abits |= (bc3[o + 2 + i] as u64) << (8 * i);
            }
            let c0 = u16::from_le_bytes([bc3[o + 8], bc3[o + 9]]);
            let c1 = u16::from_le_bytes([bc3[o + 10], bc3[o + 11]]);
            let idx = u32::from_le_bytes([bc3[o + 12], bc3[o + 13], bc3[o + 14], bc3[o + 15]]);
            let a = expand(c0);
            let b = expand(c1);
            // BC3 colour blocks ALWAYS use 4-colour interpolation - the `c0 > c1`
            // test that selects 3-colour mode is BC1-only. Measured: using the BC1
            // rule here mismatches ffmpeg on 971/4096 texels of a random block set.
            let mut pal = [[0u8; 3]; 4];
            pal[0] = a;
            pal[1] = b;
            for i in 0..3 {
                pal[2][i] = ((2 * a[i] as u32 + b[i] as u32) / 3) as u8;
                pal[3][i] = ((a[i] as u32 + 2 * b[i] as u32) / 3) as u8;
            }
            for y in 0..4 {
                let yy = by * 4 + y;
                if yy >= h {
                    break;
                }
                for x in 0..4 {
                    let xx = bx * 4 + x;
                    if xx >= w {
                        break;
                    }
                    let t = y * 4 + x;
                    let al = at[((abits >> (3 * t)) & 7) as usize];
                    let c = pal[((idx >> (2 * t)) & 3) as usize];
                    let p = (yy * w + xx) * 4;
                    out[p] = unpremultiply(c[0], al);
                    out[p + 1] = unpremultiply(c[1], al);
                    out[p + 2] = unpremultiply(c[2], al);
                    out[p + 3] = al;
                }
            }
        }
    }
    out
}
