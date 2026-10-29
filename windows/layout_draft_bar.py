"""Original PanelDraftBar as real keyboard-accessible Windows child controls."""
from PySide6.QtCore import Qt,QRectF
from PySide6.QtGui import QColor,QPainter,QPen
from PySide6.QtWidgets import QWidget,QHBoxLayout,QLabel,QPushButton,QMessageBox,QGraphicsOpacityEffect
from theme import tokens


class DraftGlyph(QWidget):
    def __init__(self,panel):
        super().__init__();self.panel=panel;self.setFixedSize(12,12)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        pen=QPen(QColor(self.panel.meter.palette_colors()['warningText']),1.2,Qt.PenStyle.DashLine)
        p.setPen(pen);p.setBrush(Qt.BrushStyle.NoBrush);p.drawRoundedRect(QRectF(1,1,10,10),1.5,1.5);p.end()


class LayoutDraftBar(QWidget):
    bar_height=34
    def __init__(self,panel):
        super().__init__(panel);self.panel=panel;self.setObjectName('island-layout-draft')
        self.fade=QGraphicsOpacityEffect(self);self.setGraphicsEffect(self.fade)
        row=QHBoxLayout(self);row.setContentsMargins(9,6,9,6);row.setSpacing(6)
        row.addWidget(DraftGlyph(panel))
        self.title=QLabel('布局未保存');self.title.setObjectName('draftTitle');row.addWidget(self.title)
        self.note=QLabel();self.note.setObjectName('draftNote');row.addWidget(self.note,1)
        self.buttons={}
        for name,label in [('discard','放弃'),('save','保存')]:
            button=QPushButton(label);button.setObjectName('island-layout-'+name);button.setAccessibleName(label+'布局草稿')
            button.setFixedHeight(22);button.setCursor(Qt.CursorShape.PointingHandCursor)
            button.clicked.connect(lambda _,name=name:self.choose(name));row.addWidget(button)
            self.buttons[name]=button
        self.hide()
    def store(self):return getattr(self.panel.meter,'layout_store',None)
    def ready(self):return self.store() is not None and self.store().has_draft(self.panel.meter.screen.name()) and not self.panel.meter.attention_event()
    def sync(self):
        if not self.ready():self.hide();return
        t=tokens(self.panel.meter.light());screen=self.panel.meter.screen.name()
        grey=QColor(self.panel.meter.palette_colors()['secondary'])
        t['muted']=f'rgba({grey.red()},{grey.green()},{grey.blue()},{grey.alpha()})'
        shared=self.store().draft_scope(screen)=='shared'
        english=self.panel.meter.settings.get('language')=='en'
        self.title.setText('Unsaved layout' if english else '布局未保存')
        self.note.setText(('Dropped on restart' if shared else 'This display only') if english else ('重启后丢弃' if shared else '仅此显示器'))
        self.note.setToolTip(('Dropped on restart' if shared else 'This display only, dropped on restart') if english else ('重启后丢弃' if shared else '仅此显示器，重启后丢弃'))
        for key,button in self.buttons.items():
            button.setText(('Save' if key=='save' else 'Discard') if english else ('保存' if key=='save' else '放弃'))
            button.setAccessibleName(button.text()+(' layout draft' if english else '布局草稿'))
        ink=QColor(t['ink']);background=f'rgba({ink.red()},{ink.green()},{ink.blue()},15)'
        style=(f'QWidget#island-layout-draft{{background:{background};border-radius:8px}} '
            f'QLabel{{background:transparent;color:{t["muted"]};font-family:"Segoe UI","Microsoft YaHei UI";font-size:11px}} '
            f'QLabel#draftTitle{{color:{t["ink"]};font-size:12px;font-weight:500}} '
            f'QPushButton{{color:{t["muted"]};background:transparent;border:1px solid {t["border"]};border-radius:6px;padding:0 9px;font-size:11px}} '
            f'QPushButton:focus{{border:1px solid {t["accent"]}}} '
            f'QPushButton#island-layout-save{{background:{t["ink"]};color:{t["bg"]}}}')
        if getattr(self,'_style',None)!=style:self.setStyleSheet(style);self._style=style
        phase=max(0,min(1,(self.panel.progress-.1)/.9));self.fade.setOpacity(phase*phase*(3-2*phase))
        self.setGeometry(18,max(0,self.panel.height()-14-28-6-self.bar_height),max(1,self.panel.width()-36),self.bar_height)
        if self.isHidden():self.show();self.raise_()
    def choose(self,name):
        if not self.ready():return
        try:
            method=self.store().save_panel if name=='save' else self.store().discard_panel
            method(self.panel.meter.screen.name())
        except (OSError,RuntimeError) as error:
            QMessageBox.warning(self,'Agent HUD',str(error));return
        callback=getattr(self.panel.meter,'layout_changed_callback',None)
        if callback:callback()
        self.panel.set_data(self.panel.meter.data);self.panel.animation.retarget(1.)
