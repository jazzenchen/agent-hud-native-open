"""QuotaAlertTracker and ResetCreditTracker, ported from original core logic."""
import time,uuid
from session_formats import stamp
from usage_display import window_key,window_account
from quota_insights import number,outlook


def fresh(quota,now):
    at=stamp(quota.get('at'))
    return at is not None and 0<=now-at<=1800 and not quota.get('stale') and not quota.get('error_code')


class QuotaEvents:
    def __init__(self):self.previous={};self.credit_previous={}
    def update(self,snapshot,now=None):
        now=time.time() if now is None else now;result=[];known=set();accounts=set()
        for vendor,data in snapshot.items():
            quota=data.get('quota') or {};fallback=(quota.get('account') or {}).get('id') or ''
            for row in quota.get('windows',[]):
                account=window_account(row) or fallback;key=(vendor,account,window_key(row));known.add(key)
                if quota.get('is_current') is False:self.previous.pop(key,None);continue
                if not fresh(quota,now):continue
                at=stamp(row.get('at') or quota.get('at'));old=self.previous.get(key)
                if at is None or at>now or now-at>1800 or old and at<=old['at']:continue
                used=number(row.get('used'))
                if used is None:self.previous.pop(key,None);continue
                remaining=max(0,min(100,100-used));reset=stamp(row.get('reset'))
                if reset is not None and reset<=now:continue
                if reset is None and remaining!=100:continue
                forecast=outlook(row,now);predicts=reset is not None and forecast['before_reset']
                critical=remaining<=10;exhausted=remaining<=.5;risk=critical or exhausted or predicts
                warned=old.get('warned') if old and old.get('warned') and old['warned']>at else None
                self.previous[key]=dict(at=at,remaining=remaining,reset=reset,critical=critical,exhausted=exhausted,risk=risk,warned=warned)
                if old is None:continue
                advanced=old['reset'] is not None and reset is not None and reset>old['reset'] and at>=old['reset']
                restored=remaining==100 and remaining-old['remaining']>=5
                kind='reset' if advanced or restored else 'exhaustion' if exhausted and not old['exhausted'] or risk and not old['risk'] and (critical or warned is None) else None
                if kind is None:continue
                other=[]
                if kind=='reset':
                    other=[r['label'] for r in quota.get('windows',[]) if (window_account(r) or fallback)==account and window_key(r)!=window_key(row) and number(r.get('used')) is not None and r['used']>=99.5 and (stamp(r.get('reset')) or 0)>now]
                if kind=='exhaustion' and not critical:self.previous[key]['warned']=reset
                result.append(dict(id=uuid.uuid4().hex,kind='quota',event=kind,vendor=vendor,source='',session='',
                    account=account,window=window_key(row),label=row['label'],summary='已重置' if kind=='reset' else '已耗尽' if exhausted else '即将耗尽',
                    remaining=remaining,reset=reset,at=at,time_to_exhaust=forecast['interval'] if predicts and kind=='exhaustion' else None,other_limits=other))
            if not fallback:continue
            account_key=(vendor,fallback);accounts.add(account_key)
            if quota.get('is_current') is False:self.credit_previous.pop(account_key,None);continue
            credits=quota.get('reset_credits');old=self.credit_previous.get(account_key)
            if not isinstance(credits,dict) or not fresh(quota,now):continue
            at=stamp(quota['at']);count=credits.get('availableCount')
            if not isinstance(count,int) or isinstance(count,bool) or count<0 or old and at<=old['at']:continue
            listed=credits.get('credits');listed=listed if isinstance(listed,list) else None
            valid=[entry for entry in (listed or []) if isinstance(entry,dict) and isinstance(entry.get('id'),str)]
            ids={entry['id'] for entry in valid} if listed is not None else old.get('ids') if old else None
            self.credit_previous[account_key]=dict(at=at,count=count,ids=ids)
            if old is None or count<=old['count']:continue
            ordered=sorted(valid,key=lambda entry:stamp(entry.get('expiresAt')) or float('inf'))
            new=[entry for entry in ordered if entry['id'] not in old['ids']] if old['ids'] is not None else []
            result.append(dict(id=uuid.uuid4().hex,kind='reset_credits',vendor=vendor,source='',session='',account=fallback,
                summary='获得使用量重置',added=count-old['count'],available=count,credits=ordered,new_credits=new,at=at))
        self.previous={key:value for key,value in self.previous.items() if key in known}
        self.credit_previous={key:value for key,value in self.credit_previous.items() if key in accounts}
        return result
