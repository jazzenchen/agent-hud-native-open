"""Windows window/tray lifecycle for the source-derived Simple HUD."""
import argparse
import json
import os
from pathlib import Path
import sys
import threading

from PySide6.QtCore import QObject, Signal, Qt, QTimer
from PySide6.QtGui import QAction, QColor, QIcon, QPainter, QPixmap
from PySide6.QtWidgets import QApplication, QSystemTrayIcon, QMenu, QDialog, QVBoxLayout, QLabel, QTabWidget, QTableWidget, QTableWidgetItem, QHeaderView

from providers import DATA
from runtime import Monitor
from source_design import DESIGN
from views import SimpleMeterView, compact
from placement import nearest_placement,group_origin
from preferences import DEFAULTS,load,validate
from settings_window import SettingsWindow


class Bridge(QObject):
    snapshot = Signal(dict)


class UsageWindow(QDialog):
    """The two original statistics tabs, scoped to available Windows records."""
    def __init__(self,client,data):
        super().__init__()
        self.setWindowTitle(client+' · 用量统计')
        self.resize(680,460)
        self.setStyleSheet('QDialog,QTabWidget::pane{background:#282828;color:#f5f5f7} '
            'QLabel,QTabBar::tab{color:#f5f5f7;padding:8px} '
            'QTabBar::tab{background:#333333;border-radius:7px;margin:3px} '
            'QTabBar::tab:selected{background:#555555} '
            'QTableWidget{background:#333333;color:#f5f5f7;border:1px solid #484848;border-radius:10px;gridline-color:#484848} '
            'QHeaderView::section{background:#282828;color:#98989d;border:0;padding:10px}')
        layout=QVBoxLayout(self)
        layout.addWidget(QLabel(client))
        tabs=QTabWidget()
        sessions=data.get('local',{}).get('sessions',[])
        for label in ('Tokens','Sessions'):
            table=QTableWidget(len(sessions),3)
            table.setHorizontalHeaderLabels(['会话','状态','会话累计 Tokens'])
            table.verticalHeader().hide()
            table.horizontalHeader().setSectionResizeMode(0,QHeaderView.ResizeMode.Stretch)
            table.setColumnWidth(1,85);table.setColumnWidth(2,120)
            table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
            for i,row in enumerate(sessions):
                for j,value in enumerate([row['title'],{'running':'运行中','done':'已结束','unknown':'最后记录','stopped':'已停止','error':'异常'}.get(row['state'],'最后记录'),compact(row.get('tokens'))]):
                    table.setItem(i,j,QTableWidgetItem(value))
            tabs.addTab(table,label)
        layout.addWidget(tabs)
        layout.addWidget(QLabel('各会话累计值；父子会话不相加，不冒充今日或账户总消耗。'))


