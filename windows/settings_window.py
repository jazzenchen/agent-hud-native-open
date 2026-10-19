"""SettingsView / GeneralPane / SourcesPane / ScreensPane / IslandPane on Windows."""
from PySide6.QtCore import Qt,QTimer,QSize
from PySide6.QtWidgets import (QDialog,QHBoxLayout,QVBoxLayout,QListWidget,QStackedWidget,
    QWidget,QScrollArea,QLabel,QComboBox,QCheckBox,QPushButton,QMessageBox,QListWidgetItem,QFrame,QSizePolicy)
from settings_controls import Switch,Segmented,SliderValue,SettingRows,sidebar_icon,PageTransition,CardSurface,SidebarDelegate,HudSample
from preferences import DEFAULTS
from theme import window_is_light,tokens,apply_widget_theme,native_titlebar
from source_design import DESIGN
from PySide6.QtGui import QIcon


EN={'通用':'General','智能体':'Agents','显示':'Display','实验选项':'Experimental','外观与语言':'Appearance & language',
    '外观':'Appearance','跟随系统':'System','深色':'Dark','浅色':'Light','语言':'Language','启动':'Startup',
    '登录时启动':'Launch at login','客户端':'Clients','客户端回调':'Client hooks','跟随所在屏幕':'Match screen',
    '显示器':'Display','屏幕':'Screens','HUD 形态':'HUD','刘海':'Notch','简约':'Simple','动态':'Dynamic',
    '位置':'Position','顶部':'Top','右侧':'Right','底部':'Bottom','左侧':'Left','沿边位置':'Edge position',
    '重置位置':'Reset position','按 agent 分开':'Separate agents','HUD 外观':'HUD appearance','材质':'Material',
    '实色':'Solid','磨砂':'Material','透明度':'Transparency','大小':'Size','Logo 大小':'Logo size','Logo 间距':'Logo spacing',
    'Logo 离屏幕边缘':'Logo edge distance','显示 Logo':'Show logos','显示圆环':'Show rings','圆环粗细':'Ring thickness',
    '显示数字':'Show numbers','展开面板':'Expanded panel','会话列表':'Session list','额度明细':'Quota details',
    '重置倒计时':'Reset countdown','Token 消耗':'Token usage','面板宽度':'Panel width','会话上限':'Session limit',
    '悬停交互':'Hover behavior','按 Alt 才展开':'Press Alt to open','鼠标触顶立即展开':'Open immediately at top edge',
    '展开延迟':'Hover delay','收起延迟':'Collapse delay','菜单栏':'Tray','显示托盘图标':'Show tray icon',
    '背景光晕':'Backdrop glow','光晕样式':'Glow style','柔光':'Soft','点阵':'Dots','字符':'ASCII','色块':'Blocks','盲文':'Braille','二进制':'Binary',
    '动效':'Effect','呼吸':'Breathe','流光':'Flow','扫描':'Scan','涟漪':'Ripple','闪烁':'Shimmer','启动':'Boot',
    '光晕亮度':'Brightness','光晕范围':'Glow range','羽化':'Feather','仅向外扩散':'Outward only',
    '工作时周期':'Working period','空闲时周期':'Idle period','呼吸幅度':'Breath depth','点距':'Grid pitch',
    '密度':'Density','实心':'Solid rows','渐隐':'Fade rows','关闭':'Close'}


