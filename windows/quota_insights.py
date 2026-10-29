"""QuotaCycle / UsageAnalytics.pace / QuotaMath Windows translation.

Samples are provider observations, never simulated consumption. Persistence is
called on the quota worker, not the GUI thread. No credentials or prompts enter
the history; account scope uses the existing opaque identity.
"""
import math,sqlite3,time
from pathlib import Path
from usage_display import window_account,window_key
from session_formats import stamp


def number(value):
    return float(value) if isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value) else None


def pace(samples,reset,duration,now):
    result=dict(rate=None,elapsed=None,required=None,after_reset=False)
    reset=number(reset);duration=number(duration)
    if reset is None or duration is None or duration<=0 or not reset-duration<=now<reset:return result
    start=reset-duration;interval=3600 if duration>=86400 else min(900,duration/2)
    current=sorted((at,remaining) for at,remaining in samples if start<=at<=now and at<reset)
    cut=0
    for index in range(1,len(current)):
        if current[index][1]-current[index-1][1]>=5:cut=index
    current=current[cut:]
    if not current:return result
    buckets={}
    for sample in current:buckets[int((sample[0]-start)/interval)]=sample
    sampled=[current[0]]
    for key in sorted(buckets):
        if buckets[key][0]>sampled[-1][0]:sampled.append(buckets[key])
    earliest,last=sampled[0],sampled[-1];span=last[0]-earliest[0]
    if span<interval:
        return dict(result,elapsed=span,required=interval,after_reset=any(at<earliest[0] for at,_ in samples))
    lookback=7*86400 if duration>=28*86400 else 86400 if duration>=7*86400 else duration/5
    first=next((sample for sample in reversed(sampled) if sample[0]<=last[0]-lookback),earliest)
    elapsed=last[0]-first[0]
    if elapsed>=interval:result['rate']=max(0,first[1]-last[1])/(elapsed/3600)
    return result


def outlook(row,now):
    reset=stamp(row.get('reset'));used=number(row.get('used'));duration=number(row.get('duration'))
    insights=row.get('insights') or {};rate=number(insights.get('rate'))
    result=dict(state='untimed',interval=None,before_reset=False,projected=None)
    if reset is None:return result
    if used is None:return dict(result,state='no_estimate')
    remaining=max(0,min(100,100-used))
    if remaining<=.5:return dict(result,state='exhausted')
    if duration is None or duration<=0:return dict(result,state='no_estimate')
    if rate==0:return dict(result,state='no_usage')
    if rate is None or rate<=0:return dict(result,state='sampling')
    interval=remaining/rate*3600
    if not math.isfinite(interval) or interval<=0:return dict(result,state='sampling')
    return dict(state='exhausts',interval=interval,before_reset=interval<reset-now,
                projected=min(100,used+rate*(reset-now)/3600) if reset>now else None)


class QuotaHistory:
    def __init__(self,path):self.path=Path(path)
    def decorate(self,vendor,quota,now=None):
        now=time.time() if now is None else now;at=stamp(quota.get('at'))
        if at is None or at>now or now-at>1800 or quota.get('stale') or quota.get('error_code'):return quota
        self.path.parent.mkdir(parents=True,exist_ok=True)
        db=sqlite3.connect(self.path,timeout=.25)
        try:
            db.execute('CREATE TABLE IF NOT EXISTS samples(vendor TEXT,scope TEXT,window TEXT,at REAL,remaining REAL,PRIMARY KEY(vendor,scope,window,at))')
            rows=[];fallback=(quota.get('account') or {}).get('id') or ''
            with db:
                for original in quota.get('windows',[]):
                    row=dict(original);used=number(row.get('used'));scope=window_account(row) or fallback;key=window_key(row)
                    if used is None:
                        # An explicit unknown reading breaks the numeric series.
                        latest=db.execute('SELECT MAX(at) FROM samples WHERE vendor=? AND scope=? AND window=?',(vendor,scope,key)).fetchone()[0]
                        if latest is None or at>latest:db.execute('DELETE FROM samples WHERE vendor=? AND scope=? AND window=?',(vendor,scope,key))
                        rows.append(row);continue
                    db.execute('INSERT OR IGNORE INTO samples VALUES(?,?,?,?,?)',(vendor,scope,key,at,max(0,min(100,100-used))))
                    duration=number(row.get('duration'));since=now-max(7*86400,duration or 0)
                    samples=db.execute('SELECT at,remaining FROM samples WHERE vendor=? AND scope=? AND window=? AND at>=? AND at<=? ORDER BY at LIMIT 20000',(vendor,scope,key,since,now)).fetchall()
                    row['insights']=pace(samples,stamp(row.get('reset')),duration,now);rows.append(row)
                db.execute('DELETE FROM samples WHERE at<?',(now-400*86400,))
            return {**quota,'windows':rows}
        finally:db.close()
