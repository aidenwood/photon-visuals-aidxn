//! Minimal ISO-BMFF walker: just enough to pull DXV frames out of an `mdat`,
//! plus the `tkhd` width/height. Not a general MP4 parser.

#![allow(dead_code)] // spike: module is a reference impl, not all of it is wired to main

pub struct Atom {
    pub typ: [u8; 4],
    pub body: usize,
    pub end: usize,
}

pub fn atoms(buf: &[u8], start: usize, end: usize) -> Vec<Atom> {
    let mut v = Vec::new();
    let mut p = start;
    while p + 8 <= end {
        let mut size = u32::from_be_bytes([buf[p], buf[p + 1], buf[p + 2], buf[p + 3]]) as usize;
        let typ = [buf[p + 4], buf[p + 5], buf[p + 6], buf[p + 7]];
        let mut hdr = 8;
        if size == 1 {
            if p + 16 > end {
                break;
            }
            size = u64::from_be_bytes(buf[p + 8..p + 16].try_into().unwrap()) as usize;
            hdr = 16;
        } else if size == 0 {
            size = end - p;
        }
        if size < hdr || p + size > end {
            break;
        }
        v.push(Atom { typ, body: p + hdr, end: p + size });
        p += size;
    }
    v
}

fn find<'a>(buf: &[u8], path: &[&[u8; 4]], start: usize, end: usize) -> Option<(usize, usize)> {
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

pub fn mdat(buf: &[u8]) -> Option<(usize, usize)> {
    find(buf, &[b"mdat"], 0, buf.len())
}

/// Visible frame dimensions from the first `tkhd` (fixed-point 16.16 at the tail).
pub fn dimensions(buf: &[u8]) -> Option<(usize, usize)> {
    let (b, e) = find(buf, &[b"moov", b"trak", b"tkhd"], 0, buf.len())?;
    if e < b + 84 {
        return None;
    }
    let w = u32::from_be_bytes(buf[e - 8..e - 4].try_into().ok()?) >> 16;
    let h = u32::from_be_bytes(buf[e - 4..e].try_into().ok()?) >> 16;
    Some((w as usize, h as usize))
}
