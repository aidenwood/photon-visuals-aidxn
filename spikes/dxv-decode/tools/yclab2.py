#!/usr/bin/env python3
"""YCG6 craft-and-probe lab: our own Y stream + a real chroma stream.

The chroma tail is lifted verbatim from ringmask3 frame 0 (bytes h0..end), which
decodes to constant Co=Cg=127, so anything that moves in the output moves because
of the crafted Y stream.
"""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract import frames
from yclab import Lab

_p = frames(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         'yc/ycg6_ringmask3.mov'))[0]['payload']
CHROMA = _p[11612:]

def payload(ystream, h1=4):
    h0 = 8 + len(ystream)
    return struct.pack('<2I', h0, h1) + ystream + CHROMA

class Y:
    """Build a Y stream: 32-bit LE mask words, 2 bits/op LSB-first, data interleaved."""
    def __init__(self): self.ops = []
    def op(self, code, data=b''):
        self.ops.append((code & 3, data)); return self
    def build(self, tail=b''):
        out = bytearray(); i = 0
        while i < len(self.ops):
            m = 0; d = b''
            for j in range(16):
                if i + j >= len(self.ops): break
                c, dd = self.ops[i + j]
                m |= c << (2 * j); d += dd
            out += struct.pack('<I', m) + d
            i += 16
        return bytes(out) + tail

def varint(n):
    if n < 255: return bytes([n])
    n -= 255; o = b'\xff'
    while n >= 0xffff:
        o += b'\xff\xff'; n -= 0xffff
    return o + struct.pack('<H', n)

def bc4(a0, a1, idx=0):
    return bytes([a0 & 0xff, a1 & 0xff]) + idx.to_bytes(6, 'little')
