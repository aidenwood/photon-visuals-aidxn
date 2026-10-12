import sys, os, json, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract import frames
from craft import make_mov, dxv_frame, decode_rgba
W=H=None
def setup(src, fidx=0, tag=b'DXT5', w=1920, h=1080):
    global SRC,PAY,TAG,W,H,REF
    SRC=src; PAY=frames(src)[fidx]['payload']; TAG=tag; W,H=w,h
    REF=dec(PAY)
    return PAY,REF
def dec(p):
    make_mov(SRC,'/tmp/mut.mov', dxv_frame(tag=TAG, payload=p))
    out,err=decode_rgba('/tmp/mut.mov',W,H)
    return out
def first_diff_block(a,b):
    """Return (first differing pixel index, which channels, block index) or None."""
    if a is None or b is None: return None
    n=min(len(a),len(b))
    for i in range(0,n,4):
        if a[i:i+4]!=b[i:i+4]:
            px=i//4; y,x=divmod(px,W)
            ch=''.join(c for c,j in zip('RGBA',range(4)) if a[i+j]!=b[i+j])
            bw=(W+15)//16*16//4
            blk=(y//4)*bw+(x//4)
            return (px,x,y,ch,blk)
    return None
