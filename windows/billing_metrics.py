"""APIBilling / BalanceSpend counterparts, prepared on the monitor worker.

Provider balances never imply a percentage. A missing price poisons that
currency's estimate rather than silently undercounting a recorded request.
"""
import math
from datetime import datetime
from decimal import Decimal,InvalidOperation
from catalog_pricing import summed_cost
from quota_insights import number

DURATIONS={'day':86400,'week':7*86400,'month':30*86400}


def decimal(value):
    if isinstance(value,bool) or value is None:return None
    try:
        result=Decimal(str(value));return result if result.is_finite() else None
    except (ValueError,InvalidOperation):return None


def money(value,currency,estimated=False,short=False):
    value=decimal(value)
    if value is None:return '—'
    symbol={'USD':'$','CNY':'¥','EUR':'€','HKD':'HK$','MOP':'MOP$'}.get(currency,currency+' ')
    minimum=Decimal('.000001') if estimated else Decimal('.01')
    if estimated and 0<value<minimum or short and value>0 and value.quantize(Decimal('.01'))==0:return '<'+symbol+('0.000001' if estimated else '0.01')
    places=6 if estimated else 2
    rounded=value.quantize(Decimal(1).scaleb(-places))
    result=f'{rounded:,.{places}f}'
    if estimated:result=result.rstrip('0').rstrip('.') if '.' in result else result
    if estimated:
        result+=('.00' if '.' not in result else '0' if len(result.split('.')[1])==1 else '')
    if short and abs(value.quantize(Decimal('.01')))>=100:result=f'{value.quantize(Decimal(".01")):,.0f}'
    return '-'+symbol+result[1:] if result.startswith('-') else symbol+result


def level(account,balance,now):
    at=number(account.get('at'));amount=decimal(balance.get('balance'))
    if account.get('stale') or account.get('error_code') or at is None or not 0<=now-at<=1800:return None
    if amount is None:return None
    if account.get('is_available') is False:return 'critical'
    if amount<=0:return 'critical'
    return 'warning' if amount<={'CNY':Decimal(10),'USD':Decimal(2)}.get(balance.get('currency'),Decimal(0)) else 'ok'


def official_price(model,event,region,at):
    if event.get('billing_provider')!='deepseek-official':return None
    return summed_cost(model,event,region,number(event.get('requested_at')) if number(event.get('requested_at')) is not None else at)


def spend(costs,currency,start,end,now):
    """APIBilling.spend takes CostBucket starts, not raw request timestamps."""
    span=min(now,end)-start
    if span<=0:return None
    total=Decimal(0)
    for bucket in costs:
        if bucket['at']+900<=start or bucket['at']>=end:continue
        amount=decimal(bucket.get('amounts',{}).get(currency))
        if amount is None:return None
        total+=amount
    return dict(cost=str(total),per_day=str(total*Decimal(86400)/Decimal(str(span))),span=span)


