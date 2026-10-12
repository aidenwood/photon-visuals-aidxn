"""Readable 64x64 DXT5 probe harness.
Block layout that is fully readable from RGBA:
  unit0 = a0 | a1<<8        (alpha endpoints; alpha idx bits all 0 => every texel alpha = a0)
  unit1 = 0                 (alpha indices)
  unit2 = c0 | c0<<16       (c0==c1 => flat RGB)
  unit3 = anything          (colour indices, invisible when c0==c1)
"""
import sys, os, re, struct, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft import make_mov, dxv_frame
TMPL='probes/red64.mov'; W=H=64; BW=W//4; NB=BW*(H//4)
RX=re.compile(r'idx (\d+) > (\d+)')
def run(payload, tag=b'DXT5'):
    make_mov(TMPL,'/tmp/d5.mov', dxv_frame(tag=tag, payload=payload))
    r=subprocess.run(['ffmpeg','-y','-v','trace','-i','/tmp/d5.mov','-frames:v','1',
                      '-f','rawvideo','-pix_fmt','rgba','/tmp/d5.raw'],capture_output=True,text=True)
    m=RX.search(r.stderr)
    if m: return ('ERR', int(m.group(1)), int(m.group(2)), None)
    if r.returncode!=0: return ('FAIL', None, None, None)
    return ('OK', None, None, open('/tmp/d5.raw','rb').read())
def blocks(rgba):
    """per block: (alpha, (r,g,b))"""
    out=[]
    for b in range(NB):
        by,bx=divmod(b,BW); p=((by*4)*W+bx*4)*4
        out.append((rgba[p+3], tuple(rgba[p:p+3])))
    return out
def unit_a(a0,a1=0): return struct.pack('<I', a0 | (a1<<8))
def unit_c(c0):      return struct.pack('<I', c0 | (c0<<16))
def seed(a0, c0):    return unit_a(a0)+b'\0\0\0\0'+unit_c(c0)+b'\0\0\0\0'
