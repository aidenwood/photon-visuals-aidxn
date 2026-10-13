"""Python port of the VERIFIED Rust decompress_dxt5 (two-plane DXTR5 scheme)."""
import struct

class R:
    __slots__=('b','p','mask','nbits')
    def __init__(s,b): s.b=b; s.p=0; s.mask=0; s.nbits=0
    def u8(s):
        v=s.b[s.p]; s.p+=1; return v
    def u16(s):
        v=s.b[s.p]|(s.b[s.p+1]<<8); s.p+=2; return v
    def u32(s):
        v=struct.unpack_from('<I',s.b,s.p)[0]; s.p+=4; return v
    def varint(s):
        n=s.u8()
        if n==0xff:
            while True:
                w=s.u16(); n+=w
                if w!=0xffff: break
        return n
    def op(s):
        if s.nbits==0: s.mask=s.u32(); s.nbits=32
        c=s.mask&3; s.mask>>=2; s.nbits-=2; return c

def dxt5(payload, nunits):
    nb=nunits//4
    out=[0]*nunits
    r=R(payload)
    for i in range(4): out[i]=r.u32()
    ap=cp=1
    def cu(pos,d):
        if d==0 or d>pos: raise ValueError(f'idx {d} > {pos}')
        out[pos]=out[pos-d]
    while ap<nb or cp<nb:
        c=r.op()
        if ap<=cp and ap<nb:
            if c==0:
                n=r.varint()+1
                for _ in range(n):
                    if ap>=nb: break
                    for k in range(4): cu(ap*4+k,4)
                    ap+=1
                if cp<ap: cp=ap
            elif c==1:
                n=r.varint()+1
                for _ in range(n):
                    if ap>=nb: break
                    cu(ap*4,4); cu(ap*4+1,4); ap+=1
            elif c==2:
                d=4*r.u16()+8; cu(ap*4,d); cu(ap*4+1,d); ap+=1
            else:
                out[ap*4]=r.u32(); out[ap*4+1]=r.u32(); ap+=1
        else:
            base=cp*4+2
            if c==0:
                for k in range(2):
                    s_=r.op()
                    if s_==0: out[base+k]=r.u32()
                    elif s_==1: cu(base+k,4)
                    elif s_==2: cu(base+k,4*r.u8()+8)
                    else: cu(base+k,4*(r.u16()+256)+8)
            elif c==1:
                cu(base,4); cu(base+1,4)
            elif c==2:
                d=4*r.u8()+8; cu(base,d); cu(base+1,d)
            else:
                d=4*(r.u16()+256)+8; cu(base,d); cu(base+1,d)
            cp+=1
    return b''.join(struct.pack('<I',v) for v in out), r.p

def bc4_block(b):
    a0,a1=b[0],b[1]
    bits=int.from_bytes(b[2:8],'little')
    if a0>a1: t=[a0,a1]+[((7-i)*a0+i*a1)//7 for i in range(1,7)]
    else: t=[a0,a1]+[((5-i)*a0+i*a1)//5 for i in range(1,5)]+[0,255]
    return [t[(bits>>(3*i))&7] for i in range(16)]
