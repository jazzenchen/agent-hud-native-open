"""Execute the original DeepSeek helper scripts; only Windows path discovery differs.

Windows adaptation by nanhudev; upstream scripts remain in Sources/ unchanged.
"""
import math,json,os,re,shutil,struct,subprocess,textwrap
from pathlib import Path
from source_design import CORE
from providers import HIDDEN


def helper(source,pattern):
    text=(CORE/'Providers/DeepSeek'/source).read_text(encoding='utf-8')
    match=re.search(pattern,text,re.S)
    if not match:raise ValueError('Original helper script unavailable')
    return textwrap.dedent(match[1])


def run(script,args,limit=64*1024*1024):
    node=shutil.which('node.exe') or shutil.which('node')
    if not node:raise RuntimeError('Node engine not found')
    env={k:v for k,v in os.environ.items() if k not in ('NODE_OPTIONS','NODE_PATH')}
    proc=subprocess.Popen([node,'--max-old-space-size=256','-e',script,*map(str,args)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,creationflags=HIDDEN,env=env)
    import threading
    timer=threading.Timer(12,proc.kill);timer.start()
    try:
        result=proc.stdout.read(limit+1)
        if len(result)>limit:raise ValueError('Source helper output exceeds bound')
        if proc.wait(timeout=2)!=0:raise ValueError('Source helper failed')
        return result
    finally:
        timer.cancel()
        if proc.poll() is None:proc.kill();proc.wait()
        proc.stdout.close()


def decompress(path):
    if path.stat().st_size>32*1024*1024:raise ValueError('Compressed source exceeds bound')
    script=helper('DeepSeekLogReader.swift',r'run\(script: """(.*?)""", arguments:')
    # Keep the original multi-frame algorithm; bound each native decompression.
    script=script.replace('{finishFlush: constants.ZSTD_e_flush}','{finishFlush: constants.ZSTD_e_flush, maxOutputLength: 67108864}')
    script=script.replace('zstdDecompressSync(input.subarray(offset, offset + size))','zstdDecompressSync(input.subarray(offset, offset + size), {maxOutputLength: 67108864})')
    raw=run(script,[path,0]);result=bytearray();offset=0
    while offset+8<=len(raw):
        stored,size=struct.unpack_from('<II',raw,offset);offset+=8
        if offset+size>len(raw):raise ValueError('Incomplete decoder envelope')
        result.extend(raw[offset:offset+size]);offset+=size
    if offset!=len(raw):raise ValueError('Malformed decoder envelope')
    return bytes(result)


def balance(home):
    roots=[Path(os.environ.get('APPDATA',''))/'npm/node_modules',Path.home()/'.bun/install/global/node_modules']
    cache=Path.home()/'.npm/_npx'
    if cache.exists():roots.extend(p/'node_modules' for p in cache.iterdir() if p.is_dir())
    name='@deepseek-ai/dsh-credentials-local/lib/index.js'
    module=next((root/item for root in roots for item in (name,'@deepseek-ai/dsh/node_modules/'+name) if (root/item).is_file()),None)
    script=helper('DeepSeekBalanceClient.swift',r'private static let script = #"""(.*?)"""#')
    reply=json.loads(run(script,[home,module or ''],limit=1024*1024))
    if reply.get('error'):
        from quota_state import QuotaError
        raise QuotaError('auth' if reply['error'] in ('missing-key','http-401','http-403') else 'unavailable')
    if reply.get('is_available') is not True or not isinstance(reply.get('balance_infos'),list):raise ValueError('Invalid DeepSeek balance response')
    wallets=[]
    for value in reply['balance_infos']:
        wallets.append(dict(currency=value.get('currency'),balance=float(value['total_balance']),granted=float(value.get('granted_balance',0)),topped_up=float(value.get('topped_up_balance',0))))
    if any(not math.isfinite(wallet[key]) or wallet[key]<0 for wallet in wallets for key in ('balance','granted','topped_up')):raise ValueError('Invalid wallet amount')
    import time
    return dict(windows=[],wallets=wallets,notice='余额已读取；按量付费不换算成订阅百分比',at=time.time(),not_provided=True)
