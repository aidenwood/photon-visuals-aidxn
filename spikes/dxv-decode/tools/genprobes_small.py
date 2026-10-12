#!/usr/bin/env python3
"""Regenerate probes/ — the small, hand-designed probe set the format was derived from.

Each probe isolates one behaviour, so a diff between two of them is readable by eye.
Run from anywhere: python3 tools/genprobes_small.py
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mkprobe import encode, solid, from_fn
from extract import frames

R = (255, 0, 0, 255)
G = (0, 255, 0, 255)
B = (0, 0, 255, 255)
K = (0, 0, 0, 255)

def blockidx(x, y, bw):
    return (y // 4) * bw + (x // 4)

PROBES = {
    # solid colours: only the first 4 bytes of the payload change -> isolates the
    # colour word from everything else
    'red64':    (64, 64, solid(64, 64, R)),
    'green64':  (64, 64, solid(64, 64, G)),
    'blue64':   (64, 64, solid(64, 64, B)),
    'black64':  (64, 64, solid(64, 64, K)),
    'red32':    (32, 32, solid(32, 32, R)),
    'red16':    (16, 16, solid(16, 16, R)),
    'red8':     (8, 8,   solid(8, 8, R)),
    'solid16':  (16, 16, solid(16, 16, R)),
    # two-colour splits -> first SHORT matches
    'lr64':     (64, 64, from_fn(64, 64, lambda x, y: R if x < 32 else G)),
    'tb64':     (64, 64, from_fn(64, 64, lambda x, y: R if y < 32 else G)),
    'vstripe4': (64, 64, from_fn(64, 64, lambda x, y: R if (x // 4) % 2 == 0 else G)),
    'hstripe4': (64, 64, from_fn(64, 64, lambda x, y: R if (y // 4) % 2 == 0 else G)),
    # a single odd block, walked across block indices 0..4 -> shows the match
    # distance encoding shifting one byte at a time
    'one_g':    (64, 64, from_fn(64, 64, lambda x, y: G if (x < 4 and y < 4) else R)),
    'one_g_b1': (64, 64, from_fn(64, 64, lambda x, y: G if (4 <= x < 8 and y < 4) else R)),
    'g0_16':    (16, 16, from_fn(16, 16, lambda x, y: G if blockidx(x, y, 4) == 0 else R)),
    'g1_16':    (16, 16, from_fn(16, 16, lambda x, y: G if blockidx(x, y, 4) == 1 else R)),
    'g2_16':    (16, 16, from_fn(16, 16, lambda x, y: G if blockidx(x, y, 4) == 2 else R)),
    'g3_16':    (16, 16, from_fn(16, 16, lambda x, y: G if blockidx(x, y, 4) == 3 else R)),
    'g4_16':    (16, 16, from_fn(16, 16, lambda x, y: G if blockidx(x, y, 4) == 4 else R)),
    'g01_16':   (16, 16, from_fn(16, 16, lambda x, y: G if blockidx(x, y, 4) < 2 else R)),
    'alt16':    (16, 16, from_fn(16, 16, lambda x, y: R if blockidx(x, y, 4) % 2 == 0 else G)),
    # every block distinct -> nearly all SPLIT + LITERAL
    'distinct16': (16, 16, from_fn(16, 16, lambda x, y: (
        blockidx(x, y, 4) * 16, 255 - blockidx(x, y, 4) * 16,
        (blockidx(x, y, 4) * 37) & 0xFF, 255))),
    'distinct64': (64, 64, from_fn(64, 64, lambda x, y: (
        blockidx(x, y, 16), 255 - blockidx(x, y, 16),
        (blockidx(x, y, 16) * 7) & 0xFF, 255))),
}

if __name__ == '__main__':
    for name, (w, h, data) in PROBES.items():
        mov = encode(name, w, h, data)
        f = frames(mov)[0]
        print(f'{name:12s} {w}x{h} tag={f["tag"]} payload={f["psize"]}')
    print(f'{len(PROBES)} probes written to probes/')
