#!/usr/bin/env python3
"""Black-box probing harness for ffmpeg's DXV decoder.

Craft a compressed payload -> decode -> recover the per-block BC1 words.
Trick: if a block has color0 == color1 == C then every pixel is C, so the
565 colour word is directly readable from the RGBA output.
"""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft import oracle

def c565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

def unexpand565(r, g, b):
    """Invert ffmpeg's 565->888 expansion (replicate high bits)."""
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

def blocks_from_rgba(rgba, w, h):
    """Return list of (is_flat, color565 or None) per 4x4 block, row-major."""
    out = []
    bw, bh = w // 4, h // 4
    for by in range(bh):
        for bx in range(bw):
            px = []
            for y in range(4):
                for x in range(4):
                    o = ((by*4+y)*w + (bx*4+x)) * 4
                    px.append(tuple(rgba[o:o+3]))
            flat = len(set(px)) == 1
            out.append((flat, unexpand565(*px[0]) if flat else px))
    return out

def flat_colors(rgba, w, h):
    res = []
    for flat, v in blocks_from_rgba(rgba, w, h):
        res.append(v if flat else 'MIX')
    return res

def lit(c565val, idx=0xAAAAAAAA):
    """One literal BC1 block with color0==color1==c, given index word."""
    return struct.pack('<HHI', c565val, c565val, idx)

def u32(v):
    return struct.pack('<I', v)

def show(name, template, w, h, payload):
    out, err = oracle(template, w, h, payload)
    if out is None:
        print(f'{name}: DECODE FAIL  {err.strip()[:160]}')
        return None
    fc = flat_colors(out, w, h)
    print(f'{name}: ' + ' '.join(f'{v:04x}' if isinstance(v, int) else 'MIX' for v in fc))
    return fc
