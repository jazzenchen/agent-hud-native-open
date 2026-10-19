"""Read-only port of OpenAgentCredentials/OpenAgentQuota's official plan routes.

Credential scopes are kept separate unless Kimi's own /me confirms identity.
Custom model endpoints never send their keys to an assumed official service.
"""
import base64,hashlib,json,math,os,time,urllib.parse,urllib.request
from dataclasses import dataclass,field
from pathlib import Path
from providers import NoRedirect
from quota_state import QuotaError
from session_formats import digest,stamp

ENDPOINTS={'kimi':'https://api.kimi.com/coding/v1/usages','kimiGlobal':'https://api.kimi.ai/coding/v1/usages','go':'https://opencode.ai/zen/go/v1/usage',
    'glmChina':'https://open.bigmodel.cn/api/monitor/usage/quota/limit','glmGlobal':'https://api.z.ai/api/monitor/usage/quota/limit'}


def service(provider='',base=None,client=None):
    if base is not None:
        try:
            url=urllib.parse.urlsplit(base)
            if url.scheme!='https' or url.username or url.password or url.query or url.fragment or url.port not in (None,443):return None
        except ValueError:return None
        routes={('api.kimi.com','coding'):'kimi',('api.kimi.com','coding/v1'):'kimi',('api.kimi.ai','coding'):'kimiGlobal',('api.kimi.ai','coding/v1'):'kimiGlobal',('opencode.ai','zen/go/v1'):'go'}
        for host,kind in [('open.bigmodel.cn','glmChina'),('api.z.ai','glmGlobal')]:
            for path in ('api/coding/paas/v4','api/anthropic'):routes[host,path]=kind
        return routes.get((url.hostname,url.path.strip('/')))
    return {'kimi-for-coding':'kimi','kimi-coding':'kimi','kimi-code':'kimi','zai-coding-plan':'glmGlobal','zhipuai-coding-plan':'glmChina','opencode-go':'go',**({'zai':'glmGlobal','zai-coding-cn':'glmChina'} if client=='Pi' else {})}.get(provider)


def read(path):
    try:
        if path.stat().st_size>1024*1024:return {}
        return json.loads(path.read_text(encoding='utf-8-sig'))
    except (OSError,ValueError):return {}


@dataclass
class Credential:
    service:str
    token:str=field(repr=False)
    clients:set=field(default_factory=set)
    @property
    def id(self):return digest(self.service,self.token)
    @property
    def group(self):return 'Kimi' if self.service.startswith('kimi') else 'OpenCode' if self.service=='go' else 'WorkBuddy' if self.clients=={'WorkBuddy'} else 'GLM'


