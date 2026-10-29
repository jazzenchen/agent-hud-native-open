"""Capture actual reminder panels driven by unchanged source animation exports."""
import argparse,json
from pathlib import Path
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from bot_player import reminder_library,clock
from attention_protocol import permission,completion
from preferences import load
from views import SimpleMeterView
from native_material_preview import Scene


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    app=QApplication([]);app.setStyle('Fusion')
    if not reminder_library().ready:raise RuntimeError('Source reminder export has not been packed yet')
    scene=Scene();scene.setFixedSize(860,600);scene.show();scene.raise_();QTest.qWait(100)
    meter=SimpleMeterView('Codex',app.primaryScreen(),load(dict(edge='left')),lambda _:None)
    meter.set_data(dict(quota=dict(windows=[]),local=dict(sessions=[])))
    meter.place(scene.x()+20,scene.y()+250);meter.show();meter.apply_material()
    events=[permission('claude',dict(session_id='demo',tool_name='Bash',tool_input=dict(command='Run tests'))),
            completion('codex',dict(hook_event_name='Stop',session_id='demo',turn_id='demo',last_assistant_message='演示回复')),
            dict(id='demo-reset',kind='quota',event='reset',vendor='WorkBuddy',label='5 小时限额',remaining=100,
                 at=1800000000,reset=1800007200,other_limits=[],summary='已重置')]
    events[1]['id']='demo-long-reply';events[1]['started_at']=events[1]['at']-601
    results=[]
    for light in (False,True):
        meter.settings['hud_appearance']='light' if light else 'dark'
        for event in events:
            meter.panel.animation.jump(0.);meter.attention_events=[event];meter.apply_material()
            meter.open_panel();meter.panel.animation.jump(1.);meter.panel.raise_()
            player=meter.panel.reminder;clock().discard(player);player.stop()
            images=[]
            for step in (0,12,24,36,48,60):
                player.advance(100+step/24)
                # Freeze only this actor's recording clock; paint and material
                # remain the actual native panel. No transparent-preview fringe.
                scene.raise_();meter.panel.raise_();meter.panel.repaint();QTest.qWait(20)
                bounds=meter.panel.geometry().adjusted(-8,-8,8,8)
                image=app.primaryScreen().grabWindow(0,bounds.x(),bounds.y(),bounds.width(),bounds.height()).toImage();images.append(image)
                image.save(str(args.output/f'{event["kind"]}-{light}-{step:02d}.png'))
            changed=sum(left!=right for left,right in zip(images,images[1:]))
            results.append(dict(kind=event['kind'],light=light,changed=changed,frames=len(images)))
            if changed<2:raise AssertionError('Reminder bot did not animate')
            meter.panel.hide()
    meter.hide_all();scene.close()
    for widget in (meter.peek,meter.panel,meter.glow,meter):widget.close()
    (args.output/'actual-reminder-panels.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print(json.dumps(results))


if __name__=='__main__':main()
