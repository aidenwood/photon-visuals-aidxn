#!/usr/bin/env python3
"""YCG6/YG10 byte-mutation harness.

Copies a real .mov, patches bytes inside frame 0's payload, decodes frame 0 with
ffmpeg to planar yuv420p/yuva420p (ffmpeg emits YCoCg planes, NOT RGB, for these
tags), and reports which plane/sample first differs from the unmutated baseline.
"""
import sys, os, struct, subprocess, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract import frames

class Lab:
    def __init__(self, path, w, h, alpha=False, nframes=1):
        self.src = path; self.w = w; self.h = h; self.alpha = alpha
        self.buf = bytearray(open(path, 'rb').read())
        self.fr = frames(path)
        self.pf = 'yuva420p' if alpha else 'yuv420p'
        self.nf = nframes
        self.psz = w*h + 2*((w+1)//2)*((h+1)//2) + (w*h if alpha else 0)

    def off(self, i=0):
        return self.fr[i]['offset'] + 12

    def decode(self, buf=None, n=None):
        n = n or self.nf
        tmp = '/tmp/ycmut.mov'
        open(tmp, 'wb').write(bytes(buf if buf is not None else self.buf))
        r = subprocess.run(['ffmpeg','-y','-nostdin','-v','error','-i',tmp,'-frames:v',str(n),
                            '-f','rawvideo','-pix_fmt',self.pf,'/tmp/ycmut.raw'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return None, r.stderr
        return open('/tmp/ycmut.raw','rb').read(), r.stderr

    def planes(self, d, i=0):
        w,h = self.w, self.h; cw,ch = (w+1)//2,(h+1)//2
        b = d[i*self.psz:(i+1)*self.psz]
        o = 0; out = {}
        out['Y'] = b[o:o+w*h]; o += w*h
        out['Co'] = b[o:o+cw*ch]; o += cw*ch
        out['Cg'] = b[o:o+cw*ch]; o += cw*ch
        if self.alpha: out['A'] = b[o:o+w*h]
        return out

    def patch(self, pos, val, frame=0):
        b = bytearray(self.buf)
        b[self.off(frame)+pos] = val
        return b

def firstdiff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]: return i
    return -1
