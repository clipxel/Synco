import sys, xml.etree.ElementTree as ET
src = ET.parse(sys.argv[1]).getroot().find('sequence')
out = ET.parse(sys.argv[2]).getroot().find('sequence')
def items(seq):
    r = {}
    for kind in ('video', 'audio'):
        for ti, t in enumerate(seq.find('media').find(kind).findall('track')):
            for ci, c in enumerate(t.findall('clipitem')):
                r[c.get('id')] = (kind, ti + 1, ci + 1, c)
    return r
a, b = items(src), items(out)
print('clipitems', len(a), '->', len(b), 'iguales' if set(a) == set(b) else 'DISTINTOS')
bad_links = overlaps = trims = 0
for cid, (kind, t, i, c) in b.items():
    o = a[cid][3]
    for k in ('in', 'out', 'duration'):
        if c.findtext(k) != o.findtext(k): trims += 1
    if int(c.findtext('end')) - int(c.findtext('start')) != int(o.findtext('end')) - int(o.findtext('start')): trims += 1
    for l in c.findall('link'):
        ref = l.findtext('linkclipref'); lk, lt, li, _ = b[ref]
        if int(l.findtext('trackindex')) != lt or int(l.findtext('clipindex')) != li or l.findtext('mediatype') != lk: bad_links += 1
# linked items must start together
starts = {}
for cid, (kind, t, i, c) in b.items():
    fid = c.find('file').get('id'); starts.setdefault(fid, set()).add(int(c.findtext('start')) - int(c.findtext('in')))
split = sum(1 for v in starts.values() if len(v) > 1)
for kind in ('video', 'audio'):
    for t in out.find('media').find(kind).findall('track'):
        cs = [(int(c.findtext('start')), int(c.findtext('end')), c.findtext('name')) for c in t.findall('clipitem')]
        for x, y in zip(cs, cs[1:]):
            if y[0] < x[0]: print('desordenado', x, y)
            if y[0] < x[1]: overlaps += 1; print('solape', kind, x, y)
print('links mal:', bad_links, '| recortes cambiados:', trims, '| clips con pistas desfasadas entre sí:', split, '| solapes:', overlaps)
print('duración secuencia:', out.findtext('duration'), 'cuadros =', int(out.findtext('duration')) / 24 / 3600, 'h')
