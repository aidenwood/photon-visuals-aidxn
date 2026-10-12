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
    let Some((s, e)) = mov::mdat(buf) else { return Vec::new() };
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
    let buf = fs::read(path)?;
    let (w, h) = mov::dimensions(&buf).ok_or("no tkhd dimensions")?;
    let (tw, th) = dxv::texture_dims(w, h);
    let mut rgba = Vec::new();
    for f in frames_of(&buf) {
        let tex = dxv::decode_texture(&f, w, h)?;
        match f.tag {
            dxv::Tag::Dxt1 => rgba.push(bc1::to_rgba(&tex, tw, th, w, h)),
            // BC3 -> RGBA is verified against ffmpeg (RAW mode); only the DXT5
            // *decompressor* is missing, so RAW DXT5 frames decode correctly today.
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

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: {} <info|decode|verify> <file.mov> [out_prefix]", args[0]);
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
            let mut files = Vec::new();
            walk(std::path::Path::new(path), &mut files);
            files.sort();
            let (mut ok, mut tot, mut skipped, mut failed) = (0usize, 0usize, 0usize, 0usize);
            for p in &files {
                let name = p.file_name().unwrap().to_string_lossy();
                match decode_all(p.to_str().unwrap()) {
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
                            if want.len() >= (i + 1) * fsz && r.as_slice() == &want[i * fsz..(i + 1) * fsz] {
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
            println!("{ok}/{tot} frames byte-exact; {} files decoded, {failed} mismatched, {skipped} unsupported",
                     files.len() - skipped);
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
}
