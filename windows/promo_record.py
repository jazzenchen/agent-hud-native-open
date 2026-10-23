"""Offline promo capture of the real Windows widgets, with demo-only data.

Owns only its opaque capture scene and child/tool windows. No provider calls,
settings writes, hooks, account access, or UsageLedger writes. Source animation
drivers are stepped on a recording clock; pixels come from the Windows desktop
compositor, not a recreated HTML product interface.
"""
import argparse,json,subprocess,time
from pathlib import Path
from PySide6.QtCore import Qt,QRectF,QPointF
from PySide6.QtGui import QPainter,QColor,QLinearGradient,QRadialGradient,QPainterPath,QImage,QCursor
from PySide6.QtWidgets import QApplication,QWidget,QVBoxLayout
from PySide6.QtTest import QTest
from preferences import load,validate
from views import SimpleMeterView
from promo_fixtures import build_demo
from attention_protocol import permission,completion
from bot_player import clock
from motion import motion_clock
from settings_window import SettingsWindow
from stats_widgets import TokenDashboard
from theme import apply_widget_theme


class Scene(QWidget):
    def __init__(self):
        super().__init__(None,Qt.WindowType.FramelessWindowHint|Qt.WindowType.Tool|Qt.WindowType.WindowStaysOnTopHint)
        self.setFixedSize(1280,800);self.move(160,110)
        self.setWindowTitle('Agent HUD promo — isolated demo')
    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        g=QLinearGradient(0,0,1280,800);g.setColorAt(0,QColor('#071a34'));g.setColorAt(.55,QColor('#183659'));g.setColorAt(1,QColor('#345973'));p.fillRect(self.rect(),g)
        for color,cx,cy,r in [('#527a9b',1000,100,850),('#246b89',100,750,700)]:
            glow=QRadialGradient(cx,cy,r);glow.setColorAt(0,QColor(color));glow.setColorAt(1,QColor(0,0,0,0));p.fillRect(self.rect(),glow)
        for n in range(4):
            path=QPainterPath();path.moveTo(-100,670+n*60);path.cubicTo(300,220+n*55,620,910+n*50,1400,250+n*70)
            p.setPen(QColor(200,228,246,12+n*4));p.drawPath(path)
        p.end()


