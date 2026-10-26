import sys, xml.etree.ElementTree as ET, collections
root = ET.parse(sys.argv[1]).getroot()
seq = root.find('sequence')
files = {}
for f in seq.iter('file'):
    if f.find('pathurl') is not None:
        files[f.get('id')] = f
for kind in ('video', 'audio'):
    tracks = seq.find('media').find(kind).findall('track')
    print(kind, 'tracks:', len(tracks))
    for i, t in enumerate(tracks):
        items = t.findall('clipitem')
        fids = collections.Counter(ci.find('file').get('id') for ci in items)
        names = [ci.findtext('name') for ci in items]
        paths = set(files[ci.find('file').get('id')].findtext('pathurl').split('/')[-2] for ci in items)
        print(' ', i, len(items), 'items', len(fids), 'files', paths, names[:2], '...', names[-1:] if names else '')
        if items:
            ci = items[0]
            print('    first:', {k: ci.findtext(k) for k in ('start','end','in','out','duration')}, 'links', len(ci.findall('link')))
f0 = next(iter(files.values()))
print(ET.tostring(f0, encoding='unicode')[:2500])
