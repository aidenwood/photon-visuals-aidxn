import sys, os, re, struct, subprocess, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract import frames
from craft import make_mov, dxv_frame
RX=re.compile(r'idx (\d+) > (\d+)')
SRC=None
def setup(src): 
    global SRC; SRC=src
def run(payload, tag=b'DXT5'):
    make_mov(SRC,'/tmp/p5.mov', dxv_frame(tag=tag, payload=payload))
    r=subprocess.run(['ffmpeg','-y','-v','trace','-i','/tmp/p5.mov','-frames:v','1',
                      '-f','rawvideo','-pix_fmt','rgba','/tmp/p5.raw'],capture_output=True,text=True)
    m=RX.search(r.stderr)
    if m: return ('ERR', int(m.group(1)), int(m.group(2)))
    if r.returncode==0: return ('OK', None, None)
    return ('FAIL', None, None)
