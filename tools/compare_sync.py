"""Compares two synced FCP 7 XMLs clip by clip (e.g. another app's export against Synco's).

    python3 tools/compare_sync.py a.xml b.xml [anchor-file-name]

For every media file it takes where its media starts on the timeline, in seconds
(clip start minus in point), makes both timelines relative to the anchor file
(the first recorder file by default), and prints how far apart each clip landed.
"""
import sys, xml.etree.ElementTree as ET
from collections import Counter


def placements(path):
    seq = next(ET.parse(path).getroot().iter('sequence'))
    tb = int(seq.find('rate/timebase').text)
    out, labels = {}, {}
    names = {}
    for kind in ('video', 'audio'):
        for track in seq.find('media').find(kind).findall('track'):
            for c in track.findall('clipitem'):
                f = c.find('file')
                if f is None:
                    continue
                fid = f.get('id')
                n = f.findtext('name')
                if n:
                    names[fid] = n
                name = names.get(fid) or c.findtext('name')
                start, inp = int(c.findtext('start')), int(c.findtext('in') or 0)
                if start < 0:
                    continue
                t = (start - inp) / tb
                out.setdefault(name, t)
                lab = c.findtext('labels/label2')
                if lab:
                    labels.setdefault(name, lab)
    return out, labels, tb


a, la, tba = placements(sys.argv[1])
b, lb, tbb = placements(sys.argv[2])
common = sorted(set(a) & set(b))
anchor = sys.argv[3] if len(sys.argv) > 3 else sorted(n for n in common if n.lower().endswith('.wav'))[0]
fps = 25.0
rows = []
for n in common:
    d = (b[n] - b[anchor]) - (a[n] - a[anchor])
    rows.append((n, d, la.get(n, ''), lb.get(n, '')))
print(f'clips en común: {len(common)}  (solo en A: {len(set(a) - set(b))}, solo en B: {len(set(b) - set(a))})  ancla: {anchor}')
print('etiquetas A:', dict(Counter(la.values())), ' B:', dict(Counter(lb.values())))
buckets = Counter()
for n, d, x, y in rows:
    f = abs(d) * fps
    buckets['≤1 cuadro' if f <= 1.0 else '1–2 cuadros' if f <= 2 else '2 cuadros–1 s' if abs(d) <= 1 else '> 1 s'] += 1
print('diferencia de ubicación (a 25 cps):', dict(buckets))
print('\nclips que difieren más de 2 cuadros:')
for n, d, x, y in sorted(rows, key=lambda r: -abs(r[1])):
    if abs(d) * fps > 2:
        print(f'  {n:28s} {d:+9.3f} s   A:{x or "-":10s} B:{y or "-"}')
