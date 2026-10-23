"""Pack original macOS-rendered bot frames into lossless Windows atlases.

Input is the original-bot-animations CI artifact; no artwork is regenerated.
"""
import argparse,gzip,hashlib,json,math
from pathlib import Path
from PySide6.QtCore import Qt
from PySide6.QtGui import QImage,QPainter


def write_json(path,value):
    raw=json.dumps(value,separators=(',',':'),sort_keys=True).encode()
    path.write_bytes(gzip.compress(raw,compresslevel=9,mtime=0))


def pack(source,destination):
    source=Path(source);destination=Path(destination)
    if destination.exists() and any(destination.iterdir()):raise ValueError('Choose an empty destination')
    destination.mkdir(parents=True,exist_ok=True)
    data=json.loads((source/'manifest.json').read_text(encoding='utf-8'))
    # Keep neighboring animation frames on neighboring atlas pages. Hash sorting
    # scatters a single blinking bot across hundreds of pages and defeats caching.
    keys=list(dict.fromkeys(frame['image'] for clip in data['clips'] for frame in clip['frames']))
    first=QImage(str(source/'images'/(keys[0]+'.png')))
    if first.isNull():raise ValueError('Missing original image')
    cell=first.width();across=1024//cell;per=across*across;images={};mapping={key:index for index,key in enumerate(keys)};checks={}
    for page_number,start in enumerate(range(0,len(keys),per)):
        subset=keys[start:start+per];atlas=QImage(across*cell,math.ceil(len(subset)/across)*cell,QImage.Format.Format_ARGB32_Premultiplied);atlas.setColorSpace(first.colorSpace());atlas.fill(Qt.GlobalColor.transparent);p=QPainter(atlas)
        try:
            for offset,key in enumerate(subset):
                image=QImage(str(source/'images'/(key+'.png')))
                if image.isNull() or image.width()!=cell or image.height()!=cell:raise ValueError('Invalid source frame')
                x=(offset%across)*cell;y=(offset//across)*cell;p.drawImage(x,y,image)
                images[str(start+offset)]=dict(page=f'atlas-{page_number:04}.png',rect=[x,y,cell,cell])
        finally:p.end()
        name=f'atlas-{page_number:04}.png'
        if not atlas.save(str(destination/name),'PNG'):raise OSError('Could not save atlas')
        checks[name]=hashlib.sha256((destination/name).read_bytes()).hexdigest()
    clips=[]
    for index,clip in enumerate(data['clips']):
        frames=[{**frame,'image':mapping[frame['image']]} for frame in clip['frames']];name=f'clip-{index:04}.json.gz'
        write_json(destination/name,{**clip,'frames':frames});checks[name]=hashlib.sha256((destination/name).read_bytes()).hexdigest()
        clips.append(dict(vendor=clip['vendor'],light=clip['light'],state=clip['state'],file=name))
    write_json(destination/'manifest.json.gz',dict(version=1,markSide=data['markSide'],margin=data['margin'],images=images,clips=clips))
    checks['manifest.json.gz']=hashlib.sha256((destination/'manifest.json.gz').read_bytes()).hexdigest()
    provenance=dict(upstream='jazzenchen/agent-hud-open',upstreamRevision=data['upstreamRevision'],renderer='Unchanged BotRenderer / BotMotion / BotSpec / BotForm',fps=24,format='Lossless PNG atlases; original pose/opacity per frame',uniqueImages=len(keys),clips=len(clips),files=checks)
    (destination/'provenance.json').write_text(json.dumps(provenance,indent=2),encoding='utf-8')
    return dict(images=len(keys),clips=len(clips),bytes=sum(path.stat().st_size for path in destination.iterdir()))

if __name__=='__main__':
    args=argparse.ArgumentParser();args.add_argument('source',type=Path);args.add_argument('destination',type=Path);options=args.parse_args();print(json.dumps(pack(options.source,options.destination)))
