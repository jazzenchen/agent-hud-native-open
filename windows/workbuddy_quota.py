"""WorkBuddy desktop account/credit metadata adapter.

The installed 5.5.6 client's AuthService reads this official summary endpoint.
Its per-package Cycle*Capacity counters are summed without a second round of
subscription filtering: the service has already removed superseded plan bases.
No login refresh, check-in, purchase or model request is performed. Credentials
stay in memory and are sent only to the fixed official HTTPS gateway.
"""
import json,math,time
from pathlib import Path
from remaining_quota import get
from quota_state import QuotaError
from session_formats import digest

ENDPOINT='https://copilot.tencent.com/billing/meter/get-user-resource-summary'
ENTERPRISE_ENDPOINT='https://copilot.tencent.com/v2/billing/meter/get-enterprise-user-usage'


def session(home):
    path=Path(home)/'AppData/Local/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info'
    if path.with_suffix(path.suffix+'.logged-out').exists():raise QuotaError('auth')
    try:
        if path.stat().st_size>2*1024*1024:raise ValueError()
        value=json.loads(path.read_text(encoding='utf-8-sig'))
        account=value.get('account');auth=value.get('auth')
        if not isinstance(account,dict) or not isinstance(auth,dict):raise ValueError()
        token=auth.get('accessToken');uid=account.get('uid');domain=auth.get('domain')
        if not isinstance(token,str) or not token or not isinstance(uid,str) or not uid:raise ValueError()
        if domain not in ('www.workbuddy.cn','www.codebuddy.cn'):raise ValueError()
        expires=auth.get('expiresAt')
        if isinstance(expires,(int,float)) and expires<=time.time()*1000:raise ValueError()
        return account,auth
    except (OSError,ValueError,TypeError,AttributeError):raise QuotaError('auth') from None


def count(value):
    if isinstance(value,bool):raise ValueError('Invalid credit count')
    try:number=float(value)
    except (ValueError,TypeError):raise ValueError('Invalid credit count') from None
    if not math.isfinite(number) or number<0:raise ValueError('Invalid credit count')
    return number


def parse(response,account,now=None):
    if not isinstance(response,dict) or response.get('code')!=0:raise QuotaError('unavailable')
    data=response.get('data')
    if not isinstance(data,dict) or not isinstance(data.get('Packages'),list):raise ValueError('Missing credit summary')
    total=left=used=0.;packages=[]
    for entry in data['Packages']:
        if not isinstance(entry,dict):raise ValueError('Invalid credit package')
        capacity=count(entry.get('CycleTotalCapacity'));remaining=count(entry.get('CycleRemainCapacity'));spent=count(entry.get('CycleUsedCapacity'))
        total+=capacity;left+=remaining;used+=spent
        packages.append(dict(code=str(entry.get('PackageCode') or ''),total=capacity,remaining=remaining,used=spent))
    if not all(math.isfinite(n) for n in (total,left,used)):raise ValueError('Invalid credit total')
    nickname=account.get('nickname')
    identity=dict(id=digest('WorkBuddy',account['uid'],account.get('enterpriseId') or ''),
                  label=nickname[:160] if isinstance(nickname,str) and nickname.strip() else 'WorkBuddy 账户',evidence='account')
    name=data.get('SubscriptionPackageName');code=data.get('SubscriptionPackageCode')
    plan=name.strip()[:160] if isinstance(name,str) and name.strip() else code.strip()[:160] if isinstance(code,str) and code.strip() else None
    at=time.time() if now is None else now
    balance=dict(remaining=left,total=total,used=used,packages=packages,at=at)
    windows=[dict(id='workbuddy:credits',label='积分',used=max(0,min(100,(1-left/total)*100)),remaining=left,capacity=total,account_id=identity['id'])] if total>0 else []
    return dict(windows=windows,account=identity,accounts=[identity],plan=plan,credit_balance=balance,
                notice='WorkBuddy 套餐与剩余积分已读取',at=at)


def enterprise(response,account):
    if not isinstance(response,dict) or response.get('code')!=0:raise QuotaError('unavailable')
    data=response.get('data') or {}
    if not isinstance(data,dict):raise ValueError('Missing enterprise credits')
    data=data.get('data',data)
    if not isinstance(data,dict) or 'limitNum' not in data or 'credit' not in data:raise ValueError('Missing enterprise credits')
    limit=data['limitNum'];spent=count(data['credit']);unlimited=limit==-1 and not isinstance(limit,bool)
    total=0 if unlimited else count(limit);remaining=0 if unlimited else max(0,total-spent)
    result=parse(dict(code=0,data=dict(SubscriptionPackageName=account.get('type') or '企业账户',Packages=[dict(PackageCode='enterprise',CycleTotalCapacity=total,CycleRemainCapacity=remaining,CycleUsedCapacity=spent)])),account)
    result['credit_balance']['unlimited']=unlimited
    if unlimited:result.update(windows=[],not_provided=True,notice='企业账户积分不限额')
    return result


def credit_text(balance,key):
    return '不限额' if balance.get('unlimited') and key in ('remaining','total') else f'{balance[key]:,.2f}'


def fetch(home=None,request=get):
    home=Path.home() if home is None else Path(home)
    account,auth=session(home)
    # Header contract follows the desktop AuthService and HTTP interceptors.
    headers={'Authorization':'Bearer '+auth['accessToken'],'X-User-Id':account['uid'],'X-Domain':auth['domain'],
             'Accept-Language':'zh','User-Agent':'WorkBuddy/5.5.6 AgentHUDOpenWindows',
             'X-Product':'SaaS','X-IDE-Type':'WorkBuddy','X-IDE-Name':'WorkBuddy','X-IDE-Version':'5.5.6'}
    if account.get('enterpriseId'):
        headers.update({'X-Enterprise-Id':account['enterpriseId'],'X-Tenant-Id':account['enterpriseId']})
    response=request(ENTERPRISE_ENDPOINT if account.get('enterpriseId') else ENDPOINT,headers,{})
    after,_=session(home)
    if (account['uid'],account.get('enterpriseId'))!=(after['uid'],after.get('enterpriseId')):raise QuotaError('auth')
    return enterprise(response,account) if account.get('enterpriseId') else parse(response,account)
