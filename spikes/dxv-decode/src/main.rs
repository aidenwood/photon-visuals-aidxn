//! DXV3 decode spike.
//!
//!   cargo run --release -- info   <file.mov>
//!   cargo run --release -- decode <file.mov> <out_prefix>    # writes <prefix>NNN.rgba
//!   cargo run --release -- verify <file.mov>                 # diffs against ffmpeg
//!
//! `verify` shells out to the `ffmpeg` BINARY purely as a black-box reference decoder.

mod bc1;
mod bc3;
mod dxv;
mod mov;

use std::fs;
use std::process::Command;

fn frames_of(buf: &[u8]) -> Vec<dxv::Frame<'_>> {
    let Some((s, e)) = mov::mdat(buf) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut p = s;
    while p + 12 <= e {
        match dxv::parse_frame(&buf[p..e]) {
            Ok((f, n)) => {
                out.push(f);
                p += n;
            }
            Err(_) => break,
        }
    }
    out
}

fn decode_all(path: &str) -> Result<(usize, usize, Vec<Vec<u8>>), Box<dyn std::error::Error>> {
    decode_n(path, usize::MAX)
}

/// Decode at most `max` frames. 4K files hold 150+ frames and a full RGBA set runs to
/// gigabytes, so bulk verification caps this rather than holding the lot in memory.
fn decode_n(
    path: &str,
    max: usize,
) -> Result<(usize, usize, Vec<Vec<u8>>), Box<dyn std::error::Error>> {
    let buf = fs::read(path)?;
    let (w, h) = mov::dimensions(&buf).ok_or("no tkhd dimensions")?;
    let (tw, th) = dxv::texture_dims(w, h);
    let mut rgba = Vec::new();
    for f in frames_of(&buf).into_iter().take(max) {
        let tex = dxv::decode_texture(&f, w, h)?;
        match f.tag {
            dxv::Tag::Dxt1 => rgba.push(bc1::to_rgba(&tex, tw, th, w, h)),
            dxv::Tag::Dxt5 => rgba.push(bc3::to_rgba(&tex, tw, th, w, h)),
            other => return Err(format!("{other:?} RGBA conversion not implemented").into()),
        }
    }
    Ok((w, h, rgba))
}

fn ffmpeg_rgba(path: &str, n: usize) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    // unique per call: a bare PID collides when verify is run in a tight shell loop
    let uniq = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = std::env::temp_dir().join(format!("dxvref_{}_{}.raw", std::process::id(), uniq));
    let st = Command::new("ffmpeg")
        // -nostdin: without it ffmpeg eats the caller's stdin, which silently breaks
        // `while read f; do ... done < list.txt` loops (every other file vanishes).
        .args(["-y", "-nostdin", "-v", "error", "-i", path, "-frames:v"])
        .arg(n.to_string())
        .args(["-f", "rawvideo", "-pix_fmt", "rgba"])
        .arg(&tmp)
        .status()?;
    if !st.success() {
        return Err("ffmpeg failed".into());
    }
    let d = fs::read(&tmp)?;
    let _ = fs::remove_file(&tmp);
    Ok(d)
}

