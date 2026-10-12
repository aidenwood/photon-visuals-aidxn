import sys, os, struct, subprocess, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract import frames
from dxv import decompress_dxt1
R5=[0,8,16,25,33,41,49,58,66,74,82,90,99,107,115,123,132,140,148,156,164,173,181,189,197,205,214,222,230,238,247,255]
G6=[0,4,8,12,16,20,24,28,32,36,40,45,49,53,57,61,65,69,73,77,81,85,89,93,97,101,105,109,113,117,121,125,130,134,138,142,146,150,154,158,162,166,170,174,178,182,186,190,194,198,202,206,210,214,219,223,227,231,235,239,243,247,251,255]
def exp565(c): return (R5[(c>>11)&31], G6[(c>>5)&63], R5[c&31])
def pal(c0,c1):
    a=exp565(c0); b=exp565(c1)
    if c0>c1: return [a+(255,),b+(255,),tuple((2*a[i]+b[i])//3 for i in range(3))+(255,),tuple((a[i]+2*b[i])//3 for i in range(3))+(255,)]
    return [a+(255,),b+(255,),tuple((a[i]+b[i])//2 for i in range(3))+(255,),(0,0,0,255)]
def bc1_to_rgba(bc, tw, th, w, h):
    out=bytearray(w*h*4); bw=tw//4
    for by in range((h+3)//4):
        for bx in range((w+3)//4):
            c0,c1,idx = struct.unpack_from('<HHI', bc, (by*bw+bx)*8)
            p=pal(c0,c1)
            for y in range(4):
                yy=by*4+y
                if yy>=h: break
                for x in range(4):
                    xx=bx*4+x
                    if xx>=w: break
                    o=(yy*w+xx)*4
                    out[o:o+4]=bytes(p[(idx>>(2*(y*4+x)))&3])
    return bytes(out)
def ff_rgba(mov, nframes=1):
    t=tempfile.mktemp(suffix='.raw')
    subprocess.run(['ffmpeg','-y','-v','error','-i',mov,'-frames:v',str(nframes),'-f','rawvideo','-pix_fmt','rgba',t],check=True)
    d=open(t,'rb').read(); os.unlink(t); return d
def dims(mov):
    o=subprocess.run(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=width,height','-of','csv=p=0',mov],capture_output=True,text=True).stdout.strip()
    w,h=o.split(','); return int(w),int(h)
def align(v,a): return (v+a-1)//a*a
def verify(mov, talign=4, nframes=None):
    w,h=dims(mov); fs=frames(mov)
    if nframes: fs=fs[:nframes]
    tw,th = align(w,talign), align(h,talign)
    ref = ff_rgba(mov, len(fs))
    fsz = w*h*4
    res=[]
    for i,f in enumerate(fs):
        nunits=(tw//4)*(th//4)*2
        bc = decompress_dxt1(f['payload'], nunits) if f['cflag']==0 else f['payload']
        mine = bc1_to_rgba(bc, tw, th, w, h)
        r = ref[i*fsz:(i+1)*fsz]
        res.append(mine==r if len(r)==fsz else None)
    return w,h,res