class Application:
    def __init__(self,app):
        self.app=app
        DATA.mkdir(parents=True,exist_ok=True)
        self.settings=load({})
        self.config=DATA/'windows-settings.json'
        try:
            saved=json.loads(self.config.read_text(encoding='utf-8'))
            self.settings=load(saved)
        except (OSError,ValueError):pass
        self.windows={}
        self.data={}
        self.dialogs=[]
        self.settings_window=None
        self.bridge=Bridge()
        self.bridge.snapshot.connect(self.update)
        self.tray=QSystemTrayIcon(self.tray_icon(),app)
        self.tray.setToolTip('Agent HUD · 等待已打开的客户端')
        self.tray_menu=self.menu()
        self.tray.setContextMenu(self.tray_menu)
        self.tray.activated.connect(self.tray_click)
        self.tray.show()
        self.monitor=Monitor(self.bridge.snapshot.emit)
        self.monitor.enabled=set(self.settings['enabled_clients'])
        self.tray.setVisible(self.settings['show_tray'])
        threading.Thread(target=self.monitor.run,daemon=True).start()
        app.aboutToQuit.connect(self.monitor.stop.set)
        app.screenAdded.connect(lambda _:self.update(self.data))
        app.screenRemoved.connect(lambda _:self.update(self.data))

    def tray_icon(self):
        pixmap=QPixmap(32,32);pixmap.fill(Qt.GlobalColor.transparent)
        p=QPainter(pixmap);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(QColor('#f5f5f7'));p.setBrush(QColor('#151515'))
        p.drawRoundedRect(2,5,28,22,10,10)
        p.setPen(QColor('#3ddc84'));p.drawEllipse(9,10,12,12);p.end()
        return QIcon(pixmap)

    def menu(self):
        menu=QMenu()
        menu.setStyleSheet('QMenu{background:#282828;color:#f5f5f7;border:1px solid #484848;border-radius:8px;padding:6px} '
                           'QMenu::item{padding:7px 22px} QMenu::item:selected{background:#454545;border-radius:4px}')
        menu.addAction('设置…',self.show_settings)
        glass=menu.addAction('磨砂背景');glass.setCheckable(True);glass.setChecked(self.settings['glass'])
        glass.toggled.connect(self.set_glass)
        sizes=menu.addMenu('HUD 大小')
        for size in (22,28,36,44,60):
            action=sizes.addAction(f'{size} pt'+(' · 原版默认' if size==22 else ''))
            action.setCheckable(True);action.setChecked(self.settings['size']==size)
            action.triggered.connect(lambda _,n=size:self.set_size(n))
        menu.addSeparator()
        info=menu.addAction('仅显示正在运行的 Codex / Cursor');info.setEnabled(False)
        menu.addAction('退出 Agent HUD',self.app.quit)
        return menu

    def context_menu(self,point):
        self.menu().exec(point)

    def save(self):
        self.config.write_text(json.dumps(self.settings,indent=2),encoding='utf-8')
        self.tray_menu=self.menu()
        self.tray.setContextMenu(self.tray_menu)

    def set_glass(self,value):
        self.apply_setting('glass',value)

    def set_size(self,value):
        self.apply_setting('size',value)

    def show_settings(self):
        if self.settings_window is None:self.settings_window=SettingsWindow(self)
        self.settings_window.show();self.settings_window.raise_();self.settings_window.activateWindow()

    def refresh_now(self):
        with self.monitor.lock:self.monitor.last_query.clear()

    def apply_setting(self,key,value,screen=None):
        value=validate(key,value)
        if screen is None:
            if key=='client_hooks':
                from install_hooks import configure
                configure(Path.home()/'.cursor/hooks.json',remove=not value)
            elif key=='launch_at_login':
                import shutil
                startup=Path(os.environ['APPDATA'])/'Microsoft/Windows/Start Menu/Programs/Startup/Agent HUD Open.lnk'
                if value:
                    import winreg
                    with winreg.OpenKey(winreg.HKEY_CURRENT_USER,r'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') as reg:
                        desktop=Path(os.path.expandvars(winreg.QueryValueEx(reg,'Desktop')[0]))
                    source=desktop/'Agent HUD Open.lnk'
                    if not source.exists():raise RuntimeError('请先运行 Windows 安装脚本以创建快捷方式。')
                    startup.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,startup)
                elif startup.exists():startup.unlink()
            self.settings[key]=value
        else:self.settings['placements'].setdefault(screen,{})[key]=value
        self.monitor.enabled=set(self.settings['enabled_clients'])
        self.tray.setVisible(self.settings['show_tray'])
        self.save();self.update(self.data)
        for meter in self.windows.values():meter.apply_material()

    def screen_settings(self,name):
        return {**self.settings,**self.settings.get('placements',{}).get(name,{})}

    def dragged(self,meter,point):
        screen=meter.screen.geometry()
        horizontal=meter.settings['edge'] in ('top','bottom')
        peers=[m for (name,_),m in self.windows.items() if name==meter.screen.name()]
        cfg=meter.settings
        gap=round(cfg['size']*cfg['gap']) if cfg['mode']=='simple' else round(cfg['logo_size']*cfg['logo_gap'])
        runs=[m.width() if horizontal else m.height() for m in peers]
        index=peers.index(meter);run=sum(runs)+max(0,len(runs)-1)*gap
        grabbed=sum(runs[:index])+index*gap+runs[index]*getattr(meter,'grab_fraction',.5)
        extent=(run,max(m.height() for m in peers)) if horizontal else (max(m.width() for m in peers),run)
        position=nearest_placement(point.x(),point.y(),(screen.x(),screen.y(),screen.width(),screen.height()),extent,meter.settings['edge'],grabbed/max(1,run))
        if meter.settings.get('mode')=='notch':position['mode']='logos'
        self.settings.setdefault('placements',{}).setdefault(meter.screen.name(),{}).update(position)
        self.save();self.update(self.data)

    def show_usage(self,client,data):
        window=UsageWindow(client,data)
        self.dialogs.append(window)
        window.finished.connect(lambda _: self.dialogs.remove(window) if window in self.dialogs else None)
        window.show()

    def update(self,snapshot):
        snapshot={k:v for k,v in snapshot.items() if k in self.settings['enabled_clients']}
        self.data=snapshot
        groups={}
        for screen in self.app.screens():
            cfg=self.screen_settings(screen.name())
            groups[screen.name()]=[[c] for c in snapshot] if cfg['separates_agents'] and cfg['mode']!='notch' else [list(snapshot)] if snapshot else []
        wanted={(screen,clients[0] if len(clients)==1 else 'group') for screen,sets in groups.items() for clients in sets}
        for key in list(self.windows):
            if key not in wanted:
                meter=self.windows.pop(key);meter.hide_all();meter.glow.deleteLater();meter.panel.deleteLater();meter.deleteLater()
        for screen in self.app.screens():
            meters=[]
            for clients in groups[screen.name()]:
                client=clients[0]
                key=(screen.name(),client if len(clients)==1 else 'group')
                if key not in self.windows:
                    meter=SimpleMeterView(client,screen,self.screen_settings(screen.name()),self.context_menu)
                    meter.usage_callback=self.show_usage
                    meter.settings_callback=self.show_settings
                    meter.placement_callback=self.dragged
                    self.windows[key]=meter
                meter=self.windows[key]
                meter.settings=self.screen_settings(screen.name())
                meter.set_group_data({c:snapshot[c] for c in clients});meters.append(meter)
            cfg=self.screen_settings(screen.name())
            edge=cfg['edge'] if cfg['mode']!='notch' else 'top';horizontal=edge in ('top','bottom')
            gap=round(cfg['size']*cfg['gap']) if cfg['mode']=='simple' else round(cfg['logo_size']*cfg['logo_gap'])
            width=sum(m.width() for m in meters)+max(0,len(meters)-1)*gap if horizontal else max([m.width() for m in meters] or [0])
            height=max([m.height() for m in meters] or [0]) if horizontal else sum(m.height() for m in meters)+max(0,len(meters)-1)*gap
            rect=screen.geometry()
            x,y=group_origin((rect.x(),rect.y(),rect.width(),rect.height()),(width,height),edge,cfg['offset'] if cfg['mode']!='notch' else .5,3 if cfg['mode']=='simple' else 0)
            for meter in meters:
                if not meter.dragging:meter.place(x,y)
                if not meter.isVisible():meter.show();meter.apply_material()
                meter.glow.sync()
                if horizontal:x+=meter.width()+gap
                else:y+=meter.height()+gap
        self.tray.setToolTip('Agent HUD · '+(' / '.join(snapshot) if snapshot else '未打开 Codex / Cursor'))
        if self.settings_window is not None:
            for client,label in self.settings_window.status_labels.items():label.setText('运行中' if client in snapshot else '未运行')
        # Health metadata only; useful for checking hidden/background operation.
        status=dict(running=sorted(snapshot),mode=self.settings['mode'],separates_agents=self.settings['separates_agents'],
                    windows=[dict(agent=m.client,screen=key[0],glass=m.native_glass,visible=m.isVisible())
                             for key,m in self.windows.items()])
        temporary=DATA/'windows-status.tmp'
        temporary.write_text(json.dumps(status,ensure_ascii=False),encoding='utf-8')
        temporary.replace(DATA/'windows-status.json')

    def tray_click(self,reason):
        if reason==QSystemTrayIcon.ActivationReason.Trigger:
            for meter in self.windows.values():
                meter.panel.pinned=True;meter.open_panel();break


