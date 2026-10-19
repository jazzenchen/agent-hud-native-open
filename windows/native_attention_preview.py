"""Owned native alert scene with sample hook payloads; no client/config access."""
import json,sys,uuid
from pathlib import Path
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from PySide6.QtCore import QRect,QPointF,Qt
from views import SimpleMeterView
from preferences import load
from native_material_preview import Scene
from attention_protocol import permission,completion


def main():
    app=QApplication([]);app.setStyle('Fusion');app.setQuitOnLastWindowClosed(False)
    output=Path(sys.argv[1]);output.mkdir(parents=True,exist_ok=True)
    scene=Scene();scene.setFixedSize(960,760);scene.show();scene.raise_();QTest.qWait(120)
    meter=SimpleMeterView('Claude',app.primaryScreen(),load(dict(mode='simple',edge='left',glass=True)),lambda _:None)
    meter.set_group_data({name:dict(quota=dict(windows=[dict(label='5-hour',used=value)]),local=dict(sessions=[])) for name,value in (('Codex',31),('Claude',63),('Cursor',42),('WorkBuddy',18))})
    meter.place(scene.x()+24,scene.y()+220);meter.show();meter.apply_material()
    request=permission('claude',dict(hook_event_name='PermissionRequest',session_id=str(uuid.uuid4()),tool_name='Bash',tool_input=dict(command='python -m unittest discover -s windows',description='Run the test suite'),cwd='C:\\Projects\\agent-hud-open'))
    reply=completion('codex',dict(hook_event_name='Stop',session_id=str(uuid.uuid4()),title='Build the dashboard',last_assistant_message='The dashboard is ready. The layout and interactions are in place.',model='Codex'))
    decisions=[];meter.attention_callback=lambda *args,**options:decisions.append((args,options))
    from session_navigation import can_navigate
    meter.attention_can_navigate=can_navigate;results=[]
    for appearance in ('dark','light'):
        meter.settings['hud_appearance']=appearance;meter.apply_material()
        for kind,event in (('permission',request),('completion',reply)):
            meter.panel.animation.jump(0.);meter.set_attention([event]);meter.hover();meter.panel.animation.jump(1.)
            meter.panel.raise_();QTest.qWait(100)
            bounds=meter.panel.geometry().adjusted(-8,-8,8,8)
            # Only this controlled wallpaper and our own alert are captured.
            meter.screen.grabWindow(0,bounds.x(),bounds.y(),bounds.width(),bounds.height()).save(str(output/(kind+'-'+appearance+'.png')))
            results.append(dict(kind=kind,appearance=appearance,width=meter.panel.width(),height=meter.panel.height(),visible=meter.panel.isVisible()))
            if kind=='permission':
                meter.panel.grab()
                rect=next(rect for rect,action in meter.panel.hits if isinstance(action,tuple) and action[2]=='allow')
                point=(rect.center()+QPointF(18,14)).toPoint();before=len(decisions)
                QTest.mousePress(meter.panel,Qt.MouseButton.LeftButton,pos=point)
                results[-1]['not_approved_on_press']=len(decisions)==before
                QTest.mouseRelease(meter.panel,Qt.MouseButton.LeftButton,pos=point)
                results[-1]['approved_on_release']=len(decisions)==before+1
    meter.hide_all()
    for widget in (meter.peek,meter.panel,meter.glow,meter,scene):widget.close()
    (output/'native-alerts.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print(json.dumps(results))


if __name__=='__main__':main()
