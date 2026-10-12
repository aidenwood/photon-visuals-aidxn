"""Position-tracking DXT5 probe rig.

Tracks the output cursor in u32 units so every op's slot (block-aligned vs mid-block)
is known by construction, and emits mask words lazily exactly like the format does.
Readable block layout: alpha a0 is directly visible as the RGBA alpha channel when the
alpha index bits are 0; colour c0==c1 shows as a flat RGB.
"""
import sys, os, re, struct, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft import make_mov, dxv_frame

RX = re.compile(r'idx (\d+) > (\d+)')

class Rig:
    def __init__(self, tmpl, w, h):
        self.tmpl, self.w, self.h = tmpl, w, h
        self.bw = w // 4
        self.nb = self.bw * (h // 4)
    def run(self, payload):
        make_mov(self.tmpl, '/tmp/rig5.mov', dxv_frame(tag=b'DXT5', payload=payload))
        r = subprocess.run(['ffmpeg','-y','-nostdin','-v','trace','-i','/tmp/rig5.mov',
                            '-frames:v','1','-f','rawvideo','-pix_fmt','rgba','/tmp/rig5.raw'],
                           capture_output=True, text=True)
        m = RX.search(r.stderr)
        if m: return ('ERR', int(m.group(1)), int(m.group(2)), None)
        if r.returncode != 0: return ('FAIL', None, None, None)
        return ('OK', None, None, open('/tmp/rig5.raw','rb').read())
    def blocks(self, rgba, n=None):
        n = n or self.nb
        out = []
        for b in range(n):
            by, bx = divmod(b, self.bw)
            p = ((by*4)*self.w + bx*4) * 4
            out.append((rgba[p+3], tuple(rgba[p:p+3])))
        return out

def varint(n):
    o = b''
    while n >= 255: o += b'\xff'; n -= 255
    return o + bytes([n])

def alpha_half(a0, a1=0, idx=0):
    return bytes([a0 & 0xff, a1 & 0xff]) + idx.to_bytes(6, 'little')

def colour_half(c0, c1=None, idx=0):
    if c1 is None: c1 = c0
    return struct.pack('<HHI', c0, c1, idx)

class Stream:
    """Builds a payload while tracking the cursor; `pos` is in u32 units."""
    def __init__(self, seed_alpha, seed_colour):
        self.seed = alpha_half(seed_alpha) + colour_half(seed_colour)
        self.ops = []          # (code, data, units_emitted)
        self.pos = 4
    def add(self, code, data=b'', units=2):
        self.ops.append((code, data))
        self.pos += units
        return self
    def aligned(self):
        return self.pos % 4 == 0
    def build(self):
        pay = bytearray(self.seed); i = 0
        while i < len(self.ops):
            m = 0; data = b''
            for j in range(16):
                if i + j >= len(self.ops): break
                c, d = self.ops[i+j]
                m |= (c & 3) << (2*j); data += d
            pay += struct.pack('<I', m) + data; i += 16
        return bytes(pay)