class SettingsWindow(QDialog):
    def __init__(self,manager):
        super().__init__()
        self.manager=manager
        self.setWindowTitle(DESIGN['app_name']+' 设置')
        self.setWindowIcon(QIcon(str(DESIGN['app_icon'])))
        self.resize(960,720);self.setMinimumSize(880,560)
        self.selected_screen=manager.app.primaryScreen().name()
        self.root=QHBoxLayout(self);self.root.setContentsMargins(0,0,0,0);self.root.setSpacing(0)
        shell=QWidget();shell.setObjectName('sidebarShell');shell.setFixedWidth(212)
        navigation=QVBoxLayout(shell);navigation.setContentsMargins(10,0,10,12);navigation.setSpacing(4)
        navigation.addSpacing(44)
        preferences=QLabel('偏好设置');preferences.setProperty('subtitle',True);preferences.setContentsMargins(12,0,0,8);navigation.addWidget(preferences)
        self.sidebar=QListWidget();self.sidebar.setIconSize(QSize(26,26));self.sidebar.setSpacing(0)
        self.sidebar.setItemDelegate(SidebarDelegate(self.sidebar))
        self.sidebar.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        navigation.addWidget(self.sidebar,1)
        identity=QWidget();identity.setObjectName('appIdentity');identity_layout=QHBoxLayout(identity);identity_layout.setContentsMargins(10,0,0,0);identity_layout.setSpacing(10)
        icon=QLabel();icon.setPixmap(QIcon(str(DESIGN['app_icon'])).pixmap(32,32));identity_layout.addWidget(icon)
        labels=QVBoxLayout();labels.setSpacing(3)
        brand=QLabel(DESIGN['app_name']);brand.setObjectName('brand');labels.addWidget(brand)
        version=QLabel(DESIGN['app_version']);version.setProperty('subtitle',True);labels.addWidget(version)
        identity_layout.addLayout(labels,1);navigation.addWidget(identity)
        self.stack=QStackedWidget()
        self.root.addWidget(shell);self.root.addWidget(self.stack,1)
        self.transition=PageTransition(self.stack)
        self.sidebar.currentRowChanged.connect(self.navigate)
        self.rebuild()

    def navigate(self,index):
        if index<0:return
        self.stack.setCurrentIndex(index);self.transition.run()

    def tr(self,value):
        return EN.get(value,value) if self.manager.settings['language']=='en' else value

    def rebuild(self):
        self.status_labels={}
        self.hud_preview=None
        if self.selected_screen not in [screen.name() for screen in self.manager.app.screens()]:self.selected_screen=self.manager.app.primaryScreen().name()
        previous=self.sidebar.currentRow() if self.sidebar.currentRow()>=0 else 2
        offsets={i:self.stack.widget(i).findChild(QScrollArea).verticalScrollBar().value() for i in range(self.stack.count())}
        self.sidebar.blockSignals(True);self.sidebar.clear()
        while self.stack.count():
            widget=self.stack.widget(0);self.stack.removeWidget(widget);widget.deleteLater()
        for name,icon,tint in [('通用','general','#8e8e93'),('智能体','agents','#30b0c7'),('显示','display','#7c65e8'),('实验选项','experimental','#ff9500')]:
            item=QListWidgetItem(sidebar_icon(icon,tint),self.tr(name));item.setSizeHint(QSize(192,48));self.sidebar.addItem(item)
        for method in (self.general,self.sources,self.display,self.experimental):
            page=QWidget();page.setObjectName('settingsPage');outer=QVBoxLayout(page);outer.setContentsMargins(0,0,0,0);outer.setSpacing(0)
            header=QWidget();header.setObjectName('pageHeader');self._header_layout=QVBoxLayout(header);self._header_layout.setContentsMargins(20,24,20,16);self._header_layout.setSpacing(7)
            outer.addWidget(header)
            content=QWidget();content.setObjectName('settingsContent');content.setMaximumWidth(16777215 if method==self.sources else 640)
            layout=QVBoxLayout(content);layout.setContentsMargins(0,0,0,0);layout.setSpacing(28)
            method(layout)
            if method!=self.sources:layout.addStretch()
            viewport=QWidget();viewport.setObjectName('pageViewport');center=QHBoxLayout(viewport);center.setContentsMargins(20,2,20,20) if method==self.sources else center.setContentsMargins(28,2,28,32);center.addWidget(content,1)
            scroll=QScrollArea();scroll.setWidgetResizable(True);scroll.setWidget(viewport);scroll.setFrameShape(QScrollArea.Shape.NoFrame)
            outer.addWidget(scroll,1);self.stack.addWidget(page)
        self.sidebar.blockSignals(False);self.sidebar.setCurrentRow(previous);self.stack.setCurrentIndex(previous)
        for i,value in offsets.items():
            bar=self.stack.widget(i).findChild(QScrollArea).verticalScrollBar();QTimer.singleShot(0,lambda bar=bar,value=value:bar.setValue(value))
        self.apply_theme()

    def apply_theme(self):
        name=self.screen().name() if self.screen() else self.selected_screen
        light=window_is_light(self.manager.settings,self.manager.screen_settings(name))
        apply_widget_theme(self,light)
        t=tokens(light);bg,sidebar,card,ink,muted,border=[t[k] for k in ('bg','sidebar','card','ink','muted','border')]
        self.setStyleSheet(f'QWidget{{color:{ink};font-family:"Microsoft YaHei UI";font-size:13px}} '
            f'QDialog,#settingsPage,#pageViewport,#settingsContent,QScrollArea{{background:{bg}}} '
            f'#sidebarShell,QListWidget{{background:{sidebar};border:0}} #sidebarShell{{border-right:1px solid {border}}} '
            f'#providerList{{background:{card};border:1px solid {border};border-radius:10px;padding:4px}} '
            'QListWidget{outline:0} QListWidget::item{padding-left:8px;border-radius:9px} QListWidget::item:selected{background:#0a84ff;color:white} '
            f'QListWidget::item:hover:!selected{{background:{border}}} QLabel#brand{{font-size:12px;font-weight:600}} '
            f'#settingsCard{{background:{card};border:1px solid {border};border-radius:10px}} #rowDivider{{background:{border};border:0}} '
            'QLabel{background:transparent} QLabel[sectionTitle="true"]{font-size:15px;font-weight:600} '
            f'QLabel[subtitle="true"]{{color:{muted};font-size:11px}} '
            f'QComboBox,QDoubleSpinBox{{background:{sidebar};border:1px solid {border};border-radius:6px;padding:5px 9px;selection-background-color:#0a84ff}} '
            f'QComboBox{{font-size:11px;padding:1px 6px;padding-right:20px}} QComboBox::drop-down{{border:0;width:20px}} QComboBox QAbstractItemView{{background:{card};selection-background-color:#0a84ff;outline:0;padding:4px}} '
            f'QDoubleSpinBox::up-button,QDoubleSpinBox::down-button{{border:0;width:16px}} '
            f'QDoubleSpinBox[compactValue="true"]{{background:transparent;border:0;padding:0;color:{muted}}} '
            f'QPushButton{{background:{sidebar};border:1px solid {border};border-radius:6px;padding:6px 12px}} QPushButton:hover{{border-color:{muted}}} QPushButton:pressed{{background:{border}}} '
            f'QPushButton:disabled{{color:{t["tertiary"]};background:{bg};border-color:{border}}} QPushButton[smallAction="true"]{{font-size:11px;padding:2px 6px;border-radius:4px}} '
            f'QPushButton#segment{{background:transparent;border:0;padding:0;font-size:12px;min-height:0;border-radius:5px}} '
            f'QPushButton#segment:checked{{background:transparent;font-weight:400}} QPushButton#segment:hover:!checked{{background:{border}}} '
            f'QSlider::groove:horizontal{{height:4px;border-radius:2px;background:{border}}} QSlider::sub-page:horizontal{{background:#0a84ff;border-radius:2px}} '
            f'QSlider::handle:horizontal{{background:#ffffff;border:1px solid {border};width:7px;height:14px;margin:-6px 0;border-radius:3px}} '
            f'QScrollBar:vertical{{background:transparent;width:8px;margin:3px}} QScrollBar::handle:vertical{{background:{border};border-radius:3px;min-height:36px}} '
            'QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical{height:0} QScrollBar::add-page:vertical,QScrollBar::sub-page:vertical{background:transparent}')

    def showEvent(self,event):
        super().showEvent(event);self.apply_theme()
        if not getattr(self,'_screen_tracking',False) and self.windowHandle():
            self._screen_tracking=True;self.windowHandle().screenChanged.connect(lambda _:self.apply_theme())

    def title(self,layout,name,subtitle):
        label=QLabel(self.tr(name));label.setStyleSheet('font-size:24px;font-weight:600');self._header_layout.addWidget(label)
        small=QLabel(subtitle);small.setProperty('subtitle',True);small.setWordWrap(True);self._header_layout.addWidget(small)

    def group(self,layout,title,subtitle=None):
        section=QWidget();column=QVBoxLayout(section);column.setContentsMargins(0,0,0,0);column.setSpacing(12)
        heading_block=QWidget();heading_layout=QVBoxLayout(heading_block);heading_layout.setContentsMargins(0,0,0,0);heading_layout.setSpacing(5)
        heading=QLabel(self.tr(title));heading.setProperty('sectionTitle',True);heading_layout.addWidget(heading);column.addWidget(heading_block)
        if subtitle:
            note=QLabel(subtitle);note.setProperty('subtitle',True);note.setWordWrap(True);heading_layout.addWidget(note)
        card=CardSurface();column.addWidget(card)
        form=SettingRows(card,{'登录时启动':'登录后，自动开始监测用量。','按 agent 分开':'悬停某个标志只展开该 agent 的面板，不再展开全部 agent 的面板。','按 Alt 才展开':'指针经过时不展开，悬停后按 Alt 打开。',
            '跟随所在屏幕':'每个窗口和菜单栏采用所在屏幕的 HUD 外观，移到另一块屏幕时跟着变。HUD 外观在「显示」中单独设置，与这里的窗口外观独立。',
            '客户端回调':'显示会话的开始与完成状态，用量和额度读取不受影响。',
            '位置':'回到这块屏幕的顶部安全位置。','HUD 样式':'形态、位置、大小、外观和光晕一起回到默认；「恢复上一版」可以撤销。'})
        if title=='屏幕':form.subtitles['HUD 形态']={'simple':'贴着屏幕边缘的悬浮面板，没有背景光晕。','logos':'贴着屏幕边缘停靠，向屏幕内展开。','notch':'固定在屏幕顶部的刘海面板。'}[self.value('mode',True)]
        layout.addWidget(section);return form

    def value(self,key,screen=False):
        return (self.manager.screen_settings(self.selected_screen) if screen else self.manager.settings)[key]

    def write(self,key,value,screen=False,rebuild=False):
        try:self.manager.apply_setting(key,value,self.selected_screen if screen else None)
        except Exception as error:
            QMessageBox.warning(self,'Agent HUD',str(error));return
        if self.hud_preview is not None:self.hud_preview.refresh()
        if rebuild:QTimer.singleShot(0,self.rebuild)

    def check(self,form,label,key,screen=False,disabled=None):
        widget=Switch();widget.setChecked(bool(self.value(key,screen)))
        widget.setAccessibleName(self.tr(label))
        widget.toggled.connect(lambda value:self.write(key,value,screen))
        if disabled:widget.setEnabled(False);widget.setToolTip(disabled)
        widget.setObjectName(key);form.addRow(self.tr(label),widget);return widget

    def combo(self,form,label,key,options,screen=False,rebuild=False):
        if key in ('appearance','mode','edge','hud_appearance'):
            widget=Segmented([(value,self.tr(title)) for value,title in options])
        else:
            widget=QComboBox();widget.setFixedWidth(135)
            for value,title in options:widget.addItem(self.tr(title),value)
        widget.setCurrentIndex(max(0,widget.findData(self.value(key,screen))))
        widget.currentIndexChanged.connect(lambda _:self.write(key,widget.currentData(),screen,rebuild))
        widget.setObjectName(key);form.addRow(self.tr(label),widget);return widget

    def number(self,form,label,key,low,high,step=1,screen=True,suffix=''):
        widget=SliderValue(low,high,step,self.value(key,screen),suffix)
        widget.valueChanged.connect(lambda n:self.write(key,n,screen));widget.setObjectName(key+'_control');widget.spin.setObjectName(key)
        widget.previewChanged.connect(lambda n:self.hud_preview.preview(key,n) if screen and self.hud_preview is not None else None)
        widget.slider.setAccessibleName(self.tr(label));widget.spin.setAccessibleName(self.tr(label));form.addRow(self.tr(label),widget)

    def general(self,layout):
        self.title(layout,'通用','外观、语言、启动方式和客户端回调。')
        form=self.group(layout,'外观与语言')
        appearance=self.combo(form,'外观','appearance',[('system','跟随系统'),('light','浅色'),('dark','深色')],rebuild=True)
        appearance.setToolTip('设置窗口、统计和菜单的外观；HUD 外观在「显示」中单独设置。')
        appearance.setEnabled(not self.manager.settings['match_screen'])
        self.check(form,'跟随所在屏幕','match_screen').toggled.connect(lambda _:QTimer.singleShot(0,self.rebuild))
        self.combo(form,'语言','language',[('system','跟随系统'),('zh','中文'),('en','English')],rebuild=True)
        form=self.group(layout,'启动');self.check(form,'登录时启动','launch_at_login')
        form=self.group(layout,'客户端');self.check(form,'客户端回调','client_hooks')
        wait=QComboBox();wait.addItem('10 分钟');wait.setEnabled(False);wait.setToolTip('权限审批暂未开放，由客户端自行询问。');form.addRow('等待回答',wait)

    def sources(self,layout):
        self.title(layout,'智能体','管理实时状态、套餐与显示窗口。')
        from agents_page import AgentsPage
        self.agent_page=AgentsPage(self);layout.addWidget(self.agent_page,1)

    def display(self,layout):
        self.title(layout,'显示','自定义灵动岛光晕与面板内容，更改自动生效。')
        form=self.group(layout,'屏幕','每块屏幕单独设置。')
        if len(self.manager.app.screens())>1:
            choose=QComboBox()
            for screen in self.manager.app.screens():choose.addItem(screen.name(),screen.name())
            choose.setCurrentIndex(max(0,choose.findData(self.selected_screen)))
            choose.currentIndexChanged.connect(lambda _:self.change_screen(choose.currentData()))
            form.addRow(self.tr('显示器'),choose)
        self.combo(form,'HUD 形态','mode',[('notch','刘海'),('simple','简约'),('logos','动态')],True,True)
        hint=QLabel('直接拖动可见的 HUD。拖动刘海会切换为「动态」。');hint.setProperty('subtitle',True);hint.setWordWrap(True);hint.setContentsMargins(0,0,0,12);form.addWidget(hint)
        self.combo(form,'HUD 外观','hud_appearance',[('dark','深色'),('light','浅色'),('system','跟随系统')],True)
        surface=Segmented([('solid','实色'),('clear','Clear'),('regular','Regular'),('material','磨砂')])
        selected=self.value('glass_style',True) if self.value('glass',True) else 'solid'
        surface.setCurrentIndex(surface.findData(selected));surface.currentIndexChanged.connect(lambda _:self.set_surface(surface.currentData()))
        surface.setObjectName('surface');form.addRow('材质',surface)
        self.number(form,'透明度','transparency',0,100,1,suffix=' %')
        button=QPushButton(self.tr('重置位置'));button.setProperty('smallAction',True);button.clicked.connect(self.reset_position);form.addRow('位置',button)
        button=QPushButton('恢复默认');button.setProperty('smallAction',True);button.setObjectName('reset_style');button.clicked.connect(self.reset_style);form.addRow('HUD 样式',button)
        own=any(key in self.manager.settings['placements'].get(self.selected_screen,{}) for key in ('panel_quota','panel_tokens','panel_sessions','panel_width','session_limit','reset_countdown'))
        actions=QWidget();actions.setProperty('wideActions',True);row=QHBoxLayout(actions);row.setContentsMargins(0,0,0,0);row.setSpacing(8)
        def action(text,name,callback,enabled=True):
            button=QPushButton(text);button.setProperty('smallAction',True);button.setObjectName(name);button.setEnabled(enabled);button.clicked.connect(callback);row.addWidget(button)
        if own:action('使用共用布局','shared_layout',self.shared_layout)
        action('恢复上一版','revert_layout',lambda:self.layout_action('revert'),bool(self.manager.settings.get('screen_versions',{}).get(self.selected_screen)))
        if own:action('恢复默认','reset_layout',lambda:self.layout_action('reset'))
        label=QLabel('面板布局\n'+('这块屏幕的布局' if own else '使用共用布局'));form.addRow(label,actions)
        if self.value('mode',True)!='notch':self.check(form,'按 agent 分开','separates_agents',True)
        if self.value('mode',True)=='simple':
            self.hud_preview=HudSample(self.manager,self.selected_screen);form.addRow(self.hud_preview)
            self.number(form,'大小','size',20,60,1,suffix=' pt')
            self.number(form,'Logo 间距','gap',.1,.6,.05)
            self.check(form,'显示圆环','show_rings',True)
            self.number(form,'圆环粗细','ring_width',1,4,.1,suffix=' pt')
            self.check(form,'显示数字','show_numbers',True)
        else:
            self.number(form,'Logo 大小','logo_size',20,60,1,suffix=' pt')
            self.number(form,'Logo 离屏幕边缘','edge_distance',0,20,1,suffix=' pt')
            self.number(form,'Logo 间距','logo_gap',.1,.6,.05)
            self.check(form,'显示 Logo','show_logos',True)
            self.glow(layout)
        form=self.group(layout,'展开面板')
        for label,key in [('会话列表','panel_sessions'),('额度明细','panel_quota'),('重置倒计时','reset_countdown'),('Token 消耗','panel_tokens')]:self.check(form,label,key,True)
        self.number(form,'面板宽度','panel_width',480,720,10,suffix=' pt')
        self.number(form,'会话上限','session_limit',1,20,1)
        form=self.group(layout,'悬停交互')
        self.check(form,'按 Alt 才展开','requires_alt');self.check(form,'鼠标触顶立即展开','immediate_top')
        self.number(form,'展开延迟','hover_delay',0,1500,50,False,' ms')
        self.number(form,'收起延迟','collapse_delay',0,1500,50,False,' ms')
        form=self.group(layout,'菜单栏');self.check(form,'显示托盘图标','show_tray')

    def glow(self,layout):
        form=self.group(layout,'背景光晕')
        self.combo(form,'光晕样式','glow_style',[('blur','柔光'),('dots','点阵'),('ascii','字符'),('blocks','色块'),('braille','盲文'),('binary','二进制')],True,True)
        self.combo(form,'动效','glow_effect',[('breathe','呼吸'),('flow','流光'),('scan','扫描'),('ripple','涟漪'),('shimmer','闪烁'),('boot','启动')],True)
        fields=[('光晕亮度','glow_brightness',.2,1,.05),
            ('工作时周期','glow_working',1,12,.1),('空闲时周期','glow_idle',1,24,.1),('呼吸幅度','glow_depth',0,1,.05),
            ]
        fields+= [('光晕范围','glow_range',0,36,1),('羽化','glow_blur',0,36,1)] if self.value('glow_style',True)=='blur' else [('点距','grid_pitch',4,12,1),('密度','grid_density',.5,1.5,.05),('实心','grid_core',0,8,1),('渐隐','grid_fade',0,8,1)]
        for label,key,low,high,step in fields:self.number(form,label,key,low,high,step)
        self.check(form,'仅向外扩散','glow_outward',True)

    def experimental(self,layout):
        self.title(layout,'实验选项','仍在验证的功能，以后可能会变。')
        form=self.group(layout,'Agent 工具')
        note=QLabel('MCP 布局草稿、权限审批和 Bot 动画暂未开放。')
        note.setWordWrap(True);form.addRow(note)

    def change_screen(self,name):
        self.selected_screen=name;QTimer.singleShot(0,self.rebuild)

    def reset_position(self):
        self.write_screen_values(dict(edge='top',offset=.5));self.rebuild()

    def set_surface(self,value):
        values=dict(glass=value!='solid')
        if value!='solid':values['glass_style']=value
        self.write_screen_values(values)
        QTimer.singleShot(0,self.rebuild)

    def write_screen_values(self,values,remember=False):
        try:
            if hasattr(self.manager,'apply_screen_settings'):self.manager.apply_screen_settings(values,self.selected_screen,remember=remember)
            else:
                for key,value in values.items():self.write(key,value,True)
            if self.hud_preview is not None:self.hud_preview.refresh()
        except RuntimeError as error:
            QMessageBox.warning(self,DESIGN['app_name'],str(error));QTimer.singleShot(0,self.rebuild)

    def reset_style(self):
        keys=('mode','edge','offset','size','ring_width','show_rings','show_numbers','show_logos','logo_size','logo_gap','edge_distance','gap','hud_appearance','glass','glass_style','transparency','glass_transparency','solid_transparency','separates_agents')
        keys+=tuple(key for key in DEFAULTS if key.startswith(('glow_','grid_')))
        values={key:DEFAULTS[key] for key in keys}
        self.write_screen_values(values,remember=True)
        self.rebuild()

    def shared_layout(self):
        self.layout_action('shared')

    def layout_action(self,action):
        if hasattr(self.manager,'change_screen_layout'):
            try:self.manager.change_screen_layout(self.selected_screen,action)
            except RuntimeError as error:QMessageBox.warning(self,DESIGN['app_name'],str(error))
        self.rebuild()