def discover(home=None,env=None):
    home=Path.home() if home is None else Path(home);env=os.environ if env is None else env;found={}
    def add(kind,key,client):
        if not kind or not isinstance(key,str) or not key or key.startswith('!') or any(c in key for c in '\r\n\0'):return
        parts=key.split('.')
        if kind.startswith('kimi') and len(parts)==3:
            try:
                claims=json.loads(base64.urlsafe_b64decode(parts[1]+'='*(-len(parts[1])%4)))
                if isinstance(claims.get('exp'),(int,float)) and claims['exp']<=time.time()+60:return
            except (ValueError,UnicodeError):pass
        credential=Credential(kind,key,{client});found.setdefault(credential.id,credential).clients.add(client)
    add(service(base=env['KIMI_CODE_BASE_URL']) if env.get('KIMI_CODE_BASE_URL') else 'kimi',env.get('KIMI_CODE_API_KEY'),'Kimi')
    for name,kind,client in [('OPENCODE_GO_API_KEY','go','OpenCode'),('ZAI_API_KEY','glmGlobal','Pi'),('ZAI_CODING_CN_API_KEY','glmChina','Pi'),('KIMI_API_KEY','kimi','Pi')]:add(kind,env.get(name),client)
    for name in ('BIGMODEL_API_KEY','ZHIPU_API_KEY','ZHIPUAI_API_KEY','GLM_API_KEY'):add('glmChina',env.get(name),'GLM')
    if env.get('Z_AI_USAGE_SCOPE','personal')=='personal' and env.get('Z_AI_REGION','global') in ('global','bigmodel-cn'):add('glmChina' if env.get('Z_AI_REGION')=='bigmodel-cn' else 'glmGlobal',env.get('Z_AI_API_KEY'),'GLM')
    for config in [env,read(home/'.claude/settings.json').get('env',{})]:
        if config.get('ANTHROPIC_BASE_URL'):add(service(base=config['ANTHROPIC_BASE_URL']),config.get('ANTHROPIC_AUTH_TOKEN') or config.get('ANTHROPIC_API_KEY'),'Claude')
    data=Path(env.get('XDG_DATA_HOME') or home/'.local/share')/'opencode';config=Path(env.get('XDG_CONFIG_HOME') or home/'.config')/'opencode'
    configs=[];valid=True
    for name in ('opencode.json','opencode.jsonc'):
        path=config/name
        if path.exists():
            try:
                if path.stat().st_size>1024*1024:raise ValueError()
                value=json.loads(path.read_text(encoding='utf-8-sig'))
                if not isinstance(value,dict):raise ValueError()
                configs.append(value)
            except (ValueError,OSError):valid=False
    if valid:
        for provider,auth in read(data/'auth.json').items():
            if not isinstance(auth,dict) or auth.get('type')!='api':continue
            base=next((c.get('provider',{}).get(provider,{}).get('options',{}).get('baseURL') for c in reversed(configs) if c.get('provider',{}).get(provider,{}).get('options',{}).get('baseURL') is not None),None)
            add(service(provider,base,'OpenCode'),auth.get('key'),'OpenCode')
    pi=Path(env.get('PI_CODING_AGENT_DIR') or home/'.pi/agent');models=read(pi/'models.json').get('providers',{})
    for provider,auth in read(pi/'auth.json').items():
        if not isinstance(auth,dict):continue
        kind=service(provider,models.get(provider,{}).get('baseUrl'),'Pi')
        if auth.get('type')=='api_key':
            key=auth.get('key');add(kind,env.get(key,key) if isinstance(key,str) else None,'Pi')
        elif auth.get('type')=='oauth' and provider=='kimi-coding' and kind=='kimi' and not env.get('KIMI_CODE_OAUTH_HOST') and not env.get('KIMI_OAUTH_HOST') and isinstance(auth.get('expires'),(int,float)) and auth['expires']>(time.time()+60)*1000:add(kind,auth.get('access'),'Pi')
    kimi=Path(env.get('KIMI_CODE_HOME') or home/'.kimi-code');allowed=service(base=env['KIMI_CODE_BASE_URL']) if env.get('KIMI_CODE_BASE_URL') else None;oauth=env.get('KIMI_CODE_OAUTH_HOST') or env.get('KIMI_OAUTH_HOST')
    if (not env.get('KIMI_CODE_BASE_URL') or allowed in ('kimi','kimiGlobal')) and oauth in (None,'https://auth.kimi.com','https://auth.kimi.ai'):
        global_slot='kimi-code-env-'+hashlib.sha256(b'{"oauthHost":"https://auth.kimi.ai","baseUrl":"https://api.kimi.ai/coding/v1"}').hexdigest()[:16]
        for kind,slot in [('kimi','kimi-code'),('kimiGlobal',global_slot)]:
            if allowed and allowed!=kind or oauth and (oauth=='https://auth.kimi.ai')!=(kind=='kimiGlobal'):continue
            auth=read(kimi/'credentials'/f'{slot}.json')
            if isinstance(auth.get('expires_at'),(int,float)) and auth['expires_at']>time.time()+60:add(kind,auth.get('access_token'),'Kimi')
    work=read(home/'.workbuddy/models.json')
    for entry in work if isinstance(work,list) else []:
        if not isinstance(entry,dict) or entry.get('vendor')!='GLM Coding Plan':continue
        kind=service(base=entry.get('url')) if entry.get('url') else None
        if kind in ('glmChina','glmGlobal'):add(kind,entry.get('apiKey'),'WorkBuddy')
    return list(found.values())


def numeric(value):
    if isinstance(value,bool):return None
    try:
        number=float(value)
        return number if math.isfinite(number) and number>=0 else None
    except (ValueError,TypeError):return None


