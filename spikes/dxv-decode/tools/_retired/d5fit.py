# RETIRED 2026-10-13: encodes the SINGLE-CURSOR DXT5 model, which is DISPROVEN.
# DXT5 has two plane cursors - see src/dxv.rs::decompress_dxt5 and tools/d5dec.py.
# Kept only as a record of how the wrong model was scored. Do not import.

"""Score a candidate DXT5 op table by how many leading BC3 blocks it reproduces.

Decodes a real payload with the candidate table, converts each block to RGBA with the
verified BC3 maths, and compares against ffmpeg's own RGBA output for the same frame.
Returns the index of the first block that differs.
"""
import sys, os, struct, subprocess, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract import frames

EXP5=[0,8,16,25,33,41,49,58,66,74,82,90,99,107,115,123,132,140,148,156,164,173,181,189,197,205,214,222,230,238,247,255]
EXP6=[0,4,8,12,16,20,24,28,32,36,40,45,49,53,57,61,65,69,73,77,81,85,89,93,97,101,105,109,113,117,121,125,130,134,138,142,146,150,154,158,162,166,170,174,178,182,186,190,194,198,202,206,210,214,219,223,227,231,235,239,243,247,251,255]
def exp565(c): return (EXP5[(c>>11)&31], EXP6[(c>>5)&63], EXP5[c&31])
def unp(c,a): return c if a==0 else min(255,(c*255)//a)
def atab(a0,a1):
    t=[a0,a1]
    if a0>a1: t += [((6-i)*a0+(1+i)*a1)//7 for i in range(6)]
    else:     t += [((4-i)*a0+(1+i)*a1)//5 for i in range(4)] + [0,255]
    return t
def block_rgba(b16):
    at=atab(b16[0],b16[1]); ab=int.from_bytes(b16[2:8],'little')
    c0,c1,idx = struct.unpack_from('<HHI', b16, 8)
    A=exp565(c0); B=exp565(c1)
    pal=[A,B,tuple((2*A[i]+B[i])//3 for i in range(3)),tuple((A[i]+2*B[i])//3 for i in range(3))]
    out=[]
    for t in range(16):
        al=at[(ab>>(3*t))&7]; c=pal[(idx>>(2*t))&3]
        out.append((unp(c[0],al),unp(c[1],al),unp(c[2],al),al))
    return out

def ff_rgba(path, n=1):
    t=tempfile.mktemp(suffix='.raw')
    subprocess.run(['ffmpeg','-y','-nostdin','-v','error','-i',path,'-frames:v',str(n),
                    '-f','rawvideo','-pix_fmt','rgba',t],check=True,capture_output=True)
    d=open(t,'rb').read(); os.unlink(t); return d

class Dec:
    """Table: ALIGNED / MID dicts mapping code -> handler(self)."""
    def __init__(self, pay, nunits, A, M):
        self.b=pay; self.p=0; self.m=0; self.n=0
        self.out=[0]*nunits; self.nu=nunits; self.A=A; self.M=M
        for i in range(4): self.out[i]=struct.unpack_from('<I',pay,self.p)[0]; self.p+=4
        self.pos=4
    def u8(s):
        v=s.b[s.p]; s.p+=1; return v
    def u16(s):
        v=s.b[s.p]|(s.b[s.p+1]<<8); s.p+=2; return v
    def u32(s):
        v=struct.unpack_from('<I',s.b,s.p)[0]; s.p+=4; return v
    def varint(s):
        n=0
        while True:
            x=s.b[s.p]; s.p+=1; n+=x
            if x!=0xff: return n
    def emit_copy(s,dist,units):
        if dist>s.pos or dist<=0: raise ValueError(f'dist {dist} > {s.pos}')
        for _ in range(units):
            if s.pos>=s.nu: return
            s.out[s.pos]=s.out[s.pos-dist]; s.pos+=1
    def emit_lit(s,units):
        for _ in range(units):
            if s.pos>=s.nu: return
            s.out[s.pos]=s.u32(); s.pos+=1
    def run(s):
        while s.pos<s.nu:
            if s.n==0: s.m=s.u32(); s.n=32
            c=s.m&3; s.m>>=2; s.n-=2
            (s.A if s.pos%4==0 else s.M)[c](s)
        return s
def texture(dec):
    out=bytearray()
    for u in dec.out: out += struct.pack('<I',u)
    return bytes(out)

def score(path, A, M, fidx=0, maxblocks=None):
    import subprocess
    o=subprocess.run(['ffprobe','-v','error','-select_streams','v:0','-show_entries',
                      'stream=width,height','-of','csv=p=0',path],capture_output=True,text=True).stdout.strip().splitlines()[0]
    w,h=[int(x) for x in o.split(',')]
    tw=(w+15)//16*16; th=(h+3)//4*4
    bw=tw//4; nb=bw*(th//4)
    pay=frames(path)[fidx]['payload']
    ref=ff_rgba(path, fidx+1)[fidx*w*h*4:(fidx+1)*w*h*4]
    d=Dec(pay, nb*4, A, M)
    err=None
    try:
        d.run()
    except Exception as e:
        err=e
    tex=texture(d)
    lim = maxblocks or nb
    for b in range(min(lim, nb)):
        by,bx=divmod(b,bw)
        if by*4>=h or bx*4>=w: continue
        px=block_rgba(tex[b*16:b*16+16])
        bad=False
        for t in range(16):
            y,x=divmod(t,4)
            yy,xx=by*4+y,bx*4+x
            if yy>=h or xx>=w: continue
            p=(yy*w+xx)*4
            if tuple(ref[p:p+4])!=px[t]: bad=True; break
        if bad:
            return (b, f'first mismatching block (decoder reached unit {d.pos}/{nb*4}, byte {d.p}/{len(pay)}, err={err})', w, h)
    return (min(lim,nb), f'all checked blocks match (unit {d.pos}/{nb*4}, byte {d.p}/{len(pay)}, err={err})', w, h)
