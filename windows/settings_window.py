"""SettingsView / GeneralPane / SourcesPane / ScreensPane / IslandPane on Windows."""
from PySide6.QtCore import Qt,QTimer
from PySide6.QtWidgets import (QDialog,QHBoxLayout,QVBoxLayout,QListWidget,QStackedWidget,
    QWidget,QScrollArea,QLabel,QGroupBox,QFormLayout,QComboBox,QCheckBox,QDoubleSpinBox,QPushButton,QMessageBox)


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
        self.setWindowTitle('Agent HUD 设置')
        self.resize(960,720);self.setMinimumSize(880,560)
        self.selected_screen=manager.app.primaryScreen().name()
        self.root=QHBoxLayout(self);self.root.setContentsMargins(0,0,0,0);self.root.setSpacing(0)
        self.sidebar=QListWidget();self.sidebar.setFixedWidth(212)
        self.stack=QStackedWidget()
        self.root.addWidget(self.sidebar);self.root.addWidget(self.stack,1)
        self.sidebar.currentRowChanged.connect(self.stack.setCurrentIndex)
        self.rebuild()

    def tr(self,value):
        return EN.get(value,value) if self.manager.settings['language']=='en' else value

    def rebuild(self):
        self.status_labels={}
        if self.selected_screen not in [screen.name() for screen in self.manager.app.screens()]:self.selected_screen=self.manager.app.primaryScreen().name()
        previous=max(0,self.sidebar.currentRow())
        self.sidebar.blockSignals(True);self.sidebar.clear()
        while self.stack.count():
            widget=self.stack.widget(0);self.stack.removeWidget(widget);widget.deleteLater()
        for name in ('通用','智能体','显示','实验选项'):self.sidebar.addItem(self.tr(name))
        for method in (self.general,self.sources,self.display,self.experimental):
            page=QWidget();layout=QVBoxLayout(page);layout.setContentsMargins(20,24,20,32);layout.setSpacing(24)
            method(layout);layout.addStretch()
            scroll=QScrollArea();scroll.setWidgetResizable(True);scroll.setWidget(page);scroll.setFrameShape(QScrollArea.Shape.NoFrame)
            self.stack.addWidget(scroll)
        self.sidebar.blockSignals(False);self.sidebar.setCurrentRow(previous);self.stack.setCurrentIndex(previous)
        appearance=self.manager.settings['appearance']
        if self.manager.settings.get('match_screen'):appearance=self.manager.screen_settings(self.selected_screen)['hud_appearance']
        light=appearance=='light' or appearance=='system' and self.manager.app.palette().window().color().lightness()>128
        bg,sidebar,card,ink,muted,border=('#f5f5f7','#e8e8ea','#ffffff','#1d1d1f','#6e6e73','#dedee2') if light else ('#282828','#1f1f1f','#333333','#f5f5f7','#98989d','#484848')
        self.setStyleSheet(f'QDialog,QScrollArea,QStackedWidget,QWidget{{background:{bg};color:{ink};font-family:"Microsoft YaHei UI";font-size:13px}} '
            f'QListWidget{{background:{sidebar};border:0;padding:16px 10px}} QListWidget::item{{padding:11px;border-radius:7px;margin:2px}} QListWidget::item:selected{{background:#365576;color:white}} '
            f'QGroupBox{{background:{card};border:1px solid {border};border-radius:10px;margin-top:24px;padding:14px}} QGroupBox::title{{subcontrol-origin:margin;left:0;top:0;font-weight:600}} '
            f'QGroupBox QLabel,QGroupBox QCheckBox{{background:transparent}} QComboBox,QDoubleSpinBox,QPushButton{{background:{sidebar};border:1px solid {border};border-radius:6px;padding:6px;min-width:100px}} '
            f'QComboBox QAbstractItemView{{background:{card}}} QComboBox::drop-down{{border:0;width:22px}} '
            f'QDoubleSpinBox::up-button,QDoubleSpinBox::down-button{{border:0;width:20px;background:transparent}} '
            f'QCheckBox::indicator{{width:17px;height:17px;border:1px solid {muted};border-radius:5px;background:{sidebar}}} '
            f'QCheckBox::indicator:checked{{background:#0a84ff;border:1px solid #0a84ff}} QLabel[subtitle="true"]{{color:{muted};font-size:11px}}')

    def title(self,layout,name,subtitle):
        label=QLabel(self.tr(name));label.setStyleSheet('font-size:24px;font-weight:600');layout.addWidget(label)
        small=QLabel(subtitle);small.setProperty('subtitle',True);small.setWordWrap(True);layout.addWidget(small)

    def group(self,layout,title):
        group=QGroupBox(self.tr(title));form=QFormLayout(group);form.setVerticalSpacing(14);form.setLabelAlignment(Qt.AlignmentFlag.AlignLeft)
        layout.addWidget(group);return form

    def value(self,key,screen=False):
        return (self.manager.screen_settings(self.selected_screen) if screen else self.manager.settings)[key]

    def write(self,key,value,screen=False,rebuild=False):
        try:self.manager.apply_setting(key,value,self.selected_screen if screen else None)
        except Exception as error:
            QMessageBox.warning(self,'Agent HUD',str(error));return
        if rebuild:QTimer.singleShot(0,self.rebuild)

    def check(self,form,label,key,screen=False,disabled=None):
        widget=QCheckBox();widget.setChecked(bool(self.value(key,screen)))
        widget.toggled.connect(lambda value:self.write(key,value,screen))
        if disabled:widget.setEnabled(False);widget.setToolTip(disabled)
        widget.setObjectName(key);form.addRow(self.tr(label),widget);return widget

    def combo(self,form,label,key,options,screen=False,rebuild=False):
        widget=QComboBox()
        for value,title in options:widget.addItem(self.tr(title),value)
        widget.setCurrentIndex(max(0,widget.findData(self.value(key,screen))))
        widget.currentIndexChanged.connect(lambda _:self.write(key,widget.currentData(),screen,rebuild))
        widget.setObjectName(key);form.addRow(self.tr(label),widget);return widget

    def number(self,form,label,key,low,high,step=1,screen=True,suffix=''):
        widget=QDoubleSpinBox();widget.setRange(low,high);widget.setSingleStep(step)
        widget.setDecimals(0 if isinstance(step,int) else 2);widget.setSuffix(suffix);widget.setValue(self.value(key,screen))
        widget.valueChanged.connect(lambda n:self.write(key,n,screen));widget.setObjectName(key);form.addRow(self.tr(label),widget)

    def general(self,layout):
        self.title(layout,'通用','外观、语言、启动方式和客户端回调。')
        form=self.group(layout,'外观与语言')
        self.combo(form,'外观','appearance',[('system','跟随系统'),('light','浅色'),('dark','深色')],rebuild=True)
        self.check(form,'跟随所在屏幕','match_screen').toggled.connect(lambda _:QTimer.singleShot(0,self.rebuild))
        self.combo(form,'语言','language',[('system','跟随系统'),('zh','中文'),('en','English')],rebuild=True)
        form=self.group(layout,'启动');self.check(form,'登录时启动','launch_at_login')
        form=self.group(layout,'客户端');self.check(form,'客户端回调','client_hooks')
        note=QLabel('Windows 回调当前支持 Cursor 开始／结束记录；Codex 使用只读会话记录。\n权限审批桥尚未移植，不会自动批准或阻止任何工具。')
        note.setWordWrap(True);note.setProperty('subtitle',True);form.addRow(note)

    def sources(self,layout):
        self.title(layout,'智能体','管理 Codex / Cursor 的显示与读取。未运行的客户端始终隐藏。')
        form=self.group(layout,'智能体')
        for client in ('Codex','Cursor'):
            check=QCheckBox(client);check.setChecked(client in self.manager.settings['enabled_clients'])
            def changed(on,client=client):
                values=set(self.manager.settings['enabled_clients'])
                values.add(client) if on else values.discard(client)
                self.write('enabled_clients',list(values))
            check.toggled.connect(changed)
            status='运行中' if client in self.manager.data else '未运行'
            label=QLabel(status);self.status_labels[client]=label;form.addRow(check,label)
        button=QPushButton('立即刷新运行状态');button.clicked.connect(lambda:self.manager.refresh_now());form.addRow(button)

    def display(self,layout):
        self.title(layout,'显示','每块屏幕单独设置；直接拖动 HUD 可吸附到四条边，修改立即生效。')
        form=self.group(layout,'屏幕')
        choose=QComboBox()
        for screen in self.manager.app.screens():choose.addItem(screen.name(),screen.name())
        choose.setCurrentIndex(max(0,choose.findData(self.selected_screen)))
        choose.currentIndexChanged.connect(lambda _:self.change_screen(choose.currentData()))
        form.addRow(self.tr('显示器'),choose)
        self.combo(form,'HUD 形态','mode',[('notch','刘海'),('simple','简约'),('logos','动态')],True,True)
        self.combo(form,'位置','edge',[('top','顶部'),('right','右侧'),('bottom','底部'),('left','左侧')],True)
        self.number(form,'沿边位置','offset',0,1,.01)
        button=QPushButton(self.tr('重置位置'));button.clicked.connect(self.reset_position);form.addRow(button)
        self.check(form,'按 agent 分开','separates_agents',True)
        self.combo(form,'HUD 外观','hud_appearance',[('dark','深色'),('light','浅色'),('system','跟随系统')],True)
        self.check(form,'磨砂','glass',True)
        self.combo(form,'材质','glass_style',[('clear','Clear'),('regular','Regular'),('material','磨砂')],True)
        self.number(form,'透明度','transparency',0,100,1,suffix=' %')
        if self.value('mode',True)=='simple':
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
        self.title(layout,'实验选项','与上游的实验功能保持区分，不用无效开关假装已经移植。')
        form=self.group(layout,'Agent 工具')
        note=QLabel('Agent 修改 HUD 的 MCP 草稿／保存流程、Windows 权限审批桥、Bot 导演动画尚未完成移植。\n这些功能当前不启用。其他 macOS 客户端不在本次 Codex / Cursor 接入范围内。\nWindows Clear / Regular / 磨砂使用系统 Acrylic，不能提供 Apple Liquid Glass 的同一合成器。')
        note.setWordWrap(True);form.addRow(note)

    def change_screen(self,name):
        self.selected_screen=name;QTimer.singleShot(0,self.rebuild)

    def reset_position(self):
        self.write('edge','top',True);self.write('offset',.5,True);self.rebuild()
