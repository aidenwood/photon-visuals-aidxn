#!/usr/bin/env python3
"""Reference (Python) DXV3 decompressor - derived empirically, mirrors the Rust impl."""
import struct

class Reader:
    __slots__ = ('b', 'p', 'mask', 'nbits')
    def __init__(self, b):
        self.b = b; self.p = 0; self.mask = 0; self.nbits = 0
    def u8(self):
        v = self.b[self.p]; self.p += 1; return v
    def u16(self):
        v = self.b[self.p] | (self.b[self.p+1] << 8); self.p += 2; return v
    def u32(self):
        v = struct.unpack_from('<I', self.b, self.p)[0]; self.p += 4; return v
    def op(self):
        """Return the 2-bit op code as (b0, b1), LSB-first, refilling the 32-bit mask."""
        if self.nbits == 0:
            self.mask = self.u32(); self.nbits = 32
        c = self.mask & 3
        self.mask >>= 2; self.nbits -= 2
        return c          # bit0 = c&1, bit1 = (c>>1)&1

OP_COPY  = 0b01   # c = b0 | b1<<1 ; b0=1,b1=0 -> 1
OP_U16   = 0b11
OP_U8    = 0b10   # b0=0,b1=1 -> 2
OP_SPLIT = 0b00

def decompress_dxt1(payload, nunits):
    out = [0] * nunits
    r = Reader(payload)
    out[0] = r.u32(); out[1] = r.u32()
    pos = 2
    while pos < nunits:
        c = r.op()
        if c == OP_COPY:
            d = 2
        elif c == OP_U8:
            d = 2 * r.u8() + 4
        elif c == OP_U16:
            d = 2 * (r.u16() + 256) + 4
        else:
            for _ in range(2):
                s = r.op()
                if s == OP_COPY:
                    out[pos] = out[pos-2]
                elif s == OP_U8:
                    out[pos] = out[pos - (2*r.u8() + 4)]
                elif s == OP_U16:
                    out[pos] = out[pos - (2*(r.u16()+256) + 4)]
                else:
                    out[pos] = r.u32()
                pos += 1
            continue
        if d > pos:
            raise ValueError(f'idx {d} > {pos}')
        out[pos] = out[pos-d]; out[pos+1] = out[pos-d+1]
        pos += 2
    return b''.join(struct.pack('<I', v) for v in out)
