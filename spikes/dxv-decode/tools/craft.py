#!/usr/bin/env python3
"""Craft a .mov containing an arbitrary single DXV frame, by patching a template.

Lets us use ffmpeg's DXV DECODER as a black-box oracle: feed a candidate
compressed payload, see what RGBA comes out.
"""
import struct, subprocess, os, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def _atoms(buf, s, e):
    p = s
    while p + 8 <= e:
        size = struct.unpack_from('>I', buf, p)[0]
        typ = buf[p+4:p+8]
        hdr = 8
        if size == 1:
            size = struct.unpack_from('>Q', buf, p+8)[0]; hdr = 16
        elif size == 0:
            size = e - p
        yield typ, p, hdr, size
        p += size

def _find(buf, path, s=0, e=None):
    if e is None: e = len(buf)
    want = path[0]
    for typ, p, hdr, size in _atoms(buf, s, e):
        if typ == want:
            if len(path) == 1:
                return p, hdr, size
            return _find(buf, path[1:], p+hdr, p+size)
    raise KeyError(path)

def make_mov(template, out_path, frame_bytes):
    buf = bytearray(open(template, 'rb').read())
    mp, mh, msz = _find(buf, [b'mdat'])
    old_payload_len = msz - mh
    new = bytearray()
    new += buf[:mp]
    new += struct.pack('>I', mh + len(frame_bytes)) + b'mdat'
    new += frame_bytes
    tail = bytearray(buf[mp+msz:])
    # patch stsz (sample size) and stco (chunk offset) inside the moov tail
    moov_off_in_tail = 0
    # find stsz / stco relative to tail
    try:
        sp, sh, ssz = _find(tail, [b'moov', b'trak', b'mdia', b'minf', b'stbl', b'stsz'])
        struct.pack_into('>I', tail, sp + 12, len(frame_bytes))  # sample_size field
    except KeyError:
        pass
    # single sample: patch stts entry count, stsc samples-per-chunk, stsz count
    try:
        tp, th_, tsz = _find(tail, [b'moov', b'trak', b'mdia', b'minf', b'stbl', b'stts'])
        struct.pack_into('>I', tail, tp + 12, 1)        # entry count
        struct.pack_into('>I', tail, tp + 16, 1)        # sample count of entry 0
    except KeyError:
        pass
    try:
        scp, sch, scsz = _find(tail, [b'moov', b'trak', b'mdia', b'minf', b'stbl', b'stsc'])
        struct.pack_into('>I', tail, scp + 12, 1)       # entry count
        struct.pack_into('>I', tail, scp + 16, 1)       # first chunk
        struct.pack_into('>I', tail, scp + 20, 1)       # samples per chunk
    except KeyError:
        pass
    try:
        szp, szh, szsz = _find(tail, [b'moov', b'trak', b'mdia', b'minf', b'stbl', b'stsz'])
        struct.pack_into('>I', tail, szp + 16, 1)       # sample count
    except KeyError:
        pass
    try:
        cp, ch, csz = _find(tail, [b'moov', b'trak', b'mdia', b'minf', b'stbl', b'stco'])
        n = struct.unpack_from('>I', tail, cp + 12)[0]
        for i in range(n):
            struct.pack_into('>I', tail, cp + 16 + 4*i, mp + mh)
    except KeyError:
        pass
    new += tail
    open(out_path, 'wb').write(bytes(new))
    return out_path

def dxv_frame(tag=b'DXT1', vmaj=4, vmin=0, cflag=0, resv=0, payload=b''):
    return tag[::-1] + bytes([vmaj, vmin, cflag, resv]) + struct.pack('<I', len(payload)) + payload

def decode_rgba(mov, w, h):
    """Run ffmpeg's dxv decoder, return RGBA bytes (or None on failure)."""
    with tempfile.NamedTemporaryFile(suffix='.raw', delete=False) as t:
        raw = t.name
    r = subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', mov, '-frames:v', '1',
                        '-f', 'rawvideo', '-pix_fmt', 'rgba', raw],
                       capture_output=True)
    data = open(raw, 'rb').read() if os.path.exists(raw) else b''
    os.unlink(raw)
    if r.returncode != 0:
        return None, r.stderr.decode('utf8', 'replace')
    return data, r.stderr.decode('utf8', 'replace')

def oracle(template, w, h, payload, cflag=0, tag=b'DXT1'):
    """payload -> decoded RGBA via ffmpeg."""
    with tempfile.NamedTemporaryFile(suffix='.mov', delete=False) as t:
        mov = t.name
    make_mov(template, mov, dxv_frame(tag=tag, cflag=cflag, payload=payload))
    out, err = decode_rgba(mov, w, h)
    os.unlink(mov)
    return out, err
