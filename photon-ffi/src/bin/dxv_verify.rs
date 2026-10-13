//! Verifies `photon_core::codec::dxv` against FFmpeg on real Resolume files.
//!
//! ```text
//! cargo run --release --bin dxv_verify -- <file.mov> [more.mov …]
//! cargo run --release --bin dxv_verify -- --frames 8 --list files.txt
//! ```
//!
//! ## What it proves, and what it deliberately does not
//!
//! The playback path produces **BC blocks** and uploads them compressed; it
//! never makes an RGBA pixel. FFmpeg's DXV decoder only produces RGBA. So to
//! compare the two at all, this tool expands our blocks to RGBA **here**, in a
//! reference decoder that exists for verification only and is never on the
//! playback path.
//!
//! That reference is also the specification the Metal sampler is written
//! against — in particular the un-premultiply, which the GPU has to do because
//! the CPU side never touches a pixel.
//!
//! Two things in the expansion are measured from FFmpeg rather than textbook:
//!
//! 1. The 565→888 channel expansion is **not** bit replication and does not fit
//!    `round(v * 255 / 31)` — it is non-monotonic against that at v = 20, 25,
//!    29. [`EXP5`] / [`EXP6`] were measured by pushing RAW-mode DXV frames
//!    containing every level through `ffmpeg -pix_fmt rgba`.
//! 2. BC3 colour blocks **always** use 4-colour interpolation. The `c0 > c1`
//!    test that selects 3-colour mode is BC1-only; applying it here mismatches
//!    FFmpeg on 971 of 4096 texels of a random block set.
//!
//! ## Container
//!
//! A linear walk of `mdat`, which is all a DXV MOV needs — frames are stored
//! back to back and each carries its own length. The shipping path does **not**
//! use this: it takes samples from AVFoundation (and libavformat on Windows),
//! so this parser is a tool, not a second demuxer.

use photon_core::codec::{dxv, CodecError, TextureFormat};
use std::collections::BTreeMap;
use std::fs;
use std::process::Command;

// ───────────────────────────── container ────────────────────────────────────

struct Atom {
    typ: [u8; 4],
    body: usize,
    end: usize,
}

fn atoms(buf: &[u8], start: usize, end: usize) -> Vec<Atom> {
    let mut v = Vec::new();
    let mut p = start;
    while p + 8 <= end {
        let Some(h) = buf.get(p..p + 8) else { break };
        let mut size = u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as usize;
        let typ = [h[4], h[5], h[6], h[7]];
        let mut hdr = 8;
        if size == 1 {
            let Some(e) = buf.get(p + 8..p + 16) else { break };
            size = u64::from_be_bytes(e.try_into().unwrap()) as usize;
            hdr = 16;
        } else if size == 0 {
            size = end - p;
        }
        if size < hdr || p + size > end {
            break;
        }
        v.push(Atom {
            typ,
            body: p + hdr,
            end: p + size,
        });
        p += size;
    }
    v
}

fn find(buf: &[u8], path: &[&[u8; 4]], start: usize, end: usize) -> Option<(usize, usize)> {
    for a in atoms(buf, start, end) {
        if &a.typ == *path.first()? {
            if path.len() == 1 {
                return Some((a.body, a.end));
            }
            return find(buf, &path[1..], a.body, a.end);
        }
    }
    None
}

/// Visible frame dimensions from the first `tkhd` (16.16 fixed point at the tail).
fn dimensions(buf: &[u8]) -> Option<(u32, u32)> {
    let (b, e) = find(buf, &[b"moov", b"trak", b"tkhd"], 0, buf.len())?;
    if e < b + 84 {
        return None;
    }
    let w = u32::from_be_bytes(buf[e - 8..e - 4].try_into().ok()?) >> 16;
    let h = u32::from_be_bytes(buf[e - 4..e].try_into().ok()?) >> 16;
    Some((w, h))
}

