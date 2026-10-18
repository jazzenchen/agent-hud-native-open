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


DEFAULTS = dict(mode='simple', glass=True, separates_agents=True,
                size=DESIGN['simple_size'], ring_width=DESIGN['ring_width'])


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
        self.settings=dict(DEFAULTS)
        self.config=DATA/'windows-settings.json'
        try:
            saved=json.loads(self.config.read_text(encoding='utf-8'))
            for key in ('glass','size'):
                if key in saved:self.settings[key]=saved[key]
        except (OSError,ValueError):pass
        self.windows={}
        self.data={}
        self.dialogs=[]
        self.bridge=Bridge()
        self.bridge.snapshot.connect(self.update)
        self.tray=QSystemTrayIcon(self.tray_icon(),app)
        self.tray.setToolTip('Agent HUD · 等待已打开的客户端')
        self.tray_menu=self.menu()
        self.tray.setContextMenu(self.tray_menu)
        self.tray.activated.connect(self.tray_click)
        self.tray.show()
        self.monitor=Monitor(self.bridge.snapshot.emit)
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
        mode=menu.addAction('简约模式 · 按 Agent 分开');mode.setEnabled(False)
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
        self.settings['glass']=value;self.save()
        for meter in self.windows.values():
            meter.apply_material()
            meter.panel.hide();meter.panel.pinned=False

    def set_size(self,value):
        self.settings['size']=value;self.save();self.update(self.data)

    def show_usage(self,client,data):
        window=UsageWindow(client,data)
        self.dialogs.append(window)
        window.finished.connect(lambda _: self.dialogs.remove(window) if window in self.dialogs else None)
        window.show()

    def update(self,snapshot):
        self.data=snapshot
        wanted={(screen.name(),client) for screen in self.app.screens() for client in snapshot}
        for key in list(self.windows):
            if key not in wanted:
                meter=self.windows.pop(key);meter.hide_all();meter.panel.deleteLater();meter.deleteLater()
        for screen in self.app.screens():
            meters=[]
            for client in ('Codex','Cursor'):
                if client not in snapshot:continue
                key=(screen.name(),client)
                if key not in self.windows:
                    meter=SimpleMeterView(client,screen,self.settings,self.context_menu)
                    meter.usage_callback=self.show_usage
                    self.windows[key]=meter
                meter=self.windows[key]
                meter.set_data(snapshot[client]);meters.append(meter)
            gap=round(self.settings['size']*.45)
            width=sum(m.width() for m in meters)+max(0,len(meters)-1)*gap
            x=screen.geometry().center().x()-width/2
            y=screen.geometry().top()+DESIGN['edge_margin']
            for meter in meters:
                meter.place(x,y)
                if not meter.isVisible():meter.show();meter.apply_material()
                x+=meter.width()+gap
        self.tray.setToolTip('Agent HUD · '+(' / '.join(snapshot) if snapshot else '未打开 Codex / Cursor'))
        # Health metadata only; useful for checking hidden/background operation.
        status=dict(running=sorted(snapshot),mode='simple',separates_agents=True,
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
        meter.hide_all();meter.panel.close();meter.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--preview-dir',type=Path)
    args=parser.parse_args()
    app=QApplication(sys.argv[:1])
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName('Agent HUD Open')
    if args.preview_dir:
        preview(app,args.preview_dir);return
    # Keep one resident UI, with no window at all until a watched client opens.
    from PySide6.QtNetwork import QLocalServer, QLocalSocket
    socket=QLocalSocket();socket.connectToServer('agent-hud-open-windows-v2')
    if socket.waitForConnected(200):return
    QLocalServer.removeServer('agent-hud-open-windows-v2')
    server=QLocalServer();server.listen('agent-hud-open-windows-v2')
    manager=Application(app)
    app.exec()


if __name__=='__main__':main()
