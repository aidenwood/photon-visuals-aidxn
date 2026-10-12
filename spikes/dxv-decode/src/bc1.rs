//! BC1 (DXT1) -> RGBA8, matching ffmpeg's DXV decoder bit-for-bit.
//!
//! The 565 -> 888 expansion ffmpeg uses is NOT bit replication and does not fit any
//! simple `round(v * 255 / 31)` formula (it is non-monotonic against it at v = 20, 25,
//! 29). The tables below were measured by feeding RAW-mode DXV frames containing every
//! 5-bit and 6-bit level through `ffmpeg -pix_fmt rgba`.

#![allow(dead_code)] // spike: module is a reference impl, not all of it is wired to main

/// 5-bit channel expansion, measured from ffmpeg.
pub const EXP5: [u8; 32] = [
    0, 8, 16, 25, 33, 41, 49, 58, 66, 74, 82, 90, 99, 107, 115, 123, 132, 140, 148, 156, 164, 173,
    181, 189, 197, 205, 214, 222, 230, 238, 247, 255,
];

/// 6-bit channel expansion, measured from ffmpeg.
pub const EXP6: [u8; 64] = [
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 45, 49, 53, 57, 61, 65, 69, 73, 77, 81, 85, 89, 93,
    97, 101, 105, 109, 113, 117, 121, 125, 130, 134, 138, 142, 146, 150, 154, 158, 162, 166, 170,
    174, 178, 182, 186, 190, 194, 198, 202, 206, 210, 214, 219, 223, 227, 231, 235, 239, 243, 247,
    251, 255,
];

#[inline]
fn expand(c: u16) -> [u8; 3] {
    [
        EXP5[((c >> 11) & 0x1F) as usize],
        EXP6[((c >> 5) & 0x3F) as usize],
        EXP5[(c & 0x1F) as usize],
    ]
}

/// The four palette entries for a BC1 colour pair.
///
/// Interpolation runs on the expanded 8-bit values with truncating division.
/// In the `c0 <= c1` branch, index 3 is opaque black — ffmpeg's DXV DXT1 path never
/// produces transparent texels.
#[inline]
pub fn palette(c0: u16, c1: u16) -> [[u8; 4]; 4] {
    let a = expand(c0);
    let b = expand(c1);
    let mut p = [[0u8; 4]; 4];
    p[0] = [a[0], a[1], a[2], 255];
    p[1] = [b[0], b[1], b[2], 255];
    if c0 > c1 {
        for i in 0..3 {
            p[2][i] = ((2 * a[i] as u32 + b[i] as u32) / 3) as u8;
            p[3][i] = ((a[i] as u32 + 2 * b[i] as u32) / 3) as u8;
        }
    } else {
        for i in 0..3 {
            p[2][i] = ((a[i] as u32 + b[i] as u32) / 2) as u8;
            p[3][i] = 0;
        }
    }
    p[2][3] = 255;
    p[3][3] = 255;
    p
}

/// Decode a BC1 texture of `tex_w x tex_h` and crop to the visible `w x h` RGBA frame.
pub fn to_rgba(bc1: &[u8], tex_w: usize, _tex_h: usize, w: usize, h: usize) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 4];
    let bw = tex_w / 4;
    let blocks_y = h.div_ceil(4);
    let blocks_x = w.div_ceil(4);
    for by in 0..blocks_y {
        for bx in 0..blocks_x {
            let o = (by * bw + bx) * 8;
            let c0 = u16::from_le_bytes([bc1[o], bc1[o + 1]]);
            let c1 = u16::from_le_bytes([bc1[o + 2], bc1[o + 3]]);
            let idx = u32::from_le_bytes([bc1[o + 4], bc1[o + 5], bc1[o + 6], bc1[o + 7]]);
            let pal = palette(c0, c1);
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
                    let p = (yy * w + xx) * 4;
                    out[p..p + 4].copy_from_slice(&pal[((idx >> (2 * (y * 4 + x))) & 3) as usize]);
                }
            }
        }
    }
    out
}
