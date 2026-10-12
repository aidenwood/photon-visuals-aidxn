"""Single-step tracer for the DXT5 op stream.

For a candidate op-code sequence it reports, after every op, the exact output cursor
and the exact number of data bytes consumed so far.

How. The history is kept short (default 20 blocks -> cursor 84) so that a code-10
SHORT with a large byte is ALWAYS an out-of-range back-reference. ffmpeg then prints
`idx N > M` with N = the computed distance and M = the cursor, which gives:

    cursor        = M
    bytes consumed = (N - 8)/4 - 0x40      (the probe's byte is a marker, 0x40 + offset)

Markers are 0x40.. so every probe distance (4*0x40+8 = 264 upward) stays out of range.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from d5lab import Build, history, run, alpha_half, colour_half, W, H, blocks

MARK = bytes(range(0x40, 0x40 + 48))
NHIST = 20


def step(codes, nhist=NHIST, datas=None):
    """codes: list of 2-bit op codes. Returns (cursor, bytes_consumed) after them all."""
    b = Build()
    history(b, nhist)
    for i, c in enumerate(codes):
        b.op(c, (datas[i] if datas else b''))
    b.op(2, MARK)                      # probe
    while len(b.ops) % 16:
        b.op(1)
    st, n, m, raw = run(b.build(tail=b'\0' * 40000))
    if st != 'ERR':
        return None, None, st
    off = (n - 8) // 4 - 0x40
    return m, off, 'ERR'


def trace(codes, nhist=NHIST, datas=None):
    out = []
    base = 4 * (nhist + 1)
    prev = (base, 0)
    for k in range(len(codes) + 1):
        cur, off, st = step(codes[:k], nhist, datas[:k] if datas else None)
        out.append((k, cur, off, st))
    return out


if __name__ == '__main__':
    for row in trace([int(c) for c in sys.argv[1]]):
        print(row)
