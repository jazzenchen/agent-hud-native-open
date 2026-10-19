"""Actual Windows HUD credit rendering, using explicit fixtures only."""
import json,sys
from pathlib import Path
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from views import SimpleMeterView
from preferences import load
from native_material_preview import Scene
from workbuddy_quota import parse


def main():
    app=QApplication([]);app.setStyle('Fusion');app.setQuitOnLastWindowClosed(False)
    directory=Path(sys.argv[1]);directory.mkdir(parents=True,exist_ok=True)
    scene=Scene();scene.setFixedSize(860,600);scene.show();scene.raise_();QTest.qWait(100)
    quota=parse(dict(code=0,data=dict(SubscriptionPackageName='标准版',Packages=[dict(PackageCode='sample',CycleTotalCapacity='7200',CycleRemainCapacity='205.33',CycleUsedCapacity='6994.67')])),dict(uid='preview-only',nickname='示例账户'))
    meter=SimpleMeterView('WorkBuddy',app.primaryScreen(),load(dict(edge='left',glass=True)),lambda _:None)
    meter.set_data(dict(quota=quota,local=dict(sessions=[])));meter.place(scene.x()+20,scene.y()+250);meter.show()
    records=[]
    for theme in ('dark','light'):
        meter.panel.animation.jump(0.);meter.settings['hud_appearance']=theme;meter.apply_material()
        meter.open_panel();meter.panel.animation.jump(1.);meter.panel.raise_();QTest.qWait(100)
        bounds=meter.panel.geometry().adjusted(-8,-8,8,8)
        app.primaryScreen().grabWindow(0,bounds.x(),bounds.y(),bounds.width(),bounds.height()).save(str(directory/(theme+'.png')))
        records.append(dict(theme=theme,visible=meter.panel.isVisible(),height=meter.panel.height(),natural_height=meter.panel.natural_height()))
    (directory/'result.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
    meter.hide_all();scene.close()
    for widget in (meter.peek,meter.panel,meter.glow,meter):widget.close()
    print(json.dumps(records))


if __name__=='__main__':main()
