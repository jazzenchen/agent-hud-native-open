"""Windows window/tray lifecycle for the source-derived Simple HUD."""
import argparse
import json
import os
from pathlib import Path
import sys
import threading
from copy import deepcopy

from PySide6.QtCore import QObject, Signal, Qt, QTimer
from PySide6.QtGui import QAction, QColor, QIcon, QPainter, QPixmap
from PySide6.QtWidgets import QApplication, QSystemTrayIcon, QMenu, QDialog, QVBoxLayout, QLabel, QTabWidget, QTableWidget, QTableWidgetItem, QHeaderView,QScrollArea,QWidget

from providers import DATA
from runtime import Monitor
from source_design import DESIGN
from views import SimpleMeterView, compact,reset_label
from placement import nearest_placement,group_origin
from preferences import DEFAULTS,load,validate
from settings_window import SettingsWindow
from theme import window_is_light,apply_widget_theme,menu_styles,tokens,native_titlebar


class Bridge(QObject):
    snapshot = Signal(dict)


class UsageWindow(QDialog):
    """The two original statistics tabs, scoped to available Windows records."""
    def __init__(self,client,data,light=False):
        super().__init__()
        self.client=client;self.usage_signature=None
        self.setWindowTitle(client+' · 用量统计')
        self.resize(900,740)
        self.apply_theme(light)
        layout=QVBoxLayout(self)
        tabs=QTabWidget()
        sessions=data.get('local',{}).get('sessions',[])
        stats=data.get('local',{}).get('stats',{})
        token_page=QDialog();token_layout=QVBoxLayout(token_page);token_layout.setContentsMargins(0,0,0,0)
        totals=stats.get('totals',{})
        self.summary=QLabel();token_layout.addWidget(self.summary)
        models=stats.get('models',[]);model_table=QTableWidget(len(models),7);model_table.setObjectName('tokenModels')
        model_table.setHorizontalHeaderLabels(['模型','输入','缓存读取','缓存写入','输出','推理','总量'])
        model_table.verticalHeader().hide();model_table.horizontalHeader().setSectionResizeMode(0,QHeaderView.ResizeMode.Stretch)
        model_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        for i,row in enumerate(models):
            for j,value in enumerate([row['model']]+[compact(row.get(k)) for k in ('fresh_input','cache','cache_write','visible_output','reasoning','total')]):model_table.setItem(i,j,QTableWidgetItem(value))
        for column in range(1,7):model_table.setColumnWidth(column,75)
        from stats_widgets import TokenDashboard
        token_content=QWidget();content_layout=QVBoxLayout(token_content);content_layout.setContentsMargins(6,0,6,0);content_layout.setSpacing(12)
        self.dashboard=TokenDashboard(client);content_layout.addWidget(self.dashboard)
        model_table.setMinimumHeight(170);model_table.setMaximumHeight(230);content_layout.addWidget(model_table)
        scroll=QScrollArea();scroll.setWidgetResizable(True);scroll.setFrameShape(QScrollArea.Shape.NoFrame);scroll.setWidget(token_content)
        token_layout.addWidget(scroll);tabs.addTab(token_page,'Tokens')
        for label in ('Sessions',):
            table=QTableWidget(len(sessions),3);table.setObjectName('usageSessions')
            table.setHorizontalHeaderLabels(['会话','状态','已索引 Tokens'])
            table.verticalHeader().hide()
            table.horizontalHeader().setSectionResizeMode(0,QHeaderView.ResizeMode.Stretch)
            table.setColumnWidth(1,85);table.setColumnWidth(2,120)
            table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
            for i,row in enumerate(sessions):
                for j,value in enumerate([row['title'],{'running':'运行中','done':'已结束','unknown':'最后记录','stopped':'已停止','error':'异常'}.get(row['state'],'最后记录'),compact(row.get('tokens'))]):
                    table.setItem(i,j,QTableWidgetItem(value))
            tabs.addTab(table,label)
        layout.addWidget(tabs)
        note=data.get('local',{}).get('notice') or '按请求去重；推理和缓存写入分列，不重复加入总量。'
        self.footer=QLabel(note);self.footer.setWordWrap(True);layout.addWidget(self.footer)
        self.sync(data)

    def sync(self,data):
        local=data.get('local',{});stats=local.get('stats',{});sessions=local.get('sessions',[])
        history=local.get('history_stats') or stats
        signature=repr((stats,history.get('event_count'),history.get('totals'),[(r.get('id'),r.get('tokens'),r.get('state'),r.get('title')) for r in sessions],local.get('notice'),data.get('quota',{}).get('account')))
        if signature==self.usage_signature:return
        self.usage_signature=signature
        from usage_display import account_label
        total=stats.get('totals',{}).get('total')
        scope=account_label(data.get('quota',{})) if stats.get('scope')=='account' else '本地用量，未推断历史账户归属'
        self.summary.setText(str(stats.get('event_count',0))+' 条用量记录 · '+scope)
        self.dashboard.set_data(local.get('history_stats') or stats)
        models=stats.get('models',[])
        values=[[r['model']]+[compact(r.get(k)) for k in ('fresh_input','cache','cache_write','visible_output','reasoning','total')] for r in models]
        session_values=[[r['title'],{'running':'运行中','done':'已结束','stopped':'已停止','error':'异常'}.get(r.get('state'),'最后记录'),compact(r.get('tokens'))] for r in sessions]
        for name,rows in [('tokenModels',values),('usageSessions',session_values)]:
            table=self.findChild(QTableWidget,name);offset=table.verticalScrollBar().value();table.setUpdatesEnabled(False)
            try:
                table.setRowCount(len(rows))
                for i,row in enumerate(rows):
                    for j,value in enumerate(row):table.setItem(i,j,QTableWidgetItem(value))
                table.verticalScrollBar().setValue(offset)
            finally:table.setUpdatesEnabled(True)
        self.footer.setText(local.get('notice') or '按请求去重；推理和缓存写入分列，不重复加入总量。')

    def apply_theme(self,light):
        apply_widget_theme(self,light);t=tokens(light)
        self.setStyleSheet(f"QWidget,QDialog,QTabWidget::pane{{background:{t['bg']};color:{t['ink']}}} "
            "QTabWidget::tab-bar{alignment:center} "
            f"QLabel,QTabBar::tab{{color:{t['ink']};padding:8px;font-family:'Microsoft YaHei UI'}} "
            f"QTabBar::tab{{background:{t['card']};border-radius:7px;margin:3px}} QTabBar::tab:selected{{background:{t['segment']}}} "
            f"QTableWidget{{background:{t['card']};color:{t['ink']};border:1px solid {t['border']};border-radius:10px;gridline-color:{t['divider']}}} "
            f"QScrollArea{{border:0}} QComboBox{{background:{t['card']};color:{t['ink']};padding:4px;border:1px solid {t['border']};border-radius:5px}} "
            f"QHeaderView::section{{background:{t['bg']};color:{t['muted']};border:0;padding:10px}}")

    def showEvent(self,event):
        super().showEvent(event);native_titlebar(self,bool(self.property('uiLight')))


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
        self.setup_layouts()
        self.windows={}
        self.data={}
        self.dialogs=[]
        self.settings_window=None
        from attention_ipc import AttentionServer
        self.attention=AttentionServer(app,enabled=lambda:self.settings.get('client_hooks',True),wait_minutes=lambda:self.settings.get('approval_wait_minutes',10),
            completion_enabled=lambda vendor:vendor not in self.settings.get('disabled_live_status_sources',[]),presentation=self.attention_presentation,news_enabled=self.attention_news_enabled)
        self.attention.changed.connect(self.refresh_attention)
        app.aboutToQuit.connect(self.attention.close)
        self.bridge=Bridge()
        self.bridge.snapshot.connect(self.update)
        self.tray=QSystemTrayIcon(self.tray_icon(),app)
        self.tray.setToolTip(DESIGN['app_name'])
        self.tray_menu=self.menu()
        self.tray.setContextMenu(self.tray_menu)
        self.tray.activated.connect(self.tray_click)
        self.tray.show()
        self.monitor=Monitor(self.bridge.snapshot.emit,copilot_consent=lambda:self.settings.get('read_copilot_quota',False))
        self.monitor.enabled=set(self.settings['enabled_clients'])
        self.tray.setVisible(self.settings['show_tray'])
        threading.Thread(target=self.monitor.run,daemon=True).start()
        app.aboutToQuit.connect(self.monitor.stop.set)
        app.screenAdded.connect(lambda _:self.update(self.data))
        app.screenRemoved.connect(lambda _:self.update(self.data))
        app.styleHints().colorSchemeChanged.connect(lambda _:self.refresh_themes())
        self.hook_setup_error=None
        if self.settings['client_hooks']:
            try:
                from attention_hooks import configure_all
                configure_all()
            except (OSError,ValueError):self.hook_setup_error='客户端回调配置失败，保留客户端原有询问。'

    def tray_icon(self):
        pixmap=QPixmap(32,32);pixmap.fill(Qt.GlobalColor.transparent)
        p=QPainter(pixmap);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(QColor('#f5f5f7'));p.setBrush(QColor('#151515'))
        p.drawRoundedRect(2,5,28,22,10,10)
        p.setPen(QColor('#3ddc84'));p.drawEllipse(9,10,12,12);p.end()
        return QIcon(pixmap)

    def menu(self):
        menu=QMenu()
        self.populate_menu(menu)
        menu.aboutToShow.connect(lambda:self.populate_menu(menu))
        return menu

    def populate_menu(self,menu):
        for previous in getattr(menu,'_agent_menus',[]):previous.deleteLater()
        menu.clear()
        menu._agent_menus=[]
        for client,data in self.data.items():
            agent=QMenu(client,menu);menu.addMenu(agent)
            menu._agent_menus.append(agent)
            rows=data.get('quota',{}).get('windows',[])
            from quota_state import quota_notice
            state=quota_notice(data.get('quota',{}),client)
            if state:agent.addAction(state).setEnabled(False)
            for row in rows:
                label=f"{row['label']}   {row['used']:.0f}%"
                if row.get('reset'):label+=' · '+reset_label(row['reset'])
                agent.addAction(label,lambda checked=False,c=client,d=data:self.show_usage(c,d))
            agent.addSeparator();agent.addAction('用量统计…',lambda checked=False,c=client,d=data:self.show_usage(c,d))
        if not self.data:menu.addAction('没有启用的模型').setEnabled(False)
        menu.addSeparator()
        menu.addAction('显示灵动岛光晕' if self.settings['glow_hidden'] else '隐藏灵动岛光晕',lambda:self.apply_setting('glow_hidden',not self.settings['glow_hidden']))
        menu.addSeparator();menu.addAction('设置…',self.show_settings)
        menu.addAction('刷新额度',self.refresh_now)
        menu.addAction('退出',self.app.quit)
        self.theme_menu(menu)

    def window_light(self,screen=None):
        screen=screen or self.app.primaryScreen()
        return window_is_light(self.settings,self.screen_settings(screen.name()))

    def theme_menu(self,menu):
        from PySide6.QtGui import QCursor
        screen=self.app.screenAt(QCursor.pos()) or self.app.primaryScreen()
        light=self.window_light(screen);apply_widget_theme(menu,light);menu.setStyleSheet(menu_styles(light))
        for action in menu.actions():
            if action.menu():apply_widget_theme(action.menu(),light);action.menu().setStyleSheet(menu_styles(light))

    def refresh_themes(self):
        if self.settings_window is not None:self.settings_window.apply_theme()
        for window in self.dialogs:window.apply_theme(self.window_light(window.screen()))
        self.theme_menu(self.tray_menu)
        for meter in self.windows.values():
            meter.apply_material();meter.update();meter.panel.update()

    def context_menu(self,point):
        self.menu().exec(point)

    def save(self):
        temporary=self.config.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.settings,indent=2),encoding='utf-8');temporary.replace(self.config)
        self.tray_menu=self.menu()
        self.tray.setContextMenu(self.tray_menu)

    def setup_layouts(self):
        from panel_layout import LayoutStore,migrate_settings
        saved=self.settings.get('layout_documents')
        self.layouts=LayoutStore(migrate_settings(self.settings) if saved is None else saved,self.persist_layouts)

    def persist_layouts(self,value):
        previous=deepcopy(self.settings)
        # {} is the saved default and the migration marker. None means an older
        # Windows profile whose scalar panel fields have not been carried yet.
        self.settings['layout_documents']=value or {}
        try:self.save()
        except OSError as error:
            self.settings=previous
            from quota_state import failure_code
            raise RuntimeError('磁盘空间不足，布局尚未保存。' if failure_code(error)=='disk_full' else '布局写入失败，已保留原配置和草稿。') from None

    def layout_changed(self):
        self.update(self.data)
        if getattr(self,'settings_window',None) is not None:self.settings_window.rebuild()

    def commit_settings(self,previous):
        try:self.save()
        except OSError as error:
            self.settings=previous
            if hasattr(self,'monitor'):self.monitor.enabled=set(previous['enabled_clients'])
            self.tray.setVisible(previous['show_tray'])
            self.update(self.data);self.refresh_themes()
            from quota_state import failure_code
            message='磁盘空间不足，设置尚未保存。' if failure_code(error)=='disk_full' else '设置无法写入，已恢复上次配置。'
            raise RuntimeError(message) from None

    def set_glass(self,value):
        self.apply_setting('glass',value)

    def set_size(self,value):
        self.apply_setting('size',value)

    def show_settings(self):
        if self.settings_window is None:self.settings_window=SettingsWindow(self)
        self.settings_window.showNormal()
        frame=self.settings_window.frameGeometry()
        if not any(frame.intersects(screen.availableGeometry()) for screen in self.app.screens()):
            available=self.app.primaryScreen().availableGeometry();frame.moveCenter(available.center());self.settings_window.move(frame.topLeft())
        self.settings_window.raise_();self.settings_window.activateWindow()

    def refresh_now(self):
        with self.monitor.lock:self.monitor.last_query.clear()

    def apply_setting(self,key,value,screen=None):
        value=validate(key,value)
        if hasattr(self,'layouts') and key in ('panel_quota','panel_tokens','panel_sessions','reset_countdown','panel_width','session_limit'):
            self.layouts.edit_field(key,value,screen)
            self.layout_changed();return
        previous=deepcopy(self.settings)
        if screen is None:
            if key=='client_hooks':
                from install_hooks import configure
                from attention_hooks import configure_all
                configure_all(remove=not value)
                if (Path.home()/'.cursor').exists():configure(Path.home()/'.cursor/hooks.json',remove=not value)
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
        else:
            if key in ('glass','transparency'):
                self.apply_screen_settings({key:value},screen);return
            self.settings['placements'].setdefault(screen,{})[key]=value
        self.monitor.enabled=set(self.settings['enabled_clients'])
        if key=='read_copilot_quota':
            with self.monitor.lock:
                self.monitor.epochs['GitHub Copilot']=self.monitor.epochs.get('GitHub Copilot',0)+1
                self.monitor.quotas.pop('GitHub Copilot',None)
                self.monitor.last_query.pop('GitHub Copilot',None)
        self.tray.setVisible(self.settings['show_tray'])
        self.commit_settings(previous);self.update(self.data)
        if hasattr(self,'attention'):
            if key=='client_hooks' and not value:self.attention.disable()
            if key=='approval_wait_minutes':self.attention.refresh_wait()
            if key=='disabled_live_status_sources':
                for identifier,event in tuple(self.attention.pending.items()):
                    if event['kind']=='completion' and event['vendor'] in value:self.attention.resolve(identifier,'dismiss')
        for meter in self.windows.values():meter.apply_material()
        self.refresh_themes()

    def screen_settings(self,name):
        settings={**self.settings,**self.settings.get('placements',{}).get(name,{})}
        if hasattr(self,'layouts'):
            from panel_layout import effective_settings
            settings=effective_settings(settings,self.layouts.effective(name))
        return settings

    def saved_screen_settings(self,name):
        settings={**self.settings,**self.settings.get('placements',{}).get(name,{})}
        if hasattr(self,'layouts'):
            from panel_layout import effective_settings
            own=self.layouts.own(name);settings=effective_settings(settings,self.layouts.current if own is None else own)
        return settings

    def apply_screen_settings(self,values,screen,remember=False):
        validated={key:validate(key,value) for key,value in values.items()}
        previous=deepcopy(self.settings)
        fields=self.settings['placements'].setdefault(screen,{})
        if remember:self.remember_screen(screen)
        cfg=self.screen_settings(screen)
        if 'glass' in validated and 'transparency' not in validated:
            validated['transparency']=cfg['glass_transparency' if validated['glass'] else 'solid_transparency']
        if 'transparency' in validated:
            validated['glass_transparency' if validated.get('glass',cfg['glass']) else 'solid_transparency']=validated['transparency']
        fields.update(validated)
        self.commit_settings(previous);self.update(self.data);self.refresh_themes()

    def remember_screen(self,screen):
        versions=self.settings.setdefault('screen_versions',{}).setdefault(screen,[])
        versions.append(deepcopy(self.settings['placements'].get(screen,{})));del versions[:-8]

    def change_screen_layout(self,screen,action):
        if hasattr(self,'layouts') and (action!='revert' or self.layouts.can_revert(screen)):
            if action=='shared':self.layouts.use_shared(screen)
            elif action=='reset':self.layouts.reset(screen)
            elif action=='revert':self.layouts.revert(screen)
            else:raise ValueError('Unknown layout action')
            self.layout_changed();return
        previous=deepcopy(self.settings)
        if action=='revert':
            versions=self.settings.setdefault('screen_versions',{}).get(screen,[])
            if not versions:return
            self.settings['placements'][screen]=versions.pop()
        else:
            self.remember_screen(screen);fields=self.settings['placements'].setdefault(screen,{})
            for key in ('panel_quota','panel_tokens','panel_sessions','panel_width','session_limit','reset_countdown'):
                if action=='shared':fields.pop(key,None)
                elif action=='reset':fields[key]=DEFAULTS[key]
        self.commit_settings(previous);self.update(self.data);self.refresh_themes()

    def change_shared_layout(self,action):
        if not hasattr(self,'layouts'):return
        if action=='revert':self.layouts.revert()
        elif action=='reset':self.layouts.reset()
        else:raise ValueError('Unknown shared layout action')
        self.layout_changed()

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
        window=UsageWindow(client,data,self.window_light())
        self.dialogs.append(window)
        window.finished.connect(lambda _: self.dialogs.remove(window) if window in self.dialogs else None)
        window.show()
        if window.windowHandle():window.windowHandle().screenChanged.connect(lambda screen:window.apply_theme(self.window_light(screen)))

    def update(self,snapshot):
        snapshot={k:v for k,v in snapshot.items() if k in self.settings['enabled_clients']}
        snapshot={name:snapshot[name] for name in self.settings.get('provider_order',list(snapshot)) if name in snapshot}
        self.data=snapshot
        if hasattr(self,'attention'):self.attention.observe(snapshot)
        for dialog in self.dialogs:
            if isinstance(dialog,UsageWindow) and dialog.client in snapshot:dialog.sync(snapshot[dialog.client])
        groups={}
        for screen in self.app.screens():
            cfg=self.screen_settings(screen.name())
            groups[screen.name()]=[list(snapshot)] if snapshot else []
        wanted={(screen,clients[0] if len(clients)==1 else 'group') for screen,sets in groups.items() for clients in sets}
        for key in list(self.windows):
            if key not in wanted:
                meter=self.windows.pop(key);meter.hide_all();meter.glow.deleteLater();meter.peek.deleteLater();meter.panel.deleteLater();meter.deleteLater()
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
                if hasattr(self,'layouts'):
                    meter.layout_store=self.layouts;meter.layout_changed_callback=self.layout_changed
                meter.settings=self.screen_settings(screen.name())
                from usage_display import visible_quota
                visible={c:{**snapshot[c],'quota':visible_quota(snapshot[c].get('quota',{}),c,self.settings)} for c in clients}
                for vendor in self.settings.get('disabled_live_status_sources',[]):
                    if vendor in visible:visible[vendor]={**visible[vendor],'local':{**visible[vendor].get('local',{}),'sessions':[]}}
                meter.set_group_data(visible);meters.append(meter)
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
        self.refresh_attention()
        self.tray.setToolTip(DESIGN['app_name']+' · '+(' / '.join(snapshot) if snapshot else '暂无运行中的智能体'))
        if self.settings_window is not None:
            for client,label in self.settings_window.status_labels.items():label.setText('已停用' if client not in self.settings['enabled_clients'] else '运行中' if client in snapshot else '未运行')
        signature=(self.window_light(),tuple((key,m.light()) for key,m in self.windows.items()))
        if signature!=getattr(self,'_theme_signature',None):
            self._theme_signature=signature;self.refresh_themes()
        # Health metadata only; useful for checking hidden/background operation.
        status=dict(qt_platform=self.app.platformName(),running=sorted(snapshot),mode=self.settings['mode'],separates_agents=self.settings['separates_agents'],
                    layout_documents_active=hasattr(self,'layouts'),layout_revision=self.layouts.revision if hasattr(self,'layouts') else None,
                    layout_draft_screens=sum(self.layouts.has_draft(screen.name()) for screen in self.app.screens()) if hasattr(self,'layouts') else 0,
                    attention_pending=len(self.attention.pending) if hasattr(self,'attention') else 0,
                    quota={client:dict(state='stale' if data.get('quota',{}).get('stale') else 'available' if data.get('quota',{}).get('windows') else 'unavailable' if data.get('quota',{}).get('error_code') else 'no_percentage' if data.get('quota',{}).get('at') else 'loading',
                        error_code=data.get('quota',{}).get('error_code'),last_success_at=data.get('quota',{}).get('at'),
                        retry_seconds=data.get('quota',{}).get('retry_seconds')) for client,data in snapshot.items()},
                    usage={client:dict(account_identified=(data.get('quota',{}).get('account') or {}).get('evidence')=='account',indexed_records=data.get('local',{}).get('stats',{}).get('event_count'),
                        plan_present=bool(data.get('quota',{}).get('plan')),credit_balance_read=bool(data.get('quota',{}).get('credit_balance')),
                        quota_measures={measure:any((row.get('metrics') or {}).get(measure) is not None for row in data.get('quota',{}).get('windows',[])) for measure in ('consumed','reply','cost')},
                        indexing=bool(data.get('local',{}).get('indexing')),models=len(data.get('local',{}).get('stats',{}).get('models',[]))) for client,data in snapshot.items()},
                    settings_visible=self.settings_window.isVisible() if self.settings_window else False,
                    window_appearance='light' if self.window_light() else 'dark',
                    windows=[dict(agent=m.client,screen=key[0],glass=m.native_glass or m.frost.image is not None,
                                  backdrop='sampled' if m.frost.image is not None else 'native' if m.native_glass else 'stand_in',
                                  visible=m.isVisible(),mode=m.settings['mode'],
                                  appearance='light' if m.light() else 'dark',edge=m.settings['edge'],offset=m.settings['offset'])
                             for key,m in self.windows.items()])
        temporary=DATA/'windows-status.tmp'
        try:
            temporary.write_text(json.dumps(status,ensure_ascii=False),encoding='utf-8')
            temporary.replace(DATA/'windows-status.json')
            self.health_write_error=None
        except OSError as error:
            from quota_state import failure_code
            self.health_write_error=failure_code(error)

    def attention_news_enabled(self,event):
        if event.get('account') in self.settings.get('hidden_accounts',[]):return False
        if event['vendor'] not in self.data:return False
        if event['kind']=='quota':
            from usage_display import visible_quota,window_key
            quota=visible_quota(self.data[event['vendor']].get('quota',{}),event['vendor'],self.settings)
            return any(window_key(row)==event['window'] for row in quota.get('windows',[]))
        return True

    def attention_presentation(self):
        from PySide6.QtGui import QCursor
        point=QCursor.pos();displayed=set();held=set()
        for meter in self.windows.values():
            event=meter.attention_event()
            if not meter.isVisible() or event is None:continue
            displayed.add(event['id'])
            for widget in (meter,meter.peek,meter.panel):
                if not widget.isVisible():continue
                local=widget.mapFromGlobal(point);mask=widget.mask()
                if widget.rect().contains(local) and (mask.isEmpty() or mask.contains(local)):
                    held.add(event['id']);break
        return displayed,held

    def refresh_attention(self):
        if not hasattr(self,'attention'):return
        from session_navigation import can_navigate,navigate
        for meter in self.windows.values():
            meter.attention_callback=self.attention.resolve
            meter.attention_can_navigate=can_navigate
            meter.attention_navigate=navigate
            disabled=set(self.settings.get('disabled_live_status_sources',[]))
            events=[row for row in self.attention.pending.values() if row['vendor'] in meter.group_data and (row['kind']!='completion' or row['vendor'] not in disabled)]
            from usage_display import window_key
            events=[row for row in events if row['kind'] not in ('quota','reset_credits') or row.get('account') not in self.settings.get('hidden_accounts',[])]
            events=[row for row in events if row['kind']!='quota' or row['window'] in {window_key(window) for window in meter.group_data[row['vendor']].get('quota',{}).get('windows',[])}]
            meter.set_attention(events)

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
                                       for i,(name,total) in enumerate([('构建项目',184200),('检查变更',73500),('运行测试',42700)])]))
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
        preview=True
        def __init__(self):
            self.app=app;self.settings=load({})
            self.data={'Codex':dict(quota=dict(windows=[dict(label='Weekly',used=49)]),local=dict(sessions=[]))}
        def screen_settings(self,name):return {**self.settings,**self.settings['placements'].get(name,{})}
        def apply_setting(self,key,value,screen=None):
            target=self.settings if screen is None else self.settings['placements'].setdefault(screen,{})
            target[key]=validate(key,value)
        def refresh_now(self):pass
    settings=SettingsWindow(PreviewManager());settings.show();app.processEvents()
    for index,name in enumerate(('general','agents','display','experimental')):
        settings.sidebar.setCurrentRow(index);settings.transition.animation.stop();settings.transition.effect.setOpacity(1.)
        app.processEvents();settings.grab().save(str(directory/('settings-'+name+'.png')))
    for scheme in ('light','dark'):
        settings.manager.settings['appearance']=scheme;settings.rebuild();app.processEvents()
        for index,name in enumerate(('general','agents','display','experimental')):
            settings.sidebar.setCurrentRow(index);settings.transition.animation.stop();settings.transition.effect.setOpacity(1.)
            app.processEvents();settings.grab().save(str(directory/('settings-'+name+'-'+scheme+'.png')))
        meter=SimpleMeterView('Codex',app.primaryScreen(),{**load({}),'hud_appearance':scheme},lambda _:None,preview=True)
        meter.set_data(data);meter.show();meter.panel.animation.jump(1.);meter.panel.show();app.processEvents()
        meter.grab().save(str(directory/('meter-'+scheme+'.png')))
        meter.panel.grab().save(str(directory/('panel-'+scheme+'.png')))
        meter.hide_all();meter.glow.close();meter.panel.close();meter.close()
    settings.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--preview-dir',type=Path)
    args=parser.parse_args()
    app=QApplication(sys.argv[:1])
    app.setStyle('Fusion')
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName('Agent HUD Open')
    app.setWindowIcon(QIcon(str(DESIGN['app_icon'])))
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
