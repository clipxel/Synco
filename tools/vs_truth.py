"""How many clips a synced XML placed right, against a reference result taken as the truth.

    python3 tools/vs_truth.py verdad.xml resultado.xml [etiquetas-sincronizadas...]

Only clips labelled as synced in each file count (default: Blue, Yellow, Iris, Caribbean).
A result can be shifted as a whole, so what is compared is each clip's position minus the
most common offset; clips within 2 frames (80 ms) of it are right.
"""
import sys, xml.etree.ElementTree as ET, collections

SYNCED = set(sys.argv[3:]) or {"Blue", "Yellow", "Iris", "Caribbean"}

def placed(path):
    r = ET.parse(path).getroot(); s = next(r.iter('sequence'))
    tb = int(s.findtext('rate/timebase')); names = {}; out = {}
    for f in r.iter('file'):
        if f.findtext('name'): names[f.get('id')] = f.findtext('name')
    for c in s.iter('clipitem'):
        f = c.find('file')
        n = names.get(f.get('id')) if f is not None else None
        if not n or n in out: continue
        start, inp = int(c.findtext('start')), int(c.findtext('in') or 0)
        if start < 0: continue
        out[n] = ((start - inp) / tb, c.findtext('labels/label2'))
    return out

truth, result = placed(sys.argv[1]), placed(sys.argv[2])
common = [n for n in result if result[n][1] in SYNCED and n in truth and truth[n][1] in {"Blue"}]
claimed = [n for n in result if result[n][1] in SYNCED]
offsets = {n: result[n][0] - truth[n][0] for n in common}
best, right = 0.0, []
for n, d in offsets.items():
    hits = [m for m, e in offsets.items() if abs(e - d) <= 0.08]
    if len(hits) > len(right): best, right = d, hits
wrong = sorted((n for n in common if n not in right), key=lambda n: -abs(offsets[n] - best))
print(f"dice sincronizados: {len(claimed)} · comparables con la verdad: {len(common)} · bien (±2 cuadros): {len(right)} · mal: {len(wrong)}")
for n in wrong[:12]:
    print(f"  mal: {n:30s} {offsets[n] - best:+9.2f} s")
