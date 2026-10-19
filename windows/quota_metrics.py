"""Source QuotaMath / QuotaRowMetrics numeric counterparts, no GUI or network."""
import time,sqlite3
from decimal import Decimal
from pathlib import Path
from quota_insights import number
from session_formats import stamp
from usage_display import window_account
from catalog_pricing import summed_cost

MEASURES=(('quota','额度'),('burn','消耗速率'),('tokens','回复速率'),('consumed','已消耗'),('cost','费用估算'))


def reply_rate(events,models=None):
    groups={}
    for event in events:groups.setdefault((event['session'],event.get('account')),[]).append(event)
    output=span=calls=0
    for group in groups.values():
        ordered=sorted(group,key=lambda event:(event['at'],event['id']))
        for before,after in zip(ordered,ordered[1:]):
            gap=after['at']-before['at']
            if gap<=0 or gap>120 or models is not None and after['model'] not in models:continue
            output+=after['output'];span+=gap;calls+=1
    return dict(tokens_per_second=output/span,calls=calls,tokens_out=output) if span>0 else None


def recent_reply_rate(events,models,now):
    week=[event for event in events if now-7*86400<=event['at']<now]
    recent=[event for event in week if event['at']>=now-3600]
    return reply_rate(recent,models) or reply_rate(week,models)


def summarize(events,start,now,models=None,region='international',contract=None):
    if not events:return dict(consumed=None,reply=None,cost=None,tokens_per_hour=None)
    oldest=min(int(event['at']//900)*900 for event in events);begin=max(start,oldest)
    selected=[event for event in events if begin<=int(event['at']//900)*900<now and (models is None or event['model'] in models)]
    hours=(now-begin)/3600
    if hours<=0:return dict(consumed=None,reply=None,cost=None,tokens_per_hour=None)
    costs={}
    for event in selected:
        cost=summed_cost(event['model'],event,region,int(event['at']//900)*900,contract)
        if cost:costs[cost['currency']]=costs.get(cost['currency'],Decimal(0))+cost['amount']
    used=sum(event['input']+event['output']+event['cache'] for event in selected)
    # Source tokensPerHour excludes cache reads; tokensTotal includes them.
    return dict(consumed=dict(used=used,capacity=None),reply=recent_reply_rate(events,models,now),
                cost=dict(amounts={key:str(value) for key,value in costs.items()},hours=hours) if costs else None,
                tokens_per_hour=round(sum(event['input']+event['output'] for event in selected)/hours),
                scope='local' if any(event.get('account') is None for event in selected) else 'account')


def model_scope(vendor,row,models):
    if isinstance(row.get('consumer_models'),list):return set(row['consumer_models'])
    label=row.get('label','')
    if vendor=='Codex':return set(models)
    if vendor=='Claude' and label in ('5-hour','Weekly','Sonnet Weekly','Opus Weekly'):
        family='sonnet' if label=='Sonnet Weekly' else 'opus' if label=='Opus Weekly' else ''
        return {model for model in models if family in model.lower()}
    if vendor=='Cursor' or vendor=='WorkBuddy' and row.get('id')=='workbuddy:credits':return set(models)
    return set()


class WindowMetrics:
    """Read on the monitor worker. Anonymous historical events stay anonymous."""
    def __init__(self,path):self.path=Path(path);self.cache={};self.derived={}
    def events(self,vendor,account,start,now,include_local=False):
        key=(vendor,account,start,include_local,int(now//15))
        if key in self.cache:return self.cache[key]
        self.cache={old:value for old,value in self.cache.items() if old[-1]==key[-1]}
        if not self.path.exists():return []
        db=sqlite3.connect(self.path.resolve().as_uri()+'?mode=ro',uri=True,timeout=.1)
        db.row_factory=sqlite3.Row;deadline=time.monotonic()+1
        db.set_progress_handler(lambda:int(time.monotonic()>deadline),10000)
        try:
            billing=vendor=='DeepSeek' and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='event_billing'").fetchone()
            extra=',provider AS billing_provider,requested_at' if billing else ',NULL AS billing_provider,NULL AS requested_at'
            join=' LEFT JOIN event_billing USING(source,event)' if billing else ''
            rows=db.execute('''SELECT event AS id,session,model,at,input,output,cache,cache_write,reasoning,account'''+extra+''' FROM events'''+join+'''
                WHERE source=? AND (account=? OR (? AND account IS NULL)) AND at>=? AND at<? AND
                COALESCE((SELECT priority FROM event_origin o WHERE o.source=events.source AND o.event=events.event),0)>=
                COALESCE((SELECT MAX(priority) FROM event_origin o WHERE o.source=events.source AND o.group_id=events.session),0)
                ORDER BY at,event LIMIT 50001''',(vendor,account,include_local,start,now)).fetchall()
            result=None if len(rows)>50000 else [dict(row) for row in rows]
            self.cache[key]=result;return result
        finally:db.close()
    def __call__(self,vendor,quota,local,now=None):
        now=time.time() if now is None else now;rows=[]
        if vendor=='DeepSeek':
            from billing_metrics import prepare
            return prepare(self,vendor,quota,local,now)
        fresh=not quota.get('stale') and not quota.get('error_code') and (at:=stamp(quota.get('at'))) is not None and 0<=now-at<=1800
        for row in quota.get('windows',[]):
            metrics=dict(consumed=None,reply=None,cost=None,tokens_per_hour=None)
            native=(quota.get('account') or {}).get('id');account=window_account(row) or native
            reset=stamp(row.get('reset'));duration=number(row.get('duration'))
            if fresh and number(row.get('used')) is not None:
                cycle_start=reset-duration if reset is not None and duration and reset-duration<=now<reset else None
                horizon=int(now//15)*15-7*86400
                since=min(cycle_start,horizon) if cycle_start is not None else horizon
                # Like the source's consumer links, the native client may show
                # its anonymous local logs as local estimates. They are never
                # relabelled as this account, or linked to another account's row.
                local_allowed=not window_account(row) or account==native
                events=self.events(vendor,account,since,now,include_local=local_allowed)
                if events:
                    models=model_scope(vendor,row,{event['model'] for event in events})
                    if models:
                        key=(vendor,account,since,local_allowed,cycle_start,tuple(sorted(models)),row.get('price_region','international'),int(now//15))
                        self.derived={old:value for old,value in self.derived.items() if old[-1]==key[-1]}
                        if key not in self.derived:
                            if cycle_start is not None:metrics=summarize(events,cycle_start,now,models,key[-2])
                            metrics['reply']=recent_reply_rate(events,models,now)
                            metrics['scope']='local' if any(event.get('account') is None for event in events if event['model'] in models) else 'account'
                            self.derived[key]=metrics
                        metrics=dict(self.derived[key])
            # This counter is read directly from the same official WorkBuddy
            # credit pool; it is not anonymous token history or another cycle.
            balance=quota.get('credit_balance')
            if fresh and vendor=='WorkBuddy' and row.get('id')=='workbuddy:credits' and balance:
                used=number(balance.get('used'));capacity=number(balance.get('total'))
                if used is not None:metrics['consumed']=dict(used=used,capacity=capacity)
            rows.append({**row,'metrics':metrics})
        return {**quota,'windows':rows}
