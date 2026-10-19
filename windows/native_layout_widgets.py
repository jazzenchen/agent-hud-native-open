"""Owned-data Windows compositor captures for source layout widget checks.

No profile writes or installed agent launches. Data is explicitly a fixture.
Run with the Windows Qt platform, optionally QT_SCALE_FACTOR=1.25/1.5.
"""
import json,sys,time
from copy import deepcopy
from pathlib import Path
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from native_material_preview import Scene
from views import SimpleMeterView
from preferences import load
from panel_layout import LayoutStore


def main():
    app=QApplication([]);app.setStyle('Fusion');app.setQuitOnLastWindowClosed(False)
    assert app.platformName()=='windows'
    out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
    screen=app.primaryScreen();scene=Scene();scene.setFixedSize(screen.geometry().size());scene.move(screen.geometry().topLeft());scene.show();scene.raise_();QTest.qWait(80)
    now=time.time();rows=[dict(id=str(i),label=name,short_name=short,used=value,reset=now+7200) for i,(name,short,value) in enumerate([
        ('5 小时限额','5 小时',27),('Weekly allowance','Weekly',75),('长名称中文额度窗口','中文窗口',None),('Review allowance','Review',96),('Session 🎮 quota','Session',42)])]
    buckets=[dict(at=now-i*3600,fresh_input=100*(i%7),visible_output=140*(i%5),total=100*(i%7)+140*(i%5)) for i in range(168)]
    stats=dict(buckets=buckets,model_buckets=[dict(row,model='fixture-model') for row in buckets],event_count=len(buckets))
    data=dict(quota=dict(account={'id':'fixture','label':'Fixture account'},plan='Fixture plan',at=now,windows=rows),local=dict(sessions=[],history_stats=stats))
    accounts_mode='--accounts' in sys.argv[2:]
    if accounts_mode:
        current={'id':'fixture','label':'Fixture current account','plan':'Fixture current plan'}
        old={'id':'previous','label':'Fixture previous account','plan':'Fixture old plan','is_current':False,'observed_at':now-3600,'notice':'Fixture retained reading; independent account scope.'}
        data['quota'].update(account=current,accounts=[current,old],windows=[{**row,'account_id':current['id']} for row in rows[:2]]+[{**row,'account_id':old['id']} for row in rows[2:4]],
            wallets=[dict(account_id=current['id'],currency='USD',balance=0),dict(account_id=old['id'],currency='USD',kind='onDemand',used=1.5,limit=None)])
        from billing_metrics import legacy_account,period_metrics
        api_quota=dict(windows=[],wallets=[dict(currency='CNY',balance=8.85),dict(currency='USD',balance=2.2)],at=now,is_available=True)
        account=legacy_account('DeepSeek',api_quota)
        events=[dict(id=str(index),session='fixture',at=now-index*3600,model='deepseek-v4-flash',input=100000,output=50000,cache=20000,billing_provider='deepseek-official') for index in range(1,169)]
        account['periods']={currency:{period:period_metrics(events,currency,period,now,region) for period in ('day','week','month')} for currency,region in (('CNY','china'),('USD','international'))}
        api_data=dict(quota={**api_quota,'api_billing':[account]},local={'sessions':[]})
    variants=[('ring-small',{'widget':'ring','ringSize':'small','columns':4}),('ring-medium',{'widget':'ring','columns':6}),
              ('ring-large',{'widget':'ring','ringSize':'large','columns':2}),('number',{'widget':'number','columns':6}),
              ('chart',{'widget':'chart','period':'week'}),('paired',{'widget':'ring','span':'half'})]
    if accounts_mode:variants=[('accounts-ring',{'widget':'ring','columns':2}),('accounts-number',{'widget':'number','columns':2}),('accounts-chart',{'widget':'chart','period':'week'}),('api-number',{'widget':'number'}),('api-chart',{'widget':'chart','period':'week'}),('api-failed',{'widget':'number'}),('api-unpriced',{'widget':'chart','period':'week'}),('paired-api',{'widget':'ring','span':'half'})]
    records=[]
    for theme in ('light','dark'):
        for name,block in variants:
            paired=name.startswith('paired');client='DeepSeek' if name.startswith('api-') else 'Codex'
            settings=load(dict(mode='simple',edge='top',hud_appearance=theme,glass=True,separates_agents=not paired,glow_hidden=True))
            meter=SimpleMeterView(client,screen,settings,lambda _:None)
            changes={'Codex':block,'Cursor':{'widget':'number','span':'half'},'api:DeepSeek':block if client=='DeepSeek' else {'widget':'number','span':'half'}}
            meter.layout_store=LayoutStore();meter.layout_store.propose(dict(style=dict(width=540),hiddenSections=['tokens','sessions'],blocks=changes))
            current_api=deepcopy(api_data) if accounts_mode and name in ('api-failed','api-unpriced') else api_data if accounts_mode else None
            if name=='api-failed':current_api['quota']['api_billing'][0].update(stale=True,error_code='unavailable',notice='Fixture failed read; previous balance retained.')
            if name=='api-unpriced':
                for periods in current_api['quota']['api_billing'][0]['periods'].values():
                    for metrics in periods.values():
                        metrics.update(cost=None,per_day=None)
                        for column in metrics['columns']:column['amount']=None
            sources={'Codex':data,'Cursor':data} if name=='paired' else {'Codex':data,'DeepSeek':current_api} if name=='paired-api' else {'DeepSeek':current_api} if client=='DeepSeek' else {'Codex':data}
            meter.set_group_data(sources);meter.place(screen.availableGeometry().center().x(),60)
            meter.show();meter.apply_material()
            # Reassert the owned backdrop before sampling, not only before the
            # screenshot. A resident topmost HUD or a closing test window can
            # otherwise become part of the frozen glass sample.
            scene.raise_();QTest.qWait(50)
            meter.open_panel();meter.panel.animation.jump(1.);meter.panel.draft_bar.sync()
            scene.raise_();meter.raise_();meter.panel.raise_();QTest.qWait(100)
            panel=meter.panel;image=screen.grabWindow(0,panel.x(),panel.y(),panel.width(),panel.height())
            file=out/(theme+'-'+name+'.png')
            if image.isNull() or not image.save(str(file)):raise RuntimeError('Native capture could not be saved: '+str(file))
            samples=[]
            for _ in range(30):
                started=time.perf_counter();panel.repaint();samples.append((time.perf_counter()-started)*1000)
            samples.sort()
            records.append(dict(theme=theme,variant=name,file=file.name,width=panel.width(),height=panel.height(),naturalHeight=panel.natural_height(),lines=[len(line) for line in panel.provider_lines()],
                                repaintMs=dict(samples=30,p50=samples[14],p95=samples[28],maximum=samples[-1])))
            meter.hide_all();meter.peek.close();meter.panel.close();meter.glow.close();meter.close();QTest.qWait(10)
    scene.close();(out/'manifest.json').write_text(json.dumps(dict(platform=app.platformName(),scale=screen.devicePixelRatio(),fixture=True,
        performanceScope='Warm synchronous QWidget repaint only; excludes cold opening, polling, animations, input-to-display latency and resident frame pacing.',captures=records),indent=2),encoding='utf-8')
    print(json.dumps(dict(captures=len(records),platform=app.platformName(),destination=str(out))))


if __name__=='__main__':main()
