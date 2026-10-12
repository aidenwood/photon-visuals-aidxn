"""Candidate DXT5 (DXTR5) decoder — two-plane model, scored against ffmpeg.

The texture is BC3: block = [8 B alpha half][8 B colour half]. The compressor treats
those as TWO independent LZ planes sharing one op/flag stream. Each plane has its own
block cursor (`ap`, `cp`); before every op the decoder picks the plane that is behind
(alpha wins ties). Distances are in u32 units over the WHOLE texture, so a plane's
back-reference lands on the same half of an earlier block.
"""
import sys, os, struct, subprocess, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract import frames


class Dec:
    def __init__(self, pay, nblocks):
        self.b = pay
        self.p = 0
        self.m = 0
        self.n = 0
        self.nb = nblocks
        self.out = [0] * (nblocks * 4)
        for i in range(4):
            self.out[i] = struct.unpack_from('<I', pay, self.p)[0]
            self.p += 4
        self.ap = 1
        self.cp = 1
        self.ops = []

    def u8(s):
        v = s.b[s.p]; s.p += 1; return v

    def u16(s):
        v = s.b[s.p] | (s.b[s.p + 1] << 8); s.p += 2; return v

    def u32(s):
        v = struct.unpack_from('<I', s.b, s.p)[0]; s.p += 4; return v

    def varint(s):
        x = s.u8()
        if x != 0xff:
            return x
        while True:
            w = s.u16()
            x += w
            if w != 0xffff:
                return x

    def code(s):
        if s.n == 0:
            s.m = s.u32(); s.n = 32
        c = s.m & 3; s.m >>= 2; s.n -= 2
        return c

    # --- unit-level writes -------------------------------------------------
    def cpu(s, pos, dist):
        if dist <= 0 or dist > pos:
            raise ValueError('dist %d > %d' % (dist, pos))
        s.out[pos] = s.out[pos - dist]

    def half_copy(s, base, dist):
        s.cpu(base, dist)
        s.cpu(base + 1, dist)

    def half_lit(s, base):
        s.out[base] = s.u32()
        s.out[base + 1] = s.u32()

    # --- alpha plane -------------------------------------------------------
    def alpha_op(s, c):
        if c == 0:                       # whole-block run: N+1 blocks, both planes
            n = s.varint() + 1
            for _ in range(n):
                if s.ap >= s.nb:
                    break
                for k in range(4):
                    s.cpu(s.ap * 4 + k, 4)
                s.ap += 1
            s.cp = max(s.cp, s.ap)
        elif c == 1:                     # alpha run: N+1 alpha halves, dist 1 block
            n = s.varint() + 1
            for _ in range(n):
                if s.ap >= s.nb:
                    break
                s.half_copy(s.ap * 4, 4)
                s.ap += 1
        elif c == 2:                     # alpha match: u16 distance
            d = 4 * s.u16() + 8
            s.half_copy(s.ap * 4, d)
            s.ap += 1
        else:                            # alpha literal, 8 bytes
            s.half_lit(s.ap * 4)
            s.ap += 1

    # --- colour plane ------------------------------------------------------
    def colour_op(s, c):
        base = s.cp * 4 + 2
        if c == 0:                       # escape: one sub-op per u32 unit
            for k in range(2):
                sc = s.code()
                if sc == 0:
                    s.out[base + k] = s.u32()
                elif sc == 1:
                    s.cpu(base + k, 4)
                elif sc == 2:
                    s.cpu(base + k, 4 * s.u8() + 8)
                else:
                    s.cpu(base + k, 4 * (s.u16() + 256) + 8)
            s.cp += 1
        elif c == 1:
            s.half_copy(base, 4)
            s.cp += 1
        elif c == 2:
            s.half_copy(base, 4 * s.u8() + 8)
            s.cp += 1
        else:
            s.half_copy(base, 4 * (s.u16() + 256) + 8)
            s.cp += 1

    def run(s, limit=None):
        while s.ap < s.nb or s.cp < s.nb:
            c = s.code()
            if s.ap <= s.cp and s.ap < s.nb:
                s.alpha_op(c)
            else:
                s.colour_op(c)
            if limit and s.p > limit:
                break
        return s

    def texture(s):
        o = bytearray()
        for u in s.out:
            o += struct.pack('<I', u)
        return bytes(o)


