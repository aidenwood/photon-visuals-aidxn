import sys, os, re, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft import oracle
RX = re.compile(r'idx (\d+) > (\d+)')
def run(template, w, h, payload):
    out, err = oracle(template, w, h, payload)
    m = RX.search(err or '')
    if m: return ('ERR', int(m.group(1)), int(m.group(2)))
    if out is None: return ('FAIL', err.strip()[:120], None)
    return ('OK', out, None)