/// Byte ranges of each DXV frame inside `mdat`.
fn frame_ranges(buf: &[u8]) -> Vec<(usize, usize)> {
    let Some((s, e)) = find(buf, &[b"mdat"], 0, buf.len()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut p = s;
    while p + 12 <= e {
        let Ok(f) = dxv::parse_frame(&buf[p..e]) else {
            break;
        };
        let n = f.payload_offset + f.payload_len;
        out.push((p, p + n));
        p += n;
    }
    out
}

// ──────────────────── reference BC → RGBA (verification only) ───────────────

/// 5-bit channel expansion, measured from FFmpeg.
const EXP5: [u8; 32] = [
    0, 8, 16, 25, 33, 41, 49, 58, 66, 74, 82, 90, 99, 107, 115, 123, 132, 140, 148, 156, 164, 173,
    181, 189, 197, 205, 214, 222, 230, 238, 247, 255,
];

/// 6-bit channel expansion, measured from FFmpeg.
const EXP6: [u8; 64] = [
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 45, 49, 53, 57, 61, 65, 69, 73, 77, 81, 85, 89, 93,
    97, 101, 105, 109, 113, 117, 121, 125, 130, 134, 138, 142, 146, 150, 154, 158, 162, 166, 170,
    174, 178, 182, 186, 190, 194, 198, 202, 206, 210, 214, 219, 223, 227, 231, 235, 239, 243, 247,
    251, 255,
];

fn expand(c: u16) -> [u8; 3] {
    [
        EXP5[((c >> 11) & 0x1F) as usize],
        EXP6[((c >> 5) & 0x3F) as usize],
        EXP5[(c & 0x1F) as usize],
    ]
}

fn bc1_to_rgba(bc1: &[u8], tex_w: u32, w: u32, h: u32) -> Vec<u8> {
    let (w, h, bw) = (w as usize, h as usize, (tex_w / 4) as usize);
    let mut out = vec![0u8; w * h * 4];
    for by in 0..h.div_ceil(4) {
        for bx in 0..w.div_ceil(4) {
            let o = (by * bw + bx) * 8;
            let c0 = u16::from_le_bytes([bc1[o], bc1[o + 1]]);
            let c1 = u16::from_le_bytes([bc1[o + 2], bc1[o + 3]]);
            let idx = u32::from_le_bytes([bc1[o + 4], bc1[o + 5], bc1[o + 6], bc1[o + 7]]);
            let (a, b) = (expand(c0), expand(c1));
            let mut pal = [[0u8; 4]; 4];
            pal[0] = [a[0], a[1], a[2], 255];
            pal[1] = [b[0], b[1], b[2], 255];
            if c0 > c1 {
                for i in 0..3 {
                    pal[2][i] = ((2 * u32::from(a[i]) + u32::from(b[i])) / 3) as u8;
                    pal[3][i] = ((u32::from(a[i]) + 2 * u32::from(b[i])) / 3) as u8;
                }
            } else {
                for i in 0..3 {
                    pal[2][i] = ((u32::from(a[i]) + u32::from(b[i])) / 2) as u8;
                    pal[3][i] = 0;
                }
            }
            // FFmpeg's DXV DXT1 path never produces a transparent texel.
            pal[2][3] = 255;
            pal[3][3] = 255;
            blit(&mut out, w, h, bx, by, |t| {
                pal[((idx >> (2 * t)) & 3) as usize]
            });
        }
    }
    out
}

fn bc3_to_rgba(bc3: &[u8], tex_w: u32, w: u32, h: u32) -> Vec<u8> {
    let (w, h, bw) = (w as usize, h as usize, (tex_w / 4) as usize);
    let mut out = vec![0u8; w * h * 4];
    for by in 0..h.div_ceil(4) {
        for bx in 0..w.div_ceil(4) {
            let o = (by * bw + bx) * 16;
            let at = alpha_table(bc3[o], bc3[o + 1]);
            let mut abits: u64 = 0;
            for i in 0..6 {
                abits |= u64::from(bc3[o + 2 + i]) << (8 * i);
            }
            let c0 = u16::from_le_bytes([bc3[o + 8], bc3[o + 9]]);
            let c1 = u16::from_le_bytes([bc3[o + 10], bc3[o + 11]]);
            let idx = u32::from_le_bytes([bc3[o + 12], bc3[o + 13], bc3[o + 14], bc3[o + 15]]);
            let (a, b) = (expand(c0), expand(c1));
            let mut pal = [[0u8; 3]; 4];
            pal[0] = a;
            pal[1] = b;
            for i in 0..3 {
                pal[2][i] = ((2 * u32::from(a[i]) + u32::from(b[i])) / 3) as u8;
                pal[3][i] = ((u32::from(a[i]) + 2 * u32::from(b[i])) / 3) as u8;
            }
            blit(&mut out, w, h, bx, by, |t| {
                let al = at[((abits >> (3 * t)) & 7) as usize];
                let c = pal[((idx >> (2 * t)) & 3) as usize];
                // The un-premultiply the GPU sampler has to perform.
                [
                    dxv::unpremultiply(c[0], al),
                    dxv::unpremultiply(c[1], al),
                    dxv::unpremultiply(c[2], al),
                    al,
                ]
            });
        }
    }
    out
}

fn alpha_table(a0: u8, a1: u8) -> [u8; 8] {
    let mut t = [0u8; 8];
    t[0] = a0;
    t[1] = a1;
    let (x, y) = (u32::from(a0), u32::from(a1));
    if a0 > a1 {
        for i in 0..6u32 {
            t[2 + i as usize] = (((6 - i) * x + (1 + i) * y) / 7) as u8;
        }
    } else {
        for i in 0..4u32 {
            t[2 + i as usize] = (((4 - i) * x + (1 + i) * y) / 5) as u8;
        }
        t[6] = 0;
        t[7] = 255;
    }
    t
}

fn blit(out: &mut [u8], w: usize, h: usize, bx: usize, by: usize, f: impl Fn(usize) -> [u8; 4]) {
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
            out[p..p + 4].copy_from_slice(&f(y * 4 + x));
        }
    }
}

// ───────────────────────────── verification ─────────────────────────────────