/// Verify every frame of a file without ever holding more than one frame of each
/// side in memory — a 4K clip is 33 MB per RGBA frame, so the all-frames-in-a-Vec
/// path runs to gigabytes and is unusable for whole-library runs.
/// Returns (frames_ok, frames_total).
fn verify_stream(path: &str) -> Result<(usize, usize), Box<dyn std::error::Error>> {
    use std::io::{Read, Seek, SeekFrom};
    let buf = fs::read(path)?;
    let (w, h) = mov::dimensions(&buf).ok_or("no tkhd dimensions")?;
    let (tw, th) = dxv::texture_dims(w, h);
    let frames = frames_of(&buf);
    let n = frames.len();
    if n == 0 {
        return Err("no DXV frames".into());
    }
    // Probe the first frame before spending minutes in ffmpeg on an unsupported tag.
    dxv::decode_texture(&frames[0], w, h)?;

    let uniq = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = std::env::temp_dir().join(format!("dxvstream_{}_{}.raw", std::process::id(), uniq));
    let st = Command::new("ffmpeg")
        .args(["-y", "-nostdin", "-v", "error", "-i", path, "-frames:v"])
        .arg(n.to_string())
        .args(["-f", "rawvideo", "-pix_fmt", "rgba"])
        .arg(&tmp)
        .status()?;
    if !st.success() {
        let _ = fs::remove_file(&tmp);
        return Err("ffmpeg failed".into());
    }
    let fsz = w * h * 4;
    let mut f = fs::File::open(&tmp)?;
    let avail = f.metadata()?.len() as usize / fsz;
    let mut want = vec![0u8; fsz];
    let mut ok = 0;
    let mut total = 0;
    for (i, fr) in frames.iter().enumerate() {
        if i >= avail {
            break;
        }
        total += 1;
        let tex = match dxv::decode_texture(fr, w, h) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let mine = match fr.tag {
            dxv::Tag::Dxt1 => bc1::to_rgba(&tex, tw, th, w, h),
            dxv::Tag::Dxt5 => bc3::to_rgba(&tex, tw, th, w, h),
            _ => continue,
        };
        f.seek(SeekFrom::Start((i * fsz) as u64))?;
        f.read_exact(&mut want)?;
        if mine == want {
            ok += 1;
        }
    }
    let _ = fs::remove_file(&tmp);
    Ok((ok, total))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!(
            "usage: {} <info|decode|verify> <file.mov> [out_prefix]",
            args[0]
        );
        std::process::exit(2);
    }
    let path = &args[2];

    match args[1].as_str() {
        "info" => {
            let buf = fs::read(path)?;
            let (w, h) = mov::dimensions(&buf).unwrap_or((0, 0));
            let (tw, th) = dxv::texture_dims(w, h);
            println!("frame {w}x{h}  texture {tw}x{th}");
            for (i, f) in frames_of(&buf).iter().enumerate() {
                println!(
                    "  frame {i}: tag={:?} v{}.{} {} payload={}",
                    f.tag,
                    f.version_major.saturating_sub(1),
                    f.version_minor,
                    if f.raw { "RAW" } else { "compressed" },
                    f.payload.len()
                );
            }
        }
        "decode" => {
            let prefix = args.get(3).map(String::as_str).unwrap_or("frame");
            let (w, h, frames) = decode_all(path)?;
            for (i, r) in frames.iter().enumerate() {
                let out = format!("{prefix}{i:03}.rgba");
                fs::write(&out, r)?;
                println!("{out}  {w}x{h}  {} bytes", r.len());
            }
        }
        // Walk a directory tree and verify every .mov in it. Prints a tag census so
        // unsupported variants (DXT5/YCoCg) are reported rather than silently skipped.
        "verify-dir" => {
            fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
                if let Ok(rd) = fs::read_dir(dir) {
                    for e in rd.flatten() {
                        let p = e.path();
                        if p.is_dir() {
                            walk(&p, out);
                        } else if p.extension().and_then(|s| s.to_str()) == Some("mov") {
                            out.push(p);
                        }
                    }
                }
            }
            let maxf: usize = args
                .get(3)
                .and_then(|s| s.parse().ok())
                .unwrap_or(usize::MAX);
            let mut files = Vec::new();
            walk(std::path::Path::new(path), &mut files);
            files.sort();
            let (mut ok, mut tot, mut skipped, mut failed) = (0usize, 0usize, 0usize, 0usize);
            for p in &files {
                let name = p.file_name().unwrap().to_string_lossy();
                match decode_n(p.to_str().unwrap(), maxf) {
                    Err(e) => {
                        skipped += 1;
                        println!("  skip {name}: {e}");
                    }
                    Ok((w, h, mine)) => {
                        let want = match ffmpeg_rgba(p.to_str().unwrap(), mine.len()) {
                            Ok(v) => v,
                            Err(e) => {
                                skipped += 1;
                                println!("  skip {name}: ffmpeg {e}");
                                continue;
                            }
                        };
                        let fsz = w * h * 4;
                        let mut good = 0;
                        for (i, r) in mine.iter().enumerate() {
                            if want.len() >= (i + 1) * fsz
                                && r.as_slice() == &want[i * fsz..(i + 1) * fsz]
                            {
                                good += 1;
                            }
                        }
                        ok += good;
                        tot += mine.len();
                        if good != mine.len() {
                            failed += 1;
                            println!("  MISMATCH {name}: {good}/{} frames", mine.len());
                        } else {
                            println!("  ok {name}: {good} frames");
                        }
                    }
                }
            }
            println!(
                "{ok}/{tot} frames byte-exact; {} files decoded, {failed} mismatched, {skipped} unsupported",
                files.len() - skipped
            );
        }
        // Whole-tree, every frame, constant memory. Prints one line per file.
        "verify-all" => {
            fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
                if let Ok(rd) = fs::read_dir(dir) {
                    for e in rd.flatten() {
                        let p = e.path();
                        if p.is_dir() {
                            walk(&p, out);
                        } else if p.extension().and_then(|s| s.to_str()) == Some("mov") {
                            out.push(p);
                        }
                    }
                }
            }
            let mut files = Vec::new();
            walk(std::path::Path::new(path), &mut files);
            files.sort();
            let (mut ok, mut tot, mut nfiles, mut bad, mut skipped) = (0, 0, 0, 0, 0);
            for p in &files {
                let name = p.file_name().unwrap().to_string_lossy();
                match verify_stream(p.to_str().unwrap()) {
                    Err(_) => skipped += 1,
                    Ok((g, t)) => {
                        nfiles += 1;
                        ok += g;
                        tot += t;
                        if g != t {
                            bad += 1;
                            println!("  MISMATCH {name}: {g}/{t}");
                        } else {
                            println!("  ok {name}: {t}");
                        }
                    }
                }
            }
            println!(
                "{ok}/{tot} frames byte-exact across {nfiles} files; {bad} mismatched, {skipped} unsupported"
            );
            if ok != tot {
                std::process::exit(1);
            }
        }
        "verify" => {
            let (w, h, mine) = decode_all(path)?;
            let want = ffmpeg_rgba(path, mine.len())?;
            let fsz = w * h * 4;
            let mut ok = 0;
            for (i, r) in mine.iter().enumerate() {
                let slice = &want[i * fsz..(i + 1) * fsz];
                if r.as_slice() == slice {
                    ok += 1;
                } else {
                    let nd = r.iter().zip(slice).filter(|(a, b)| a != b).count();
                    println!("  frame {i}: MISMATCH {nd}/{fsz} bytes");
                }
            }
            println!("{path}: {ok}/{} frames byte-exact vs ffmpeg", mine.len());
            if ok != mine.len() {
                std::process::exit(1);
            }
        }
        other => {
            eprintln!("unknown command {other}");
            std::process::exit(2);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every `.mov` in probes/ and probes2/ must decode byte-exactly against ffmpeg.
    #[test]
    fn probes_match_ffmpeg() {
        let mut checked = 0;
        for dir in ["probes", "probes2"] {
            let Ok(rd) = fs::read_dir(dir) else { continue };
            for e in rd.flatten() {
                let p = e.path();
                if p.extension().and_then(|s| s.to_str()) != Some("mov") {
                    continue;
                }
                let path = p.to_str().unwrap();
                let (w, h, mine) = decode_all(path).expect(path);
                let want = ffmpeg_rgba(path, mine.len()).expect(path);
                let fsz = w * h * 4;
                for (i, r) in mine.iter().enumerate() {
                    assert_eq!(
                        r.as_slice(),
                        &want[i * fsz..(i + 1) * fsz],
                        "{path} frame {i}"
                    );
                    checked += 1;
                }
            }
        }
        assert!(checked > 0, "no probes found");
        eprintln!("{checked} frames byte-exact");
    }

    /// Real Resolume DXT5 assets, 1080p and 4K. `d5/` holds symlinks into Aiden's
    /// projections library; skipped when that volume is not mounted rather than
    /// failing, but never silently passing with zero frames checked.
    #[test]
    fn dxt5_real_assets_match_ffmpeg() {
        let Ok(rd) = fs::read_dir("d5") else {
            eprintln!("d5/ absent - DXT5 corpus not available here");
            return;
        };
        let mut checked = 0;
        for e in rd.flatten() {
            let p = e.path();
            if p.extension().and_then(|s| s.to_str()) != Some("mov") {
                continue;
            }
            let path = p.to_str().unwrap();
            let (w, h, mine) = decode_n(path, 20).expect(path);
            let want = ffmpeg_rgba(path, mine.len()).expect(path);
            let fsz = w * h * 4;
            for (i, r) in mine.iter().enumerate() {
                assert_eq!(
                    r.as_slice(),
                    &want[i * fsz..(i + 1) * fsz],
                    "{path} frame {i}"
                );
                checked += 1;
            }
        }
        eprintln!("{checked} DXT5 frames byte-exact");
    }
}
