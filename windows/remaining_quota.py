"""Windows ports of CopilotClient, GrokClient and AntigravityClient.

Modified for Windows by nanhudev. Exact metadata routes and counters follow
the upstream source; see THIRD_PARTY_NOTICES for CodexBar/Tokscale attribution.
No model turns, login refreshes, arbitrary endpoints or credential logging.
"""
import base64,ctypes,json,math,os,re,ssl,time,urllib.request
from pathlib import Path
from providers import NoRedirect
from quota_state import QuotaError
from session_formats import stamp,digest


def get(url,headers,body=None,local=False):
    handlers=[NoRedirect()]
    if local:
        if not url.startswith(('https://127.0.0.1:','http://127.0.0.1:')):raise ValueError('Non-loopback service')
        handlers.extend([urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=ssl._create_unverified_context())])
    req=urllib.request.Request(url,data=json.dumps(body).encode() if body is not None else None,headers={'Accept':'application/json',**({'Content-Type':'application/json'} if body is not None else {}),**headers})
    with urllib.request.build_opener(*handlers).open(req,timeout=8) as response:
        raw=response.read(2*1024*1024+1)
        if len(raw)>2*1024*1024:raise ValueError('Metadata response exceeds bound')
        return json.loads(raw)


def copilot_parse(root):
    from open_plan_quota import numeric
    rows=[];snapshots=dict(root.get('quota_snapshots') or {});reset=stamp(root.get('quota_reset_date_utc') or root.get('quota_reset_date'))
    premium=snapshots.pop('premium_models',None)
    if premium is not None:snapshots.setdefault('premium_interactions',premium)
    for key,value in snapshots.items():
        if value.get('unlimited') is True:continue
        entitlement=numeric(value.get('entitlement'));remaining=numeric(value.get('remaining',value.get('quota_remaining')))
        if entitlement==remaining==0:continue
        pct=numeric(value.get('percent_remaining'))
        if pct is None and entitlement and remaining is not None:pct=remaining/entitlement*100
        if pct is None:continue
        credits=(root.get('token_based_billing') or value.get('token_based_billing')) and (key=='premium_interactions' or key=='chat' and root.get('access_type_sku')=='free_limited_copilot')
        label='AI credits' if credits else {'premium_interactions':'Premium requests','chat':'Chat messages','completions':'Code completions'}.get(key,key.replace('_',' '))
        own=numeric(value.get('quota_reset_at'));rows.append(dict(label=label,used=max(0,100-min(100,pct)),reset=own if own and own<=253402300799 else reset))
    if not rows:
        for key,remaining in (root.get('limited_user_quotas') or {}).items():
            total=numeric((root.get('monthly_quotas') or {}).get(key));remaining=numeric(remaining)
            if total and remaining is not None:rows.append(dict(label=key,used=max(0,100-remaining/total*100),reset=stamp(root.get('limited_user_reset_date'))))
    return dict(windows=rows,plan=root.get('copilot_plan'),at=time.time())


def windows_credential(target):
    from ctypes import wintypes
    class Credential(ctypes.Structure):
        _fields_=[('Flags',wintypes.DWORD),('Type',wintypes.DWORD),('TargetName',wintypes.LPWSTR),('Comment',wintypes.LPWSTR),('LastWritten',wintypes.FILETIME),('CredentialBlobSize',wintypes.DWORD),('CredentialBlob',ctypes.POINTER(ctypes.c_ubyte)),('Persist',wintypes.DWORD),('AttributeCount',wintypes.DWORD),('Attributes',ctypes.c_void_p),('TargetAlias',wintypes.LPWSTR),('UserName',wintypes.LPWSTR)]
    if os.name!='nt':return None
    api=ctypes.WinDLL('Advapi32',use_last_error=True);out=ctypes.POINTER(Credential)()
    api.CredReadW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.POINTER(ctypes.POINTER(Credential))];api.CredReadW.restype=wintypes.BOOL;api.CredFree.argtypes=[ctypes.c_void_p]
    if not api.CredReadW(target,1,0,ctypes.byref(out)):return None
    try:return ctypes.string_at(out.contents.CredentialBlob,out.contents.CredentialBlobSize).decode('utf-8')
    finally:api.CredFree(out)


