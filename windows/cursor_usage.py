"""Port of CursorClient.fetchEvents/reconcile/parseEvents (see third-party notices)."""
import time
from datetime import datetime
from providers import cursor_auth,cursor_request,cursor_quota,cursor_sessions,DATA
from session_formats import count,digest,stamp,Transcript
from usage_ledger import UsageLedger


def reconcile(pages,expected):
    total=sum(map(len,pages))
    if expected is None:return [row for page in pages for row in page]
    if total<expected:raise ValueError('Incomplete Cursor usage pages')
    remove=total-expected;result=list(pages[0]) if pages else []
    for previous,current in zip(pages,pages[1:]):
        overlap=0
        for n in range(min(len(previous),len(current),remove),0,-1):
            if previous[-n:]==current[:n]:overlap=n;break
        result.extend(current[overlap:]);remove-=overlap
    if remove or len(result)!=expected:raise ValueError('Inconsistent Cursor usage pages')
    return result


def fetch_events(token,user,request=cursor_request):
    now=time.time();start=datetime.fromtimestamp(now).replace(hour=0,minute=0,second=0,microsecond=0).timestamp()-7*86400
    pages=[];expected=None;deadline=time.monotonic()+25
    for page in range(1,201):
        if time.monotonic()>deadline:raise TimeoutError('Usage pagination deadline')
        data=request(token,user,'dashboard/get-filtered-usage-events',dict(page=page,pageSize=1000,startDate=str(int(start*1000)),endDate=str(int(now*1000))))
        reported=data.get('totalUsageEventsCount')
        if reported is not None:
            if isinstance(reported,bool) or not isinstance(reported,(int,str)):raise ValueError('Invalid usage count')
            reported=int(reported)
            if reported<0 or expected is not None and reported!=expected:raise ValueError('Usage count changed during pagination')
            expected=reported
        rows=data.get('usageEventsDisplay')
        if not data:
            if expected not in (None,0):raise ValueError('Missing usage page')
            expected=0;rows=[]
        elif set(data)=={'totalUsageEventsCount'}:rows=[]
        if not isinstance(rows,list):raise ValueError('Unsupported usage page')
        pages.append(rows)
        if len(rows)<1000:return reconcile(pages,expected)
    raise ValueError('Usage page limit')


def parse_events(rows,account):
    sessions={};occurrences={}
    for row in rows:
        usage=row.get('tokenUsage')
        if not isinstance(usage,dict):continue
        at=stamp(row.get('timestamp'));model=row.get('model')
        if at is None or not model or usage.get('inputTokens') is None or usage.get('outputTokens') is None:raise ValueError('Missing request counters')
        inp=count(usage.get('inputTokens'));out=count(usage.get('outputTokens'));cache=count(usage.get('cacheReadTokens'));write=count(usage.get('cacheWriteTokens'))
        conversation=row.get('conversationId')
        key=digest(account,conversation or '',int(at*1000),model,inp,out,cache,write)
        ordinal=occurrences.get(key,0);occurrences[key]=ordinal+1;key+=f':{ordinal}'
        sid=conversation or 'unassigned-'+key
        parser=sessions.setdefault(sid,Transcript('Cursor',sid))
        parser.add(key,at,dict(input=inp+write,output=out,cache=cache,cache_write=write,reasoning=0),model)
        parser.events[key]['account']=account
    return list(sessions.values())


class CursorSource:
    def __init__(self,ledger=None):
        self.ledger=ledger or UsageLedger(DATA/'usage-ledger.sqlite');self.cached=None;self.identity=None;self.notice=None
    def quota(self):
        result=cursor_quota();identity=result['account']['id']
        if identity!=self.identity:self.cached=None;self.identity=identity
        self.ledger.record('Cursor',[],[result['account']])
        try:
            token,user,_=cursor_auth()
            if digest('Cursor',user)!=identity:raise ValueError('Account switched during read')
            parsed=parse_events(fetch_events(token,user),identity)
            self.ledger.record('Cursor',[event for parser in parsed for event in parser.events.values()])
            self.cached=dict(sessions=[p.summary() for p in parsed],stats=self.ledger.report('Cursor',account=identity));self.notice=None
        except Exception:
            self.notice='账户 Token 用量读取失败，稍后重试；额度读数仍有效'
        return result
    def sessions(self):
        local=cursor_sessions()
        if self.cached:
            local['stats']=self.cached['stats'];known={r['id'] for r in local['sessions']}
            local['sessions']+= [r for r in self.cached['sessions'] if r['id'] not in known]
        if self.notice:local['notice']=self.notice
        return local
