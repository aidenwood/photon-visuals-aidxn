# RETIRED 2026-10-13: encodes the SINGLE-CURSOR DXT5 model, which is DISPROVEN.
# DXT5 has two plane cursors - see src/dxv.rs::decompress_dxt5 and tools/d5dec.py.
# Kept only as a record of how the wrong model was scored. Do not import.

"""Characterise one DXT5 op: byte consumption, units emitted, and (for matches) distance.

Method. Build a long history of blocks with distinct alphas using only verified ops,
park the cursor at a known unit, run the op under test with a controlled data tail of
distinct marker bytes, then run a PROBE op of code 11.

  * cursor left MID   -> code 11 is a LONG match; ffmpeg's `idx N > M` trace gives
                         N = 4*(v+256)+8 with v = LE u16 at the probe's read offset,
                         and M = the cursor. Offset -> bytes consumed by the test op.
  * cursor left ALIGNED -> code 11 is an 8-byte literal; the alpha it writes is the
                         marker byte at the probe's read offset, and the block it lands
                         in gives the cursor.

Both branches therefore report (bytes consumed, cursor) exactly.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from d5lab import *

MARK = bytes(range(0x21, 0x21 + 24))   # distinct, non-0xff, usable as alpha markers
HIST = 300


def hist_alpha(k):
    return (k % 251) + 1


def characterise(code, data_prefix=b'', mid=False, nhist=HIST, verbose=False):
    b = Build()
    history(b, nhist)
    pos = 4 * (nhist + 1)
    if mid:
        b.op(3, alpha_half(0xAA))      # aligned literal -> cursor to colour half
        pos += 2
    b.op(code, data_prefix + MARK)
    b.op(3, b'')                       # probe
    while len(b.ops) % 16:
        b.op(1)
    st, n, m, raw = run(b.build(tail=b'\0' * 40000))
    if st == 'ERR':
        v = (n - 8) // 4 - 256
        lo = v & 0xff
        hi = (v >> 8) & 0xff
        try:
            off = MARK.index(bytes([lo, hi]))
        except ValueError:
            off = None
        return dict(start=pos, cursor=m, emitted=m - pos, consumed=(off - len(data_prefix)) if off is not None else None,
                    align='mid', rawv=v, n=n)
    if st != 'OK' or raw is None or len(raw) < W * H * 4:
        return dict(start=pos, err=st)
    bl = blocks(raw)
    # find the block whose alpha is one of the marker bytes -> literal landed there
    for i in range(nhist - 2, nhist + 40):
        a = bl[i][0]
        if a in MARK:
            off = MARK.index(a)
            cur = 4 * i
            return dict(start=pos, cursor=cur, emitted=cur - pos,
                        consumed=off - len(data_prefix), align='aligned', alpha=a)
    return dict(start=pos, alphas=[x[0] for x in bl[nhist - 2:nhist + 12]], note='no marker found')
