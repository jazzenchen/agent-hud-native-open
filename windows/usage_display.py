"""Exclusive chart channels and common time aggregation for ledger consumers."""
import json,time
CHANNELS=('fresh_input','cache','cache_write','visible_output','reasoning')


def hourly(stats,now=None,hours=24):
    end=int((time.time() if now is None else now)//3600)*3600
    rows={end-index*3600:dict(at=end-index*3600,**{key:0 for key in CHANNELS},total=0) for index in range(hours)}
    for report in stats:
        for bucket in report.get('buckets',[]):
            slot=int(bucket['at']//3600)*3600
            if slot not in rows:continue
            for key in CHANNELS:rows[slot][key]+=bucket.get(key,0)
            rows[slot]['total']+=bucket.get('total',0)
    return [rows[key] for key in sorted(rows)]


def account_label(quota):
    account=quota.get('account') or {}
    if len(quota.get('accounts') or [])>1:return str(len(quota['accounts']))+' 个账户／凭据范围'
    return account.get('label') or '账户身份未确认'


def window_account(row):
    value=row.get('account_id') or row.get('account')
    return (value.get('id') if isinstance(value,dict) else value) or ''


def window_key(row):
    """Do not let equally named windows of different accounts share a switch.

    Keep the old label key for legacy single-account rows. Reading old label
    preferences below deliberately applies them to all matching migrated rows.
    """
    account=window_account(row);identifier=row.get('id') or row.get('label','')
    return 'window:'+json.dumps([account,identifier],ensure_ascii=False,separators=(',',':')) if account or row.get('id') else row.get('label','')


def ordered_windows(rows,order):
    # Reordering within one account never moves another account's slots.
    groups={}
    def rank(row):
        key=window_key(row)
        return order.index(key) if key in order else order.index(row['label']) if row['label'] in order else len(order)
    for row in rows:groups.setdefault(window_account(row),[]).append(row)
    groups={key:iter(sorted(values,key=rank)) for key,values in groups.items()}
    return [next(groups[window_account(row)]) for row in rows]


def visible_quota(quota,vendor,settings):
    """Presentation choices never mutate account readings or historical usage."""
    hidden=set(settings.get('hidden_accounts',[]));fallback=(quota.get('account') or {}).get('id')
    def visible(row):
        return (window_account(row) or fallback) not in hidden
    excluded=set(settings.get('hidden_windows',{}).get(vendor,[]));order=settings.get('window_order',{}).get(vendor,[])
    rows=[row for row in quota.get('windows',[]) if window_key(row) not in excluded and row['label'] not in excluded and visible(row)]
    rows=ordered_windows(rows,order)
    return {**quota,'windows':rows,'wallets':[row for row in quota.get('wallets',[]) if visible(row)],
            'hidden':bool(quota.get('windows')) and not rows}
