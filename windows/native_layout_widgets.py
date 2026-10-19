"""Owned-data Windows compositor captures for source layout widget checks.

No profile writes or installed agent launches. Data is explicitly a fixture.
Run with the Windows Qt platform, optionally QT_SCALE_FACTOR=1.25/1.5.
"""
import json,sys,time
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
    screen=app.primaryScreen();scene=Scene();scene.setGeometry(screen.geometry());scene.show();scene.raise_();QTest.qWait(80)
    now=time.time();rows=[dict(id=str(i),label=name,short_name=short,used=value,reset=now+7200) for i,(name,short,value) in enumerate([
        ('5 小时限额','5 小时',27),('Weekly allowance','Weekly',75),('长名称中文额度窗口','中文窗口',None),('Review allowance','Review',96),('Session 🎮 quota','Session',42)])]
    buckets=[dict(at=now-i*3600,fresh_input=100*(i%7),visible_output=140*(i%5),total=100*(i%7)+140*(i%5)) for i in range(168)]
    stats=dict(buckets=buckets,model_buckets=[dict(row,model='fixture-model') for row in buckets],event_count=len(buckets))
    data=dict(quota=dict(account={'id':'fixture','label':'Fixture account'},plan='Fixture plan',at=now,windows=rows),local=dict(sessions=[],history_stats=stats))
    variants=[('ring-small',{'widget':'ring','ringSize':'small','columns':4}),('ring-medium',{'widget':'ring','columns':6}),
              ('ring-large',{'widget':'ring','ringSize':'large','columns':2}),('number',{'widget':'number','columns':6}),
              ('chart',{'widget':'chart','period':'week'}),('paired',{'widget':'ring','span':'half'})]
    records=[]
    for theme in ('light','dark'):
        for name,block in variants:
            settings=load(dict(mode='simple',edge='top',hud_appearance=theme,glass=True,separates_agents=name!='paired',glow_hidden=True))
            meter=SimpleMeterView('Codex',screen,settings,lambda _:None)
            meter.layout_store=LayoutStore();meter.layout_store.propose(dict(style=dict(width=540),hiddenSections=['tokens','sessions'],blocks={'Codex':block,'Cursor':{'widget':'number','span':'half'}}))
            meter.set_group_data({'Codex':data,'Cursor':data} if name=='paired' else {'Codex':data});meter.place(screen.availableGeometry().center().x(),60)
            meter.show();meter.apply_material();meter.open_panel();meter.panel.animation.jump(1.);meter.panel.draft_bar.sync()
            scene.raise_();meter.raise_();meter.panel.raise_();QTest.qWait(100)
            panel=meter.panel;image=screen.grabWindow(0,panel.x(),panel.y(),panel.width(),panel.height())
            file=out/(theme+'-'+name+'.png');image.save(str(file))
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
