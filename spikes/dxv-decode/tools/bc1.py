#!/usr/bin/env python3
"""BC1 (DXT1) -> RGBA decoder, to be validated against ffmpeg via DXV RAW mode."""
import struct

def exp565(c):
    r = (c >> 11) & 0x1F; g = (c >> 5) & 0x3F; b = c & 0x1F
    r = (r << 3) | (r >> 2); g = (g << 2) | (g >> 4); b = (b << 3) | (b >> 2)
    return (r, g, b)

def bc1_block(c0, c1, idx):
    a = exp565(c0); b = exp565(c1)
    if c0 > c1:
        c2 = tuple((2*a[i] + b[i]) // 3 for i in range(3))
        c3 = tuple((a[i] + 2*b[i]) // 3 for i in range(3))
        pal = [a + (255,), b + (255,), c2 + (255,), c3 + (255,)]
    else:
        c2 = tuple((a[i] + b[i]) // 2 for i in range(3))
        pal = [a + (255,), b + (255,), c2 + (255,), (0, 0, 0, 0)]
    return [pal[(idx >> (2*i)) & 3] for i in range(16)]

def decode(bc1, w, h):
    out = bytearray(w * h * 4)
    bw, bh = w // 4, h // 4
    for by in range(bh):
        for bx in range(bw):
            o = (by * bw + bx) * 8
            c0, c1, idx = struct.unpack_from('<HHI', bc1, o)
            px = bc1_block(c0, c1, idx)
            for y in range(4):
                for x in range(4):
                    p = ((by*4+y)*w + (bx*4+x)) * 4
                    out[p:p+4] = bytes(px[y*4+x])
    return bytes(out)