fn ffmpeg_rgba(path: &str, n: usize) -> Result<Vec<u8>, String> {
    let uniq = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = std::env::temp_dir().join(format!("dxvref_{}_{uniq}.raw", std::process::id()));
    // -nostdin: without it FFmpeg eats the caller's stdin, which silently
    // breaks `while read f; …` loops (every other file vanishes).
    let st = Command::new("ffmpeg")
        .args(["-y", "-nostdin", "-v", "error", "-i", path, "-frames:v"])
        .arg(n.to_string())
        .args(["-f", "rawvideo", "-pix_fmt", "rgba"])
        .arg(&tmp)
        .status()
        .map_err(|e| e.to_string())?;
    if !st.success() {
        return Err("ffmpeg failed".into());
    }
    let d = fs::read(&tmp).map_err(|e| e.to_string())?;
    let _ = fs::remove_file(&tmp);
    Ok(d)
}

struct Outcome {
    frames: usize,
    mismatched_frames: usize,
    mismatched_texels: u64,
    note: String,
}

fn verify(path: &str, max_frames: usize) -> Outcome {
    let mut o = Outcome {
        frames: 0,
        mismatched_frames: 0,
        mismatched_texels: 0,
        note: String::new(),
    };
    let Ok(buf) = fs::read(path) else {
        o.note = "unreadable".into();
        return o;
    };
    let Some((w, h)) = dimensions(&buf) else {
        o.note = "no tkhd (truncated file?)".into();
        return o;
    };
    let ranges = frame_ranges(&buf);
    if ranges.is_empty() {
        o.note = "no DXV frames in mdat".into();
        return o;
    }
    let want = ranges.len().min(max_frames);
    let (tw, _) = dxv::texture_dims(w, h);

    let mut ours: Vec<Vec<u8>> = Vec::with_capacity(want);
    for (s, e) in ranges.iter().take(want) {
        let slice = &buf[*s..*e];
        let frame = match dxv::parse_frame(slice) {
            Ok(f) => f,
            Err(e) => {
                o.note = format!("parse: {e}");
                return o;
            }
        };
        match dxv::decode_texture(&frame, slice, w, h) {
            Ok(blocks) => match frame.format {
                TextureFormat::Bc1Rgb => ours.push(bc1_to_rgba(&blocks, tw, w, h)),
                TextureFormat::Bc3Rgba => ours.push(bc3_to_rgba(&blocks, tw, w, h)),
                f => {
                    o.note = format!("{f:?} has no reference expansion");
                    return o;
                }
            },
            Err(CodecError::NotDerived) => {
                o.note = "NotDerived (YCG6/YG10)".into();
                return o;
            }
            Err(e) => {
                o.note = format!("decode: {e}");
                return o;
            }
        }
    }

    let reference = match ffmpeg_rgba(path, want) {
        Ok(r) => r,
        Err(e) => {
            o.note = e;
            return o;
        }
    };
    let stride = (w as usize) * (h as usize) * 4;
    for (i, frame) in ours.iter().enumerate() {
        let Some(r) = reference.get(i * stride..(i + 1) * stride) else {
            o.note = format!("ffmpeg returned only {} frames", reference.len() / stride);
            break;
        };
        o.frames += 1;
        let bad = frame
            .chunks_exact(4)
            .zip(r.chunks_exact(4))
            .filter(|(a, b)| a != b)
            .count() as u64;
        if bad > 0 {
            o.mismatched_frames += 1;
            o.mismatched_texels += bad;
        }
    }
    o
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut files: Vec<String> = Vec::new();
    let mut max_frames = usize::MAX;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--frames" => max_frames = args.next().and_then(|v| v.parse().ok()).unwrap_or(8),
            "--list" => {
                let p = args.next().expect("--list needs a path");
                let t = fs::read_to_string(&p).expect("read list");
                files.extend(t.lines().filter(|l| !l.trim().is_empty()).map(String::from));
            }
            other => files.push(other.to_string()),
        }
    }
    if files.is_empty() {
        eprintln!("usage: dxv_verify [--frames N] [--list FILE] <file.mov>…");
        std::process::exit(2);
    }

    let (mut ok_files, mut ok_frames, mut bad_frames) = (0usize, 0usize, 0usize);
    let mut skipped: BTreeMap<String, usize> = BTreeMap::new();
    for f in &files {
        let o = verify(f, max_frames);
        if o.frames == 0 {
            *skipped.entry(o.note.clone()).or_default() += 1;
            println!("SKIP  {f}  — {}", o.note);
            continue;
        }
        ok_frames += o.frames - o.mismatched_frames;
        bad_frames += o.mismatched_frames;
        if o.mismatched_frames == 0 {
            ok_files += 1;
            println!("OK    {f}  {} frames", o.frames);
        } else {
            println!(
                "FAIL  {f}  {}/{} frames differ, {} texels",
                o.mismatched_frames, o.frames, o.mismatched_texels
            );
        }
    }
    println!(
        "\n{ok_files}/{} files byte-exact · {ok_frames} frames matched · {bad_frames} mismatched",
        files.len()
    );
    for (why, n) in &skipped {
        println!("  skipped {n}: {why}");
    }
    if bad_frames > 0 {
        std::process::exit(1);
    }
}
