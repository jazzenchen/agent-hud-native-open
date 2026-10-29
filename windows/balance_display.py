"""Source SimpleMeterItem.balances and AgentPeek API lines."""
import time
from billing_metrics import legacy_account,money,level
from quota_insights import number


def balance_lines(vendor,quota,now=None,include_empty=False):
    if vendor!='DeepSeek':return []
    now=time.time() if now is None else now
    accounts=quota.get('api_billing',[]) if 'api_billing' in quota else [legacy_account(vendor,quota)]
    result=[]
    for account in accounts:
        balances=account.get('balances',[])
        if not balances and not include_empty:continue
        at=number(account.get('at'));fresh=not account.get('stale') and not account.get('error_code') and at is not None and 0<=now-at<=1800
        levels=[rung for balance in balances if (rung:=level(account,balance,now)) is not None]
        ink=('critical' if account.get('is_available') is False or 'critical' in levels else 'warning' if 'warning' in levels else 'ok' if levels else 'secondary') if fresh else 'secondary'
        first=balances[0] if balances else None
        result.append(dict(value=money(first.get('balance'),first.get('currency') or 'CNY') if first else '–',ink=ink))
    return result