def copilot_quota(enabled=False,http=get):
    if not enabled:return dict(windows=[],not_provided=True,notice='在智能体设置中允许读取 GitHub CLI 账户额度后启用',at=time.time())
    token=os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN') or windows_credential('gh:github.com')
    if token and token.startswith('go-keyring-base64:'):token=base64.b64decode(token.split(':',1)[1]).decode()
    if not token:
        folder=Path(os.environ.get('GH_CONFIG_DIR') or Path(os.environ.get('APPDATA',Path.home()/'.config'))/'GitHub CLI')
        path=folder/'hosts.yml'
        if path.exists() and path.stat().st_size<=1024*1024:
            in_host=False
            for line in path.read_text(encoding='utf-8').splitlines():
                if line=='github.com:':in_host=True;continue
                if line and not line[0].isspace() and not line.startswith('#'):in_host=False
                if in_host and line.strip().startswith('oauth_token:'):token=line.split(':',1)[1].strip().strip('"\'');break
    if not token:raise QuotaError('auth')
    headers={'Authorization':'token '+token,'Editor-Version':'vscode/1.96.2','Editor-Plugin-Version':'copilot-chat/0.26.7','User-Agent':'GitHubCopilotChat/0.26.7','X-Github-Api-Version':'2025-04-01'}
    result=copilot_parse(http('https://api.github.com/copilot_internal/user',headers))
    try:
        profile=http('https://api.github.com/user',headers)
        if isinstance(profile.get('id'),int):result['account']=dict(id=digest('GitHub Copilot','github.com:'+str(profile['id'])),label=profile.get('login') or 'GitHub',evidence='account')
    except Exception:pass
    return result


def grok_parse(root):
    from open_plan_quota import numeric
    config=root.get('config')
    if not isinstance(config,dict):raise ValueError('Invalid Grok billing response')
    period=config.get('currentPeriod') or {};reset=stamp(period.get('end') or config.get('billingPeriodEnd'));rows=[];used=numeric(config.get('creditUsagePercent'))
    if used is not None:rows.append(dict(label='Weekly' if period.get('type')=='USAGE_PERIOD_TYPE_WEEKLY' else 'Monthly' if period.get('type')=='USAGE_PERIOD_TYPE_MONTHLY' else 'Usage',used=used,reset=reset))
    def dollars(value):
        if not isinstance(value,dict):return None
        if not value:return 0.
        try:
            amount=float(value['val'])
            return abs(amount)/100 if math.isfinite(amount) and amount==int(amount) else None
        except (KeyError,ValueError,TypeError):return None
    balance=dollars(config.get('prepaidBalance'));cap=dollars(config.get('onDemandCap'));extra=dollars(config.get('onDemandUsed'));wallets=[]
    if balance is not None:wallets.append(dict(currency='USD',balance=balance))
    if cap and extra is not None:rows.append(dict(label='Extra usage',used=extra/cap*100,reset=reset))
    return dict(windows=rows,wallets=wallets,at=time.time())


def grok_quota(http=get):
    home=Path(os.environ.get('GROK_HOME') or Path.home()/'.grok');path=home/'auth.json'
    if not path.exists() or path.stat().st_size>1024*1024:raise QuotaError('auth')
    root=json.loads(path.read_text(encoding='utf-8'));entries=[(key,value) for key,value in root.items() if key.startswith('https://auth.x.ai::') or key=='https://accounts.x.ai/sign-in']
    entries.sort(key=lambda item:(not item[0].startswith('https://auth.x.ai::'),item[0]))
    entry=next((value for _,value in entries if value.get('key') and (stamp(value.get('expires_at')) or 0)>time.time()),None)
    if not entry:raise QuotaError('auth')
    if str(entry.get('principal_type','')).lower()=='team':return dict(windows=[],at=time.time(),notice='原版接口未提供 Grok 团队额度',not_provided=True)
    result=grok_parse(http('https://cli-chat-proxy.grok.com/v1/billing?format=credits',{'Authorization':'Bearer '+entry['key'],'x-xai-token-auth':'xai-grok-cli'}))
    user=entry.get('user_id') or entry.get('principal_id')
    if user:result['account']=dict(id=digest('Grok',user,entry.get('team_id') or entry.get('organization_id') or ''),label=entry.get('email') or 'Grok CLI',evidence='credential')
    return result


def antigravity_parse(root,status=None):
    groups=(root.get('response') or root.get('summary') or root).get('groups');rows=[];seen=set()
    if not isinstance(groups,list):raise ValueError('Invalid Antigravity summary')
    for group in groups:
        if not isinstance(group.get('buckets'),list):raise ValueError('Missing quota buckets')
        for value in group['buckets']:
            if value.get('disabled'):continue
            identity=value.get('bucketId')
            if not identity or identity in seen:raise ValueError('Duplicate quota bucket')
            seen.add(identity);remaining=value.get('remaining') or {};fraction=value.get('remainingFraction',remaining.get('remainingFraction',remaining.get('value') if remaining.get('case')=='remainingFraction' else None))
            if isinstance(fraction,(int,float)) and not isinstance(fraction,bool) and 0<=fraction<=1:rows.append(dict(label=' · '.join(v for v in (group.get('displayName'),value.get('displayName') or identity) if v),used=(1-fraction)*100,reset=stamp(value.get('resetTime'))))
    result=dict(windows=rows,at=time.time());status=(status or {}).get('userStatus') or {};email=status.get('email');team=status.get('teamId')
    if email or team:result['account']=dict(id=digest('Antigravity',str(email or '').lower(),team or ''),label=email or 'Antigravity 工作区',evidence='account')
    result['plan']=(status.get('userTier') or {}).get('name') or ((status.get('planStatus') or {}).get('planInfo') or {}).get('planName')
    return result