def period_metrics(events,currency,period,now,region='international',price=official_price):
    end=math.ceil(now/900)*900;start=end-DURATIONS[period];span=min(now,end)-start
    if events is None or span<=0:return None
    selected=[event for event in events if event['at']<=now and int(event['at']//900)*900<end and int(event['at']//900)*900+900>start]
    buckets={}
    for event in selected:
        at=int(event['at']//900)*900;item=price(event['model'],event,region,at)
        amount=item['amount'] if item and item['currency']==currency else None
        if at not in buckets:buckets[at]=Decimal(0)
        buckets[at]=None if amount is None or buckets[at] is None else buckets[at]+amount
    spent=spend([dict(at=at,amounts={currency:amount} if amount is not None else {}) for at,amount in buckets.items()],currency,start,end,now)
    step=900 if period=='day' else 86400
    floor=lambda value:int(value//900)*900 if step==900 else int(datetime.fromtimestamp(value).replace(hour=0,minute=0,second=0,microsecond=0).timestamp())
    columns={};at=floor(start)
    while at<end:columns[at]=Decimal(0);at+=step
    for at,amount in buckets.items():
        slot=floor(at)
        if slot in columns:columns[slot]=None if amount is None or columns[slot] is None else columns[slot]+amount
    return dict(cost=spent['cost'] if spent else None,per_day=spent['per_day'] if spent else None,
                span=span,tokens=sum(event['input']+event['output']+event.get('cache',0) for event in selected),
                tokens_per_hour=round(sum(event['input']+event['output'] for event in selected)*3600/span),
                columns=[dict(at=at,amount=str(amount) if amount is not None else None) for at,amount in sorted(columns.items())])


def legacy_account(vendor,quota):
    """Existing DeepSeek adapter's actual official balances, not subscription wallets."""
    identity=quota.get('account') or {}
    return dict(id=identity.get('id') or vendor,vendor=vendor,provider=vendor,legacy=not identity.get('id'),
        balances=quota.get('wallets',[]),at=quota.get('at'),stale=quota.get('stale',False),error_code=quota.get('error_code'),
        is_available=quota.get('is_available'),notice=quota.get('notice') if quota.get('error_code') else None,
        periods={},reply=None)


def prepare(reader,vendor,quota,local,now):
    account=legacy_account(vendor,quota);identity=(quota.get('account') or {}).get('id')
    key=('billing',identity,quota.get('at'),int(now//15))
    cached=getattr(reader,'billing_cache',{})
    if key not in cached:
        # Legacy, unidentified DeepSeek requests remain local estimates. An
        # identified account never acquires anonymous or another account's use.
        events=reader.events(vendor,identity,now-30*86400-900,now,include_local=identity is None) if reader.path.exists() else None
        currencies={str(balance.get('currency') or 'CNY') for balance in account['balances']} or {'CNY'}
        prices={}
        def cached_price(model,event,region,at):
            key=(event['id'],region)
            if key not in prices:prices[key]=official_price(model,event,region,at)
            return prices[key]
        periods={currency:{period:period_metrics(events,currency,period,now,'china' if currency=='CNY' else 'international',price=cached_price) for period in DURATIONS} for currency in currencies}
        from quota_metrics import recent_reply_rate
        cached={key:dict(periods=periods,reply=recent_reply_rate(events,None,now) if events else None)}
        reader.billing_cache=cached
    return {**quota,'api_billing':[{**account,**cached[key]}]}


def runs_out(amount,cost,span,read_at):
    amount=decimal(amount);cost=decimal(cost)
    if amount is None or cost is None or amount<=0 or cost<=0:return None
    seconds=float(amount/cost)*span
    return read_at+seconds if math.isfinite(seconds) else None


def figures(account,balance,measure,period,now):
    """BalanceMetrics.figure: the two source columns, never quota percentages."""
    currency=str(balance.get('currency') or 'CNY');values=account.get('periods',{}).get(currency,{}).get(period)
    cost=decimal(values.get('cost')) if values else None;pace=decimal(values.get('per_day')) if values else None
    amount=decimal(balance.get('balance'));rung=level(account,balance,now)
    label={'day':'近 24 小时','week':'近 7 天','month':'近 30 天'}[period]
    estimated=('费用估算 · '+label,money(cost,currency,estimated=True) if cost is not None else '暂无价格','text')
    def burn(caption):return caption,money(pace,currency,short=True)+'/天' if pace is not None else '暂无价格',rung or 'secondary'
    if measure=='cost':return estimated,burn('消耗速率')
    if measure=='tokens':
        reply=account.get('reply');rate=reply.get('tokens_per_second') if reply else None
        return ('回复速率 · '+label,(f'{rate:.1f}/s' if rate<10 else f'{int(rate)}/s') if rate is not None else '—','text'),('回复次数',str(reply['calls']) if reply else '—','text')
    if measure=='consumed':
        from quota_metric_views import short
        return ('Token 消耗 · '+label,short(values['tokens']) if values else '—','text'),('平均速率',short(values['tokens_per_hour'])+'/h' if values else '—','text')
    if measure=='burn':
        runout='—';ink='secondary'
        if amount is not None and cost is not None and rung is not None:
            if amount<=0:runout='已耗尽';ink=rung
            elif cost<=0:runout='暂无消耗'
            else:
                read_at=number(account.get('at'));at=runs_out(amount,cost,values['span'],read_at if read_at is not None else now)
                if at is not None:
                    ahead=at-now
                    from quota_metric_views import forecast_time
                    try:runout=forecast_time(at,now) if ahead<7*86400 else datetime.fromtimestamp(at).strftime('%m月%d日 %H:%M' if ahead<365*86400 else '%Y年%m月');ink='text'
                    except (ValueError,OverflowError,OSError):pass
        return burn('消耗速率 · '+label),('预计耗尽',runout,ink)
    return ('账户余额',money(amount,currency),rung or 'text'),estimated
