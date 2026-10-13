#!/usr/bin/env python3
"""Score a candidate YCG6 Y-plane decoder against ffmpeg's own output.

ffmpeg emits YCG6 as planar yuv420p tagged `ycgco` (it does NOT convert to RGB),
so plane 0 IS the BC4-decoded Y texture, cropped to the frame. A candidate
texture is scored by the index of the first block whose 16 decoded texels differ.
"""
import sys, os, struct, subprocess, pickle
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def ref_y(path, w, h, frame=0, cache='/tmp/yref.pkl'):
    key = (path, w, h, frame)
    try:
        d = pickle.load(open(cache,'rb'))
        if d['key'] == key: return d['y']
    except Exception: pass
    subprocess.run(['ffmpeg','-y','-nostdin','-v','error','-i',path,'-frames:v',str(frame+1),
                    '-f','rawvideo','-pix_fmt','yuv420p','/tmp/yref.raw'], check=True)
    sz = w*h*3//2
    b = open('/tmp/yref.raw','rb').read()[frame*sz:(frame+1)*sz]
    y = b[:w*h]
    pickle.dump({'key':key,'y':y}, open(cache,'wb'))
    return y

def bc4_texels(b, o):
    a0, a1 = b[o], b[o+1]
    bits = int.from_bytes(b[o+2:o+8], 'little')
    if a0 > a1:
        t = [a0, a1] + [((7-i)*a0 + i*a1)//7 for i in range(1, 7)]
    else:
        t = [a0, a1] + [((5-i)*a0 + i*a1)//5 for i in range(1, 5)] + [0, 255]
    return [t[(bits >> (3*i)) & 7] for i in range(16)]

def ref_blocks(y, w, h):
    bw = w//4
    out = []
    for bi in range(bw*(h//4)):
        by, bx = divmod(bi, bw)
        p = by*4*w + bx*4
        out.append([y[p+r*w+c] for r in range(4) for c in range(4)])
    return out

def first_bad(tex, rb):
    for i, want in enumerate(rb):
        if 8*i+8 > len(tex): return i
        if bc4_texels(tex, 8*i) != want: return i
    return len(rb)
