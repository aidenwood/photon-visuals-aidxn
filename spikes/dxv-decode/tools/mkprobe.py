#!/usr/bin/env python3
"""Generate a raw RGBA frame -> dxv .mov probe, extract payload, print summary."""
import subprocess, sys, os, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBES = os.path.join(ROOT, 'probes')
os.makedirs(PROBES, exist_ok=True)

def encode(name, w, h, rgba_bytes, codec='dxv', extra=None):
    raw = os.path.join(PROBES, name + '.raw')
    mov = os.path.join(PROBES, name + '.mov')
    with open(raw, 'wb') as f:
        f.write(rgba_bytes)
    cmd = ['ffmpeg', '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgba',
           '-s', f'{w}x{h}', '-r', '1', '-i', raw, '-frames:v', '1',
           '-c:v', codec, '-pix_fmt', 'rgba']
    if extra:
        cmd += extra
    cmd += [mov]
    subprocess.run(cmd, check=True)
    return mov

def solid(w, h, rgba):
    return bytes(rgba) * (w * h)

def from_fn(w, h, fn):
    out = bytearray()
    for y in range(h):
        for x in range(w):
            out += bytes(fn(x, y))
    return bytes(out)
