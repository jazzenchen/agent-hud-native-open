"""Actual native five-measure panel with explicit, internally computed demo calls."""
import argparse,json,time
from pathlib import Path
from PySide6.QtCore import Qt,QPointF
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from native_material_preview import Scene
from preferences import load
from views import SimpleMeterView
from quota_metrics import summarize,MEASURES
from usage_ledger import UsageLedger


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    app=QApplication([]);app.setStyle('Fusion');now=time.time()
    events=[dict(id=f'demo-{n}',session='demo',model='gpt-6.1-sol',at=now-1000+n*35,
                 input=8000+n*17,output=1200+n*8,cache=18000,cache_write=1000,reasoning=400) for n in range(28)]
    metrics=summarize(events,now-10800,now,{'gpt-6.1-sol'})
    row=dict(label='5-hour',used=68,reset=now+7200,duration=18000,insights=dict(rate=12.5),metrics=metrics)
    counts=UsageLedger.counts(tuple(sum(event[key] for event in events) for key in ('input','output','cache','cache_write','reasoning')))
    buckets=[dict(at=int(event['at']//900)*900,**UsageLedger.counts(tuple(event[key] for key in ('input','output','cache','cache_write','reasoning')))) for event in events]
    data=dict(quota=dict(windows=[row],at=now,account=dict(id='demo',label='示例账户'),plan='Demo plan'),
              local=dict(sessions=[dict(id='demo',title='完善 Windows 交互',state='running',updated=now,tokens=counts['total'])],
                         stats=dict(event_count=len(events),totals=counts,buckets=buckets)))
    scene=Scene();scene.setFixedSize(900,700);scene.show();scene.raise_();QTest.qWait(100)
    meter=SimpleMeterView('Codex',app.primaryScreen(),load(dict(edge='left')),lambda _:None)
    meter.set_data(data);meter.place(scene.x()+24,scene.y()+260);meter.show();records=[]
    for theme in ('dark','light'):
        meter.panel.animation.jump(0.);meter.settings['hud_appearance']=theme;meter.apply_material()
        meter.open_panel();meter.panel.animation.jump(1.)
        for metric,_ in MEASURES:
            panel=meter.panel;panel.grab()
            rect=next(rect for rect,action in panel.hits if action==('metric','Codex',metric))
            QTest.mouseClick(panel,Qt.MouseButton.LeftButton,pos=(rect.center()+QPointF(18,14)).toPoint())
            scene.raise_();panel.raise_();panel.repaint();QTest.qWait(30)
            bounds=panel.geometry().adjusted(-8,-8,8,8)
            app.primaryScreen().grabWindow(0,bounds.x(),bounds.y(),bounds.width(),bounds.height()).save(str(args.output/(metric+'-'+theme+'.png')))
            records.append(dict(metric=metric,theme=theme,selected=panel.metric_selection.get('Codex')))
    meter.hide_all();scene.close()
    for widget in (meter.peek,meter.panel,meter.glow,meter):widget.close()
    (args.output/'actual-picker.json').write_text(json.dumps(dict(demo=True,cases=records,metrics=metrics),indent=2),encoding='utf-8')
    print(json.dumps(records))


if __name__=='__main__':main()