def parse(root,kind):
    rows=[];plan=None
    def add(label,used,reset):
        if numeric(used) is None:raise ValueError('Invalid quota percentage')
        rows.append(dict(label=label,used=float(used),reset=stamp(reset)))
    if kind.startswith('kimi'):
        plan=(root.get('membership') or {}).get('level')
        for key,label in [('limit_5h','5-hour'),('limit_7d','Weekly'),('limit_month_total','Monthly')]:
            value=(root.get('usages') or {}).get(key) or {};ratio=numeric(value.get('used_ratio'))
            if ratio is not None:add(label,ratio*100,value.get('reset_time'))
        if not rows:
            legacy=[]
            if isinstance(root.get('usage'),dict):legacy.append(('Weekly',root['usage']))
            for entry in root.get('limits') or []:
                window=entry.get('window') or {};number=numeric(window.get('duration'));unit={'TIME_UNIT_MINUTE':60,'TIME_UNIT_HOUR':3600,'TIME_UNIT_DAY':86400,'TIME_UNIT_WEEK':604800}.get(window.get('timeUnit'))
                if not number or not unit:raise ValueError('Invalid quota window')
                seconds=number*unit;label='5-hour' if seconds==18000 else 'Weekly' if seconds==604800 else f'{seconds/3600:g}h'
                legacy.append((label,entry.get('detail') or {}))
            for label,value in legacy:
                limit=numeric(value.get('limit'));used=numeric(value.get('used'));remaining=numeric(value.get('remaining'))
                if not limit or used is None and remaining is None:raise ValueError('Missing quota counts')
                add(label,(used if used is not None else max(0,limit-remaining))/limit*100,value.get('resetTime'))
    elif kind=='go':
        if not isinstance(root.get('usage'),dict):raise ValueError('Missing quota usage')
        for key,label in [('rolling','5-hour'),('weekly','Weekly'),('monthly','Monthly')]:
            if key in root['usage']:
                value=root['usage'][key];add(label,value.get('percent'),value.get('resetsAt'))
    else:
        if root.get('success') is not True or root.get('code')!=200 or not isinstance(root.get('data',{}).get('limits'),list):raise ValueError('Invalid GLM usage response')
        plan=root['data'].get('planName') or root['data'].get('level')
        for value in root['data']['limits']:
            kind=value.get('type')
            if kind not in ('TOKENS_LIMIT','CREDIT_LIMIT','TIME_LIMIT'):continue
            unit=numeric(value.get('unit'));number=numeric(value.get('number'));percent=numeric(value.get('percentage'))
            if unit is None or number is None or unit!=int(unit) or number!=int(number) or percent is None:raise ValueError('Invalid GLM quota window')
            limit=numeric(value.get('usage'));current=numeric(value.get('currentValue'));remaining=numeric(value.get('remaining'))
            if limit and (current is not None or remaining is not None):percent=max(max(0,limit-remaining) if remaining is not None else 0,current or 0)/limit*100
            seconds={1:86400,3:3600,5:60,6:604800}.get(unit,0)*number
            label='MCP' if kind=='TIME_LIMIT' else ('Credits ' if kind=='CREDIT_LIMIT' else 'Tokens ')+('5h' if seconds==18000 else 'Weekly' if seconds==604800 else f'{seconds/3600:g}h')
            reset=stamp(value.get('nextResetTime'))
            if kind!='TIME_LIMIT' and seconds==18000 and reset and reset>time.time()+18060:reset=None
            add(label,percent,reset)
    if not rows or len({r['label'] for r in rows})!=len(rows):raise ValueError('Missing or duplicate quota windows')
    return dict(windows=rows,plan=plan,at=time.time())


def request(url,token):
    if url not in ENDPOINTS.values() and url not in ('https://api.kimi.com/coding/v1/me','https://api.kimi.ai/coding/v1/me'):raise ValueError('Unsupported quota route')
    req=urllib.request.Request(url,headers={'Authorization':'Bearer '+token,'Accept':'application/json'})
    with urllib.request.build_opener(NoRedirect()).open(req,timeout=10) as response:
        raw=response.read(2*1024*1024+1)
        if len(raw)>2*1024*1024:raise ValueError('Oversized quota response')
        return json.loads(raw)


def fetch(group,credentials=None,http=request):
    candidates=[c for c in (discover() if credentials is None else credentials) if c.group==group]
    if not candidates:raise QuotaError('auth')
    windows=[];accounts={};plans=set();failed=0;deadline=time.monotonic()+30;last_error=None
    for credential in candidates[:8]:
        if time.monotonic()>deadline:failed+=1;break
        try:
            endpoint=ENDPOINTS[credential.service];result=parse(http(endpoint,credential.token),credential.service)
            account=dict(id=credential.id,label=group+' · 凭据 '+credential.id[:6],evidence='credential')
            if credential.service.startswith('kimi'):
                try:
                    profile=http(endpoint.rsplit('/',1)[0]+'/me',credential.token);domain=profile.get('domain',0)
                    if isinstance(profile.get('user_id'),str) and profile['user_id'].strip() and isinstance(profile.get('region'),str) and profile['region'].strip() and numeric(domain) is not None and numeric(domain)==int(numeric(domain)):
                        account=dict(id=digest(credential.service,profile['user_id'],int(domain),profile['region']),label=group+' · '+str(profile['user_id']),evidence='account')
                except Exception:pass
            # Two keys confirmed as one account share one set of windows.
            if account['id'] in accounts:continue
            accounts[account['id']]=account
            if result.get('plan'):plans.add(str(result['plan']))
            for window in result['windows']:windows.append({**window,'label':window['label']+((' · '+account['id'][:6]) if len(candidates)>1 else ''),'account':account['id']})
        except Exception as error:failed+=1;last_error=error
    if not windows:raise last_error or QuotaError('unavailable')
    return dict(windows=windows,account=next(iter(accounts.values())) if len(accounts)==1 else None,accounts=list(accounts.values()),plan=' / '.join(sorted(plans)),at=time.time(),
        notice='部分账户读取失败，稍后重试' if failed else '官方账户额度已读取',partial=bool(failed))
