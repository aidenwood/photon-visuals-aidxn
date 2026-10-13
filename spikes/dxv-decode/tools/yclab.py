#!/usr/bin/env python3
"""YCG6 / YG10 experiment lab.

Crafts a single compressed DXV frame with the given tag and payload, runs ffmpeg
at -v trace, and returns either the `idx N > M` fault or the decoded planar
YCoCg frame. ffmpeg emits yuv420p (YCG6) / yuva420p (YG10) tagged `ycgco`; it does
NOT do the YCoCg->RGB conversion, so these planes are the verification target.
"""
import sys, os, re, struct, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft import make_mov, dxv_frame

RX = re.compile(r'idx (\d+) > (\d+)')

class Lab:
    def __init__(self, tmpl, w, h, tag=b'YCG6'):
        self.tmpl, self.w, self.h, self.tag = tmpl, w, h, tag
        self.alpha = (tag == b'YG10')
        self.pf = 'yuva420p' if self.alpha else 'yuv420p'

    def run(self, payload, cflag=0):
        make_mov(self.tmpl, '/tmp/yclab.mov', dxv_frame(tag=self.tag, cflag=cflag, payload=payload))
        r = subprocess.run(['ffmpeg','-y','-nostdin','-v','trace','-i','/tmp/yclab.mov',
                            '-frames:v','1','-f','rawvideo','-pix_fmt',self.pf,'/tmp/yclab.raw'],
                           capture_output=True, text=True)
        m = RX.search(r.stderr)
        if m: return ('ERR', int(m.group(1)), int(m.group(2)), None)
        if r.returncode != 0: return ('FAIL', None, None, r.stderr)
        return ('OK', None, None, open('/tmp/yclab.raw','rb').read())

    def planes(self, d):
        w,h = self.w,self.h; cw,ch = w//2,h//2
        o=0; out={}
        out['Y']=d[o:o+w*h]; o+=w*h
        out['Co']=d[o:o+cw*ch]; o+=cw*ch
        out['Cg']=d[o:o+cw*ch]; o+=cw*ch
        if self.alpha: out['A']=d[o:o+w*h]
        return out
