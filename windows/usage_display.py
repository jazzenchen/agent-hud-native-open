"""Exclusive chart channels and common time aggregation for ledger consumers."""
import time
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
