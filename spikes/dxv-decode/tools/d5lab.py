"""DXT5 experiment lab.

Builds payloads op-by-op with explicit control over the data byte stream, so an op
whose byte-consumption is UNKNOWN can be probed: everything after it is read as a
tail of known, distinct bytes and the resulting behaviour identifies the consumption.

ffmpeg's `idx N > M` trace line is the instruction tracer: N = the computed source
index in u32 units, M = the output cursor in u32 units at the moment of the fault.
Calibrated in `calib()`.
"""
import sys, os, re, struct, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft import make_mov, dxv_frame

RX = re.compile(r'idx (\d+) > (\d+)')
TMPL = 'probes/tmpl_1024x64.mov'
W, H = 1024, 64
BW = W // 4
NB = BW * (H // 4)
NU = NB * 4


def alpha_half(a0, a1=0, idx=0):
    return bytes([a0 & 0xff, a1 & 0xff]) + idx.to_bytes(6, 'little')


def colour_half(c0, c1=None, idx=0):
    if c1 is None:
        c1 = c0
    return struct.pack('<HHI', c0, c1, idx)


def varint(n):
    o = b''
    while n >= 255:
        o += b'\xff'
        n -= 255
    return o + bytes([n])


class Build:
    """ops: list of 2-bit codes. data: byte stream appended after each mask group.

    The real format interleaves: a 32-bit mask word, then the data bytes consumed by
    those 16 ops, then the next mask word. `data` entries are attached per-op so the
    interleave comes out right even when an op's consumption is a guess.
    """

    def __init__(self, seed_alpha=200, seed_colour=0xF800):
        self.pay = bytearray(alpha_half(seed_alpha) + colour_half(seed_colour))
        self.ops = []   # (code, data_bytes)

    def op(self, code, data=b''):
        self.ops.append((code & 3, data))
        return self

    def build(self, tail=b''):
        out = bytearray(self.pay)
        i = 0
        while i < len(self.ops):
            m = 0
            d = b''
            for j in range(16):
                if i + j >= len(self.ops):
                    break
                c, dd = self.ops[i + j]
                m |= c << (2 * j)
                d += dd
            out += struct.pack('<I', m) + d
            i += 16
        return bytes(out) + tail


def run(payload, tmpl=TMPL, w=W, h=H):
    make_mov(tmpl, '/tmp/d5lab.mov', dxv_frame(tag=b'DXT5', payload=payload))
    r = subprocess.run(['ffmpeg', '-y', '-nostdin', '-v', 'trace', '-i', '/tmp/d5lab.mov',
                        '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgba', '/tmp/d5lab.raw'],
                       capture_output=True, text=True)
    m = RX.search(r.stderr)
    if m:
        return ('ERR', int(m.group(1)), int(m.group(2)), None)
    if r.returncode != 0:
        return ('FAIL', None, None, r.stderr[-400:])
    return ('OK', None, None, open('/tmp/d5lab.raw', 'rb').read())


def blocks(rgba, n=None, w=W, bw=BW):
    """per block -> (alpha, (r,g,b)) of its top-left texel."""
    n = n or NB
    out = []
    for b in range(n):
        by, bx = divmod(b, bw)
        p = ((by * 4) * w + bx * 4) * 4
        out.append((rgba[p + 3], tuple(rgba[p:p + 3])))
    return out


def history(b, n, a0=lambda k: (k % 251) + 1):
    """Append n blocks each with a distinct alpha, colour copied from the block before.

    Uses only VERIFIED ops: aligned 11 = 8-byte literal (alpha half),
    mid 01 = copy 8 bytes from 16 back (colour half).
    """
    for k in range(1, n + 1):
        b.op(3, alpha_half(a0(k)))
        b.op(1)
    return b
