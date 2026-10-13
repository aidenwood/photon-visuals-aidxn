#!/usr/bin/env python3
"""YCG6 byte -> block-cursor map: flip each sampled payload byte and report the index
of the first Y/Co/Cg block that changes. This is what proved the first sub-stream is
ONE monotone cursor over [8, h0) with no discontinuity at align4(h1)."""
import sys,struct; sys.path.insert(0,'tools')
from yclab import Lab
from extract import frames
pay=bytes(frames('yc/ycg6_ringmask3.mov')[0]['payload'])
L=Lab('probes3/t_2560x1080.mov',2560,1080)
W=2560; BW=W//4; CW=1280; CBW=CW//4
base=L.run(pay)[3]
BP=L.planes(base)
def fb(Y,BY,w,bw):
    for i in range(len(Y)):
        if Y[i]!=BY[i]:
            r,c=divmod(i,w); return (r//4)*bw + c//4
    return None
step=int(sys.argv[1]); 
for p in range(8,len(pay),step):
    out=[None,None,None]
    for x in (0x01,0x10,0x55,0x80):
        q=bytearray(pay); q[p]^=x
        s=L.run(bytes(q))
        if s[0]!='OK': continue
        P=L.planes(s[3])
        v=[fb(P['Y'],BP['Y'],W,BW), fb(P['Co'],BP['Co'],CW,CBW), fb(P['Cg'],BP['Cg'],CW,CBW)]
        for i in range(3):
            if v[i] is not None: out[i]=v[i] if out[i] is None else min(out[i],v[i])
    print(p, out, flush=True)
