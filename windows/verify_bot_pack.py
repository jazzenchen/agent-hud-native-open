"""Verify packed asset hashes and sampled premultiplied pixels against CI PNGs."""
import argparse,hashlib,json
from pathlib import Path
from PySide6.QtGui import QImage
from bot_player import BotLibrary


def verify(source,packed):
    source=Path(source);packed=Path(packed)
    manifest=json.loads((source/'manifest.json').read_text(encoding='utf-8'))
    provenance=json.loads((packed/'provenance.json').read_text(encoding='utf-8'))
    for name,digest in provenance['files'].items():
        if Path(name).name!=name:raise ValueError('Invalid packed file name')
        if hashlib.sha256((packed/name).read_bytes()).hexdigest()!=digest:raise ValueError('Hash mismatch: '+name)
    keys=list(dict.fromkeys(frame['image'] for clip in manifest['clips'] for frame in clip['frames']))
    lib=BotLibrary(packed)
    if not lib.ready or len(keys)!=len(lib.images) or len(lib.clips)!=len(manifest['clips']):raise ValueError('Incomplete pack')
    indices=sorted({n*(len(keys)-1)//119 for n in range(120)})
    for index in indices:
        original=QImage(str(source/'images'/(keys[index]+'.png'))).convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)
        converted=lib.image(index).convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)
        if original.isNull() or converted!=original:raise ValueError('Pixel mismatch: '+keys[index])
    return dict(files_verified=len(provenance['files']),pixel_samples=len(indices),
                images=len(keys),clips=len(lib.clips),upstream_revision=manifest['upstreamRevision'])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('source');parser.add_argument('packed')
    args=parser.parse_args();print(json.dumps(verify(args.source,args.packed)))