# --- scoring ---------------------------------------------------------------
EXP5 = [0,8,16,25,33,41,49,58,66,74,82,90,99,107,115,123,132,140,148,156,164,173,181,189,197,205,214,222,230,238,247,255]
EXP6 = [0,4,8,12,16,20,24,28,32,36,40,45,49,53,57,61,65,69,73,77,81,85,89,93,97,101,105,109,113,117,121,125,130,134,138,142,146,150,154,158,162,166,170,174,178,182,186,190,194,198,202,206,210,214,219,223,227,231,235,239,243,247,251,255]


def exp565(c):
    return (EXP5[(c >> 11) & 31], EXP6[(c >> 5) & 63], EXP5[c & 31])


def unp(c, a):
    return c if a == 0 else min(255, (c * 255) // a)


def atab(a0, a1):
    t = [a0, a1]
    if a0 > a1:
        t += [((6 - i) * a0 + (1 + i) * a1) // 7 for i in range(6)]
    else:
        t += [((4 - i) * a0 + (1 + i) * a1) // 5 for i in range(4)] + [0, 255]
    return t


def block_rgba(b16):
    at = atab(b16[0], b16[1]); ab = int.from_bytes(b16[2:8], 'little')
    c0, c1, idx = struct.unpack_from('<HHI', b16, 8)
    A = exp565(c0); B = exp565(c1)
    pal = [A, B, tuple((2 * A[i] + B[i]) // 3 for i in range(3)),
           tuple((A[i] + 2 * B[i]) // 3 for i in range(3))]
    out = []
    for t in range(16):
        al = at[(ab >> (3 * t)) & 7]; c = pal[(idx >> (2 * t)) & 3]
        out.append((unp(c[0], al), unp(c[1], al), unp(c[2], al), al))
    return out


def ff_rgba(path, n):
    t = tempfile.mktemp(suffix='.raw')
    subprocess.run(['ffmpeg', '-y', '-nostdin', '-v', 'error', '-i', path, '-frames:v', str(n),
                    '-f', 'rawvideo', '-pix_fmt', 'rgba', t], check=True, capture_output=True)
    d = open(t, 'rb').read(); os.unlink(t); return d


def dims(path):
    o = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                        'stream=width,height', '-of', 'csv=p=0', path],
                       capture_output=True, text=True).stdout.strip().splitlines()[0]
    return [int(x) for x in o.split(',')]


def score(path, fidx=0, ref=None, w=None, h=None, pays=None):
    if w is None:
        w, h = dims(path)
    tw = (w + 15) // 16 * 16; th = (h + 3) // 4 * 4
    bw = tw // 4; nb = bw * (th // 4)
    pay = (pays or frames(path))[fidx]
    pay = pay['payload'] if isinstance(pay, dict) else pay
    if ref is None:
        ref = ff_rgba(path, fidx + 1)[fidx * w * h * 4:(fidx + 1) * w * h * 4]
    d = Dec(pay, nb)
    err = None
    try:
        d.run()
    except Exception as e:
        err = e
    tex = d.texture()
    for b in range(nb):
        by, bx = divmod(b, bw)
        if by * 4 >= h or bx * 4 >= w:
            continue
        px = block_rgba(tex[b * 16:b * 16 + 16])
        for t in range(16):
            y, x = divmod(t, 4)
            yy, xx = by * 4 + y, bx * 4 + x
            if yy >= h or xx >= w:
                continue
            p = (yy * w + xx) * 4
            if tuple(ref[p:p + 4]) != px[t]:
                return (b, 'MISMATCH ap=%d cp=%d nb=%d byte=%d/%d err=%s' % (d.ap, d.cp, nb, d.p, len(pay), err))
    return (nb, 'ALL MATCH (byte=%d/%d err=%s)' % (d.p, len(pay), err))


if __name__ == '__main__':
    for f in sys.argv[1:]:
        print(f, score(f))