class DemoManager:
    preview=True
    def __init__(self,app,data):self.app=app;self.data=data;self.settings=load(dict(appearance='dark',edge='left'))
    def screen_settings(self,name):return {**self.settings,**self.settings['placements'].get(name,{})}
    def apply_setting(self,key,value,screen=None):
        target=self.settings if screen is None else self.settings['placements'].setdefault(screen,{})
        target[key]=validate(key,value)
    def refresh_now(self):pass


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path);parser.add_argument('--test',action='store_true');parser.add_argument('--only',help='Recapture one named chapter');args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    app=QApplication([]);app.setStyle('Fusion');app.setQuitOnLastWindowClosed(False)
    if app.platformName()!='windows':raise RuntimeError('Native Windows compositor required')
    screen=app.primaryScreen()
    if screen.devicePixelRatio()!=1 or screen.geometry().width()<1920 or screen.geometry().height()<1080:
        raise RuntimeError('Recorder requires a 1920x1080 or larger Windows desktop at 100% scaling')
    if args.only and args.only not in ('01-simple','02-details','03-approval','04-reply','05-modes','06-settings','07-accounts','08-tokens'):
        raise ValueError('Unknown chapter')
    now=time.time();fixture=build_demo(now,20);data=fixture['providers']
    scene=Scene();scene.show();scene.raise_();QTest.qWait(150)
    QCursor.setPos(scene.x()+1160,scene.y()+700)
    meter=SimpleMeterView('Codex',app.primaryScreen(),load(dict(edge='left',size=36,logo_size=36,collapse_delay=200)),lambda _:None)
    manager=DemoManager(app,data);settings=SettingsWindow(manager);settings.setWindowFlag(Qt.WindowType.WindowStaysOnTopHint,True);settings.resize(1100,700);settings.move(scene.x()+90,scene.y()+45)
    if settings.hud_preview is not None:settings.hud_preview.wallpaper=scene.grab()
    stats=QWidget(None,Qt.WindowType.Window|Qt.WindowType.WindowStaysOnTopHint);stats.setWindowTitle('Agent HUD — Token 用量');stats.resize(1040,700);stats.move(scene.x()+120,scene.y()+45)
    layout=QVBoxLayout(stats);layout.setContentsMargins(22,16,22,16);dashboard=TokenDashboard('Codex');dashboard.set_data(data['Codex']['local']['stats']);layout.addWidget(dashboard);apply_widget_theme(stats,False)
    meter.set_group_data(data);meter.place(scene.x()+100,scene.y()+230);meter.show();meter.apply_material()
    pending=permission('claude',dict(session_id='demo-only',tool_name='Bash',tool_input=dict(command='npm test')))
    pending['id']='promo-permission'
    reply=completion('codex',dict(hook_event_name='Stop',session_id='demo-only',turn_id='demo-only',last_assistant_message='已完成面板交互与主题调整，测试通过。'))
    reply['id']='promo-reply';reply['started_at']=reply['at']-620
    clips=['01-simple','02-details','03-approval','04-reply','05-modes','06-settings','07-accounts','08-tokens']
    def reset():
        meter.hide_all();settings.hide();stats.hide();meter.attention_events=[];meter.selected_attention=None
        meter.client='Codex'
        meter.settings.update(mode='simple',edge='left',hud_appearance='dark',separates_agents=True,panel_sessions=True,panel_tokens=True)
        meter.set_group_data(data);meter.place(scene.x()+100,scene.y()+230);scene.raise_();meter.show();meter.raise_();meter.apply_material()
        meter.enter_timer.stop();meter.leave_timer.stop()
    def open_panel():
        meter.open_panel();meter.panel.pinned=True;meter.panel.raise_()
    def step_motion():
        for driver in (meter.peek.animation,meter.panel.animation):
            if driver.running:
                motion_clock().active.discard(driver);driver.state.advance(1/30);driver.valueChanged.emit(driver.state.position)
                if driver.state.settled:driver.running=False;driver.finished.emit()
    records=[]
    try:
        for index,name in enumerate(clips):
            if args.only and name!=args.only:continue
            reset()
            if index==4:meter.settings.update(panel_sessions=False,panel_tokens=False)
            if index==1:open_panel()
            if index in (2,3):
                meter.attention_events=[pending if index==2 else reply];open_panel();meter.panel.reminder.stop()
            if index in (5,6):
                meter.hide_all();settings.sidebar.setCurrentRow(2 if index==5 else 1)
                settings.transition.animation.stop();settings.transition.effect.setOpacity(1.)
                if index==6:
                    settings.agent_page.list.setCurrentRow(next(i for i in range(settings.agent_page.list.count()) if settings.agent_page.list.item(i).data(Qt.ItemDataRole.UserRole)['vendor']=='WorkBuddy'))
                settings.show();settings.raise_()
            if index==7:meter.hide_all();stats.show();stats.raise_()
            QTest.qWait(100)
            frames=12 if args.test else 120
            out=args.output/(name+'.mp4')
            process=subprocess.Popen(['ffmpeg','-v','error','-y','-f','rawvideo','-pix_fmt','rgb24','-s','1280x800','-r','30','-i','-','-an','-c:v','libx264','-preset','fast','-crf','16','-pix_fmt','yuv420p',str(out)],stdin=subprocess.PIPE)
            try:
                for f in range(frames):
                    if index==0:
                        if f==20:meter.client='Claude';meter.data=data['Claude'];meter.hover()
                        if f==82:meter.peek.dismiss()
                    if index==1 and f==60:
                        meter.panel.grab()
                        hit=next((rect for rect,action in meter.panel.hits if action==('metric','Codex','tokens')),None)
                        if hit is not None:QTest.mouseClick(meter.panel,Qt.MouseButton.LeftButton,pos=(hit.center()+QPointF(18,14)).toPoint())
                    if index==4:
                        if f in (0,60):
                            meter.settings.update(mode='logos' if f==0 else 'notch',edge='top');meter.refresh_size();meter.place(scene.x()+640-meter.width()/2,scene.y()+80);meter.apply_material()
                        if f in (15,75):meter.hover()
                        if f==50:meter.peek.dismiss();meter.panel.collapse()
                    if index==5 and f==60:
                        manager.settings['appearance']='light';settings.apply_theme()
                    step_motion()
                    # One deterministic source clip frame for each encoded frame.
                    for player in (meter.bots,meter.panel.reminder):
                        clock().discard(player)
                        if (player is meter.bots and meter.isVisible()) or (player is meter.panel.reminder and meter.panel.isVisible()):player.advance(100+f/30)
                    meter.enter_timer.stop();meter.leave_timer.stop()
                    if index<5:
                        meter.raise_()
                        for widget in (meter.peek,meter.panel):
                            if widget.isVisible():widget.raise_();widget.repaint()
                        meter.repaint()
                    app.processEvents();QTest.qWait(18)
                    image=scene.screen().grabWindow(0,scene.x(),scene.y(),1280,800).toImage().convertToFormat(QImage.Format.Format_RGB888)
                    if image.width()!=1280 or image.height()!=800:raise RuntimeError('Unexpected native capture size or screen scaling')
                    process.stdin.write(bytes(image.constBits()))
                    if f in (min(frames-1,8),min(frames-1,75)):image.save(str(args.output/f'{name}-{f:03}.png'))
                process.stdin.close()
                if process.wait()!=0:raise RuntimeError('Footage encoding failed')
            finally:
                if process.poll() is None:process.kill()
            records.append(dict(file=out.name,frames=frames,source='Actual Windows Qt widgets + Windows compositor',demo=True))
            print(name+' captured',flush=True)
    finally:
        meter.hide_all()
        for widget in (meter.peek,meter.panel,meter.glow,meter,settings,stats,scene):widget.close()
    manifest=args.output/'capture.json'
    if args.only and manifest.exists():
        previous=json.loads(manifest.read_text(encoding='utf-8'))['clips']
        records=sorted({row['file']:row for row in previous+records}.values(),key=lambda row:row['file'])
    manifest.write_text(json.dumps(dict(demo=True,no_account_access=True,no_settings_writes=True,clips=records),indent=2),encoding='utf-8')


if __name__=='__main__':main()
