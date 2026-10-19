"""Explicit promo-only sample readings. Pure data: no files, clients or network.

The resident application never imports this module. A recorder must display
DISCLOSURE outside the product UI. Nothing here is written to UsageLedger.
"""
import math

DISCLOSURE = '演示数据 · Demo data'
VENDORS = ('Codex', 'Claude', 'Cursor', 'WorkBuddy')
MODELS = ('Demo reasoning', 'Demo coding', 'Demo composer', 'Demo assistant')
CHANNELS = ('input', 'output', 'cache', 'cache_write', 'reasoning')
TITLES = ('打磨面板交互', '完善设置与主题', '检查动画与性能', '准备发布说明')


def counts(values):
    inp, out, cache, write, reasoning = values
    return dict(zip(CHANNELS, values), fresh_input=inp-write,
                visible_output=out-reasoning, total=inp+out+cache)


def build_demo(now, elapsed=0):
    """Return a deterministic 30-day snapshot at an explicit recording clock.

    elapsed (0..45 seconds) advances the final session's actual sample counters;
    every graph/model/session total is derived from the same exclusive values.
    Model labels deliberately describe fictional examples, not sold products.
    """
    if not math.isfinite(now) or not math.isfinite(elapsed):
        raise ValueError('The recording clock must be finite')
    elapsed = max(0., min(45., elapsed))
    hour = int(now//3600)*3600
    providers = {}
    for vendor_index, vendor in enumerate(VENDORS):
        events = []
        for age in range(30*24-1, -1, -1):
            # Several quiet hours and varied work bursts instead of a sine-wave
            # chart. Fixed arithmetic gives repeatable captures across machines.
            if age and (age+vendor_index*3)%24 not in (0, 1, 4, 7, 8, 9, 13, 17, 20, 21):
                continue
            seed = (age*37+vendor_index*83+19)%151
            growth = int(elapsed*57) if age == 0 else 0
            fresh = 1100+seed*31+growth
            write = 120+seed*3
            reasoning = 180+seed*7+growth//3
            visible = 370+seed*11+growth//2
            cache = 3200+seed*83
            session = f'demo-{vendor.lower()}-{age//24:02d}-{(age%24)//6}'
            events.append(dict(at=hour-age*3600, session=session,
                               **counts((fresh+write, visible+reasoning,
                                         cache, write, reasoning))))
        totals = counts(tuple(sum(event[key] for event in events) for key in CHANNELS))
        sessions = {}
        for event in events:
            row = sessions.setdefault(event['session'], dict(id=event['session'],
                title=TITLES[(len(sessions)+vendor_index)%len(TITLES)],
                updated=event['at'], state='done', tokens=0,
                model=MODELS[vendor_index]))
            row['updated'] = max(row['updated'], event['at'])
            row['tokens'] += event['total']
        session_rows = sorted(sessions.values(), key=lambda row:row['updated'], reverse=True)
        session_rows[0]['state'] = 'running'
        session_rows[0]['updated'] = now
        account = dict(id=f'demo-{vendor.lower()}', label='Demo account', evidence='demo')
        buckets = [{key:value for key,value in event.items() if key!='session'} for event in events]
        stats = dict(totals=totals, buckets=buckets,
                     model_buckets=[dict(row, model=MODELS[vendor_index]) for row in buckets],
                     models=[dict(totals, model=MODELS[vendor_index])],
                     event_count=len(events), hours=720, scope='demo', accounts=[account])
        used = (31, 63, 42, 18)[vendor_index]+elapsed*.04
        quota = dict(account=account, plan='Demo plan', observed=now,
                     windows=[dict(id='demo-cycle', label='5 小时限额', used=used,
                                   duration=18000, reset=now+7200)])
        if vendor=='WorkBuddy':
            quota['credit_balance'] = dict(remaining=840.-elapsed*.2,
                                          total=1200., used=360.+elapsed*.2)
        providers[vendor] = dict(local=dict(sessions=session_rows, stats=stats), quota=quota)
    return dict(demo=True, disclosure=DISCLOSURE, recorded_at=now,
                elapsed=elapsed, providers=providers)
