#!/usr/bin/env python3
"""Extract the DXV frame payload(s) from a .mov produced by ffmpeg's dxv encoder.

Walks the ISO-BMFF atom tree to find `mdat`, then reads successive DXV frames.
Each frame: 12-byte header + payload_size bytes.
"""
import struct, sys, os

def atoms(buf, start, end, depth=0):
    p = start
    while p + 8 <= end:
        size = struct.unpack_from('>I', buf, p)[0]
        typ = buf[p+4:p+8]
        hdr = 8
        if size == 1:
            size = struct.unpack_from('>Q', buf, p+8)[0]
            hdr = 16
        elif size == 0:
            size = end - p
        if size < hdr:
            break
        yield (typ, p, hdr, size)
        p += size

def find_mdat(buf):
    for typ, p, hdr, size in atoms(buf, 0, len(buf)):
        if typ == b'mdat':
            return p + hdr, p + size
    raise SystemExit('no mdat')

HDR = struct.Struct('<4sBBBBI')

def frames(path):
    buf = open(path, 'rb').read()
    s, e = find_mdat(buf)
    out = []
    p = s
    while p + 12 <= e:
        tag, vmaj, vmin, cflag, resv, psize = HDR.unpack_from(buf, p)
        if psize == 0 or p + 12 + psize > e:
            break
        out.append({
            'tag': tag[::-1].decode('latin1'),
            'vmaj': vmaj, 'vmin': vmin, 'cflag': cflag, 'resv': resv,
            'psize': psize,
            'payload': buf[p+12:p+12+psize],
            'offset': p,
        })
        p += 12 + psize
    return out

if __name__ == '__main__':
    path = sys.argv[1]
    for i, f in enumerate(frames(path)):
        print(f"frame {i}: tag={f['tag']} v={f['vmaj']}.{f['vmin']} cflag={f['cflag']} "
              f"resv={f['resv']} psize={f['psize']} off={f['offset']}")
        if len(sys.argv) > 2:
            outp = sys.argv[2] if len(frames(path)) == 1 else f"{sys.argv[2]}.{i}"
            open(outp, 'wb').write(f['payload'])
            print(f"  -> {outp}")