def antigravity_legacy(root):
    status=root.get('userStatus') or {};configs=(status.get('cascadeModelConfigData') or {}).get('clientModelConfigs')
    if not isinstance(configs,list):raise ValueError('Invalid Antigravity status')
    pools={}
    for config in configs:
        quota=config.get('quotaInfo') or {};fraction=quota.get('remainingFraction')
        if isinstance(fraction,bool) or not isinstance(fraction,(int,float)) or not 0<=fraction<=1:continue
        model=(config.get('modelOrAlias') or {}).get('model') or '';label=config.get('label') or model;lower=(model+' '+label).lower()
        if any(word in lower for word in ('lite','autocomplete','image')):continue
        family='gemini' if 'gemini' in lower else 'claude-gpt' if 'claude' in lower or 'gpt' in lower else model
        if not family:continue
        row=dict(label='Gemini Models' if family=='gemini' else 'Claude and GPT models' if family=='claude-gpt' else label,used=(1-fraction)*100,reset=stamp(quota.get('resetTime')))
        if family not in pools or row['used']>pools[family]['used']:pools[family]=row
    result=antigravity_parse(dict(groups=[]),root);result['windows']=[pools[key] for key in sorted(pools)]
    return result


def antigravity_cli_parse(root):
    command=root.get('command') or {};groups=(command.get('data') or {}).get('groups')
    if root.get('status')!='SUCCESS' or command.get('name')!='usage' or not isinstance(groups,list):raise ValueError('Invalid agy usage')
    return antigravity_parse(dict(groups=[dict(displayName=group.get('name'),buckets=[dict(bucketId=bucket.get('id'),displayName=bucket.get('name'),remainingFraction=bucket.get('remaining_fraction'),resetTime=bucket.get('reset_time')) for bucket in group.get('buckets') or []]) for group in groups]))


def antigravity_cli(executable):
    import subprocess,threading
    from providers import HIDDEN,PROBE_PIDS
    proc=subprocess.Popen([executable,'-p','/usage','--output-format','json'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,creationflags=HIDDEN)
    PROBE_PIDS.add(proc.pid);timer=threading.Timer(30,proc.kill);timer.start()
    try:
        raw=proc.stdout.read(1024*1024+1)
        if len(raw)>1024*1024 or proc.wait(timeout=2)!=0:raise ValueError('agy usage unavailable')
        return antigravity_cli_parse(json.loads(raw))
    finally:
        timer.cancel()
        if proc.poll() is None:proc.kill();proc.wait()
        proc.stdout.close();PROBE_PIDS.discard(proc.pid)


def antigravity_quota(http=get):
    import psutil
    deadline=time.monotonic()+20;agy=None
    for process in psutil.process_iter(['name','exe','cmdline']):
        try:
            args=process.info.get('cmdline') or [];command=' '.join(args);lower=command.lower().replace('\\','/')
            executable=process.info.get('exe') or ''
            if Path(executable).name.lower() in ('agy.exe','agy') and Path(executable).is_absolute():agy=agy or executable
            if not ('antigravity' in lower or re.search(r'(?:^|/)agy(?:\.exe)?(?:\s|$)',lower)):continue
            if not any(marker in lower for marker in ('language_server','language-server','--extension_server_port')):continue
            def flag(key):
                for index,arg in enumerate(args):
                    if arg.startswith('--'+key+'='):return arg.split('=',1)[1]
                    if arg=='--'+key and index+1<len(args):return args[index+1]
            token=flag('csrf_token');ext=flag('extension_server_port');ext_token=flag('extension_server_csrf_token') or token
            listeners={c.laddr.port for c in process.net_connections('tcp') if c.status=='LISTEN' and c.laddr.ip in ('127.0.0.1','::1','0.0.0.0','::')}
            endpoints=[('https',port,token) for port in listeners if token]
            if ext and int(ext) in listeners and ext_token:endpoints.insert(0,('http',int(ext),ext_token))
            for scheme,port,secret in endpoints[:6]:
                if time.monotonic()>deadline:raise TimeoutError('Service metadata deadline')
                base=f'{scheme}://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/'
                try:
                    headers={'x-codeium-csrf-token':secret}
                    try:summary=http(base+'RetrieveUserQuotaSummary',headers,dict(forceRefresh=True),local=True)
                    except Exception:summary=None
                    try:status=http(base+'GetUserStatus',headers,dict(metadata=dict(ideName='antigravity',extensionName='antigravity',locale='en',ideVersion='unknown')),local=True)
                    except Exception:status=None
                    if summary is not None:return antigravity_parse(summary,status)
                    if status is not None:
                        result=antigravity_legacy(status)
                        if result['windows']:return result
                except Exception:continue
        except (psutil.NoSuchProcess,psutil.AccessDenied,ValueError):continue
    if agy:return antigravity_cli(agy)
    raise QuotaError('unavailable')