def preview(app,directory):
    """Render the actual Qt views with explicit fixture data; never query clients."""
    directory.mkdir(parents=True,exist_ok=True)
    for index,client in enumerate(('Codex','Cursor')):
        data=dict(quota=dict(windows=[dict(label='Weekly' if client=='Codex' else 'Included',used=40 if client=='Codex' else 72,reset=1792874445)]),
                  local=dict(sessions=[dict(id=str(i),title=name,state='running' if i==0 else 'done',tokens=total,
                                           breakdown=dict(input=total//6,cache=total//2,reasoning=total//6,output=total//6))
                                       for i,(name,total) in enumerate([('构建 Windows 兼容层',184200),('验证运行中的 Agent',73500),('同步上游界面与交互',42700)])]))
        meter=SimpleMeterView(client,app.primaryScreen(),dict(DEFAULTS),lambda _:None,preview=True)
        meter.set_data(data);meter.place(500+index*120,50);meter.show();app.processEvents()
        meter.grab().save(str(directory/(client.lower()+'-simple.png')))
        meter.panel.progress=1.;meter.panel.animate(1.);meter.panel.show();app.processEvents()
        meter.panel.grab().save(str(directory/(client.lower()+'-panel.png')))
        for mode in ('logos','notch'):
            meter.settings['mode']=mode;meter.refresh_size();meter.glow.sync();app.processEvents()
            meter.grab().save(str(directory/(client.lower()+'-'+mode+'.png')))
        meter.hide_all();meter.glow.close();meter.panel.close();meter.close()
    class PreviewManager:
        def __init__(self):self.app=app;self.settings=load({});self.data={}
        def screen_settings(self,name):return {**self.settings,**self.settings['placements'].get(name,{})}
        def apply_setting(self,key,value,screen=None):
            target=self.settings if screen is None else self.settings['placements'].setdefault(screen,{})
            target[key]=validate(key,value)
        def refresh_now(self):pass
    settings=SettingsWindow(PreviewManager());settings.show();app.processEvents()
    for index,name in enumerate(('general','agents','display','experimental')):
        settings.sidebar.setCurrentRow(index);app.processEvents();settings.grab().save(str(directory/('settings-'+name+'.png')))
    settings.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--preview-dir',type=Path)
    args=parser.parse_args()
    app=QApplication(sys.argv[:1])
    app.setStyle('Fusion')
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName('Agent HUD Open')
    if args.preview_dir:
        preview(app,args.preview_dir);return
    # Keep one resident UI, with no window at all until a watched client opens.
    from PySide6.QtNetwork import QLocalServer, QLocalSocket
    socket=QLocalSocket();socket.connectToServer('agent-hud-open-windows-v2')
    if socket.waitForConnected(200):
        socket.write(b'settings');socket.flush();socket.waitForBytesWritten(200);return
    QLocalServer.removeServer('agent-hud-open-windows-v2')
    server=QLocalServer();server.listen('agent-hud-open-windows-v2')
    manager=Application(app)
    def activate_existing():
        connection=server.nextPendingConnection()
        if connection:
            manager.show_settings();connection.disconnectFromServer();connection.deleteLater()
    server.newConnection.connect(activate_existing)
    app.exec()


if __name__=='__main__':main()
