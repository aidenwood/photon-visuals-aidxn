#!/usr/bin/env python3
"""YCG6 opcode-byte scan: for every value 0..255 of the byte that follows a completed
block record, try several operand lengths and report which decode and what block they
produce. Result (2026-10-13): only 0x00 (8-byte whole-block literal) and 0xDE
(5-byte [a0][a1][idx3][idx4][idx5], index bytes 0..2 inherited) accept non-zero
operands. See decompress_ycocg in src/dxv.rs."""
import sys,struct,json; sys.path.insert(0,'tools')
from yclab2 import CHROMA, bc4
from yclab import Lab
L=Lab('probes3/t_64x64.mov',64,64); W=64
PREV=bytes([77,10,0x49,0x92,0x24,0x49,0x92,0x24])
pre=bc4(200,200)+bytes([244])+PREV          # blocks 0..248 = 200, 249 = PREV
D=bytes(range(0xA1,0xA1+32))
def blk(Y,b):
    by,bx=divmod(b,16); p=by*4*W+bx*4
    return [Y[p+r*W+c] for r in range(4) for c in range(4)]
res={}
for F in range(256):
    hits=[]
    for k in (1,2,3,4,5,6,7,8,9,10,12,16,20):
        st=pre+bytes([F])+D[:k]+b'\x00'*64
        s=L.run(struct.pack('<2I',8+len(st),64)+st+CHROMA)
        if s[0]!='OK': continue
        Y=L.planes(s[3])['Y']
        hits.append((k,blk(Y,250),blk(Y,251)))
    if hits: res[F]=hits
    print(F,len(hits),flush=True)
json.dump({str(k):v for k,v in res.items()}, open('/tmp/opscan2.json','w'))
