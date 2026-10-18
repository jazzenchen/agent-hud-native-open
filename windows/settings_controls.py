"""SwiftUI-style controls for the Windows settings host; native keyboard semantics."""
from PySide6.QtCore import Qt,QRectF,QPointF,Property,QSignalBlocker,Signal
from PySide6.QtGui import QColor,QPainter,QPen,QFont,QIcon,QPixmap,QPainterPath,QRadialGradient
from PySide6.QtWidgets import (QWidget,QCheckBox,QHBoxLayout,QVBoxLayout,QPushButton,QButtonGroup,
    QSlider,QDoubleSpinBox,QLabel,QGraphicsOpacityEffect,QFrame,QSizePolicy)
from motion import SpringDriver,animations_enabled

def is_light(widget):return bool(widget.window().property('uiLight'))

class Switch(QCheckBox):
    """A switch with QCheckBox's focus, checked state, shortcuts and accessibility."""
    def __init__(self,parent=None):
        super().__init__(parent);self._position=0.
        self.setFixedSize(40,24);self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.animation=SpringDriver(self,frequency=7.,damping=.92);self.animation.valueChanged.connect(self.set_position)
        self.toggled.connect(self.transition)
    def get_position(self):return self._position
    def set_position(self,value):self._position=float(value);self.update()
    position=Property(float,get_position,set_position)
    def transition(self,on):
        self.animation.retarget(float(on),immediate=not self.isVisible())
    def hitButton(self,point):return self.rect().contains(point)
    def hideEvent(self,event):
        self.animation.jump(float(self.isChecked()));super().hideEvent(event)
    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        if not self.isEnabled():p.setOpacity(.4)
        t=max(0,min(1,self._position));base=QColor('#d1d1d6' if is_light(self) else '#5a5a60');accent=QColor('#0a84ff')
        track=QColor.fromRgbF(base.redF()*(1-t)+accent.redF()*t,base.greenF()*(1-t)+accent.greenF()*t,base.blueF()*(1-t)+accent.blueF()*t)
        p.setPen(Qt.PenStyle.NoPen);p.setBrush(track);p.drawRoundedRect(QRectF(1,2,38,20),10,10)
        x=3+18*t
        p.setBrush(QColor(0,0,0,24));p.drawEllipse(QRectF(x-.5,3.5,19,19))
        p.setBrush(QColor('white'));p.drawEllipse(QRectF(x-.5 if self.isDown() else x,5 if self.isDown() else 4,17 if self.isDown() else 16,14 if self.isDown() else 16))
        if self.hasFocus():p.setBrush(Qt.BrushStyle.NoBrush);p.setPen(QPen(QColor('#0a84ff'),1));p.drawRoundedRect(QRectF(.5,.5,39,23),12,12)
        p.end()

class Segmented(QWidget):
    currentIndexChanged=Signal(int)
    def __init__(self,items,parent=None):
        super().__init__(parent);self.setObjectName('segmented');self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground);self.items=items;self.index=0
        self._selection=0.
        self.animation=SpringDriver(self,frequency=5.5);self.animation.valueChanged.connect(self.set_selection)
        self.layout=QHBoxLayout(self);self.layout.setContentsMargins(3,3,3,3);self.layout.setSpacing(1)
        self.group=QButtonGroup(self);self.group.setExclusive(True);self.buttons=[]
        for index,(value,label) in enumerate(items):
            button=QPushButton(label);button.setObjectName('segment');button.setCheckable(True);button.setCursor(Qt.CursorShape.PointingHandCursor)
            button.setMinimumWidth(48);self.layout.addWidget(button,1);self.group.addButton(button,index);self.buttons.append(button)
        self.group.idClicked.connect(self.setCurrentIndex);self.buttons[0].setChecked(True)
        self.setFixedHeight(32);self.setMinimumWidth(230)
    def currentData(self):return self.items[self.index][0]
    def findData(self,value):return next((i for i,(v,_) in enumerate(self.items) if v==value),-1)
    def setCurrentIndex(self,index):
        if index<0 or index>=len(self.items):return
        changed=self.index!=index;self.index=index;self.buttons[index].setChecked(True)
        self.animation.retarget(float(index),immediate=not self.isVisible() or not changed)
        if changed:self.currentIndexChanged.emit(index)

    def get_selection(self):return self._selection
    def set_selection(self,value):self._selection=float(value);self.update()
    selection=Property(float,get_selection,set_selection)

    def paintEvent(self,event):
        painter=QPainter(self);painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        from theme import tokens
        t=tokens(is_light(self));painter.setPen(QPen(QColor(t['border']),1));painter.setBrush(QColor(t['sidebar']))
        painter.drawRoundedRect(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5),7,7)
        if not self.buttons:return
        first=self.buttons[0].geometry();last=self.buttons[-1].geometry()
        step=(last.x()-first.x())/max(1,len(self.buttons)-1)
        pill=QRectF(first);pill.moveLeft(first.x()+self._selection*step)
        painter.setPen(Qt.PenStyle.NoPen);painter.setBrush(QColor('#ffffff' if is_light(self) else '#57575b'))
        if not self.isEnabled():painter.setOpacity(.45)
        painter.drawRoundedRect(pill,5,5);painter.end()
    def hideEvent(self,event):
        self.animation.jump(float(self.index));super().hideEvent(event)

class SliderValue(QWidget):
    """Continuous preview while dragging; commit a setting only at gesture end."""
    valueChanged=Signal(float)
    previewChanged=Signal(float)
    def __init__(self,low,high,step,value,suffix='',parent=None):
        super().__init__(parent);self.low=low;self.step=step
        layout=QHBoxLayout(self);layout.setContentsMargins(0,0,0,0);layout.setSpacing(14)
        self.slider=QSlider(Qt.Orientation.Horizontal);self.slider.setRange(0,round((high-low)/step))
        self.spin=QDoubleSpinBox();self.spin.setRange(low,high);self.spin.setSingleStep(step)
        self.spin.setDecimals(0 if isinstance(step,int) else 2);self.spin.setSuffix(suffix)
        self.spin.setFixedWidth(92);self.spin.setKeyboardTracking(False);self.slider.setMinimumWidth(120)
        self.slider.setValue(round((value-low)/step));self.spin.setValue(value)
        layout.addWidget(self.slider,1);layout.addWidget(self.spin)
        self.slider.valueChanged.connect(self.from_slider);self.slider.sliderReleased.connect(lambda:self.valueChanged.emit(self.spin.value()))
        self.spin.valueChanged.connect(self.from_spin)
    def from_slider(self,index):
        value=self.low+index*self.step
        with QSignalBlocker(self.spin):self.spin.setValue(value)
        self.previewChanged.emit(value)
        if not self.slider.isSliderDown():self.valueChanged.emit(value)
    def from_spin(self,value):
        with QSignalBlocker(self.slider):self.slider.setValue(round((value-self.low)/self.step))
        self.previewChanged.emit(value);self.valueChanged.emit(value)

def sidebar_icon(kind,tint):
    pix=QPixmap(52,52);pix.fill(Qt.GlobalColor.transparent);p=QPainter(pix);p.scale(2,2)
    p.setRenderHint(QPainter.RenderHint.Antialiasing);p.setPen(Qt.PenStyle.NoPen);p.setBrush(QColor(tint));p.drawRoundedRect(QRectF(0,0,26,26),7,7)
    p.setPen(QPen(QColor('white'),1.5,Qt.PenStyle.SolidLine,Qt.PenCapStyle.RoundCap,Qt.PenJoinStyle.RoundJoin));p.setBrush(Qt.BrushStyle.NoBrush)
    if kind=='display':
        p.drawRoundedRect(QRectF(5.5,6,15,10.5),2,2);p.drawLine(QPointF(13,17),QPointF(13,20));p.drawLine(QPointF(9,20),QPointF(17,20))
    elif kind=='general':
        p.drawEllipse(QPointF(13,13),5,5);p.drawEllipse(QPointF(13,13),1.6,1.6)
        p.translate(13,13)
        for _ in range(8):p.drawLine(QPointF(0,-5),QPointF(0,-7));p.rotate(45)
    elif kind=='agents':
        p.drawRoundedRect(QRectF(6,9,14,11),3,3);p.drawLine(QPointF(13,9),QPointF(13,6));p.drawPoint(QPointF(10,14));p.drawPoint(QPointF(16,14));p.drawLine(QPointF(10,17),QPointF(16,17))
    else:
        path=QPainterPath();path.moveTo(10,5);path.lineTo(16,5);path.moveTo(11,5);path.lineTo(11,11);path.lineTo(6,19);path.quadTo(5,21,8,21);path.lineTo(18,21);path.quadTo(21,21,20,19);path.lineTo(15,11);path.lineTo(15,5);p.drawPath(path);p.drawLine(QPointF(9,16),QPointF(17,16))
    p.end();pix.setDevicePixelRatio(2);return QIcon(pix)

class PageTransition:
    """One short fade when navigating; never rebuild settings while it runs."""
    def __init__(self,stack):
        self.stack=stack;self.effect=QGraphicsOpacityEffect(stack);stack.setGraphicsEffect(self.effect)
        self.animation=SpringDriver(stack,value=1.,frequency=7.);self.animation.valueChanged.connect(lambda value:self.effect.setOpacity(max(0,min(1,value))))
    def run(self):
        if not self.animation.running:self.animation.jump(.9)
        self.animation.retarget(1.)

class CardSurface(QFrame):
    """Source card geometry with restrained pointer light; text and hit boxes stay still."""
    def __init__(self):
        super().__init__();self.setObjectName('settingsCard');self.setAttribute(Qt.WidgetAttribute.WA_Hover)
        self.light_amount=SpringDriver(self,frequency=5.);self.light_amount.valueChanged.connect(lambda _:self.update())
        self.pointer_x=SpringDriver(self,value=.5,frequency=7.);self.pointer_y=SpringDriver(self,value=.5,frequency=7.)
        self.pointer_x.valueChanged.connect(lambda _:self.update());self.pointer_y.valueChanged.connect(lambda _:self.update())
    def event(self,event):
        if hasattr(self,'light_amount'):
            if event.type()==event.Type.HoverEnter:self.light_amount.retarget(1.)
            elif event.type()==event.Type.HoverLeave:self.light_amount.retarget(0.)
            elif event.type()==event.Type.HoverMove:
                point=event.position()
                self.pointer_x.retarget(point.x()/max(1,self.width()),immediate=not animations_enabled())
                self.pointer_y.retarget(point.y()/max(1,self.height()),immediate=not animations_enabled())
        return super().event(event)
    def paintEvent(self,event):
        from theme import tokens
        t=tokens(is_light(self));p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        path=QPainterPath();path.addRoundedRect(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5),10,10)
        p.fillPath(path,QColor(t['card']));amount=max(0,min(1,self.light_amount.state.position))
        if amount>.001:
            p.save();p.setClipPath(path)
            point=QPointF(self.pointer_x.state.position*self.width(),self.pointer_y.state.position*self.height())
            gradient=QRadialGradient(point,220)
            accent=QColor('#0a84ff' if is_light(self) else '#ffffff');accent.setAlphaF(amount*(.025 if is_light(self) else .045))
            gradient.setColorAt(0,accent);accent.setAlpha(0);gradient.setColorAt(1,accent);p.fillPath(path,gradient);p.restore()
        p.setPen(QPen(QColor(t['border']),1));p.setBrush(Qt.BrushStyle.NoBrush);p.drawPath(path);p.end()
    def hideEvent(self,event):
        self.light_amount.jump(0.);self.pointer_x.stop();self.pointer_y.stop();super().hideEvent(event)

class SettingRows(QVBoxLayout):
    """Source SettingsCard: label left, compact control right, hairline row dividers."""
    def __init__(self,card,subtitles=None):
        super().__init__(card);self.setContentsMargins(16,0,16,0);self.setSpacing(0);self.count_rows=0;self.subtitles=subtitles or {}
    def addRow(self,*args):
        if self.count_rows:
            line=QFrame();line.setObjectName('rowDivider');line.setFixedHeight(1);self.addWidget(line)
        self.count_rows+=1
        row=QWidget();row.setObjectName('settingRow');layout=QHBoxLayout(row);layout.setContentsMargins(0,12,0,12);layout.setSpacing(20)
        if len(args)==1:
            layout.addWidget(args[0],1)
        else:
            label,control=args
            if isinstance(label,str):
                labels=QWidget();labels.setObjectName('rowLabels');column=QVBoxLayout(labels);column.setContentsMargins(0,0,0,0);column.setSpacing(4)
                title=QLabel(label);title.setWordWrap(True);column.addWidget(title)
                if label in self.subtitles:
                    subtitle=QLabel(self.subtitles[label]);subtitle.setProperty('subtitle',True);subtitle.setWordWrap(True);column.addWidget(subtitle)
                layout.addWidget(labels,1)
            else:layout.addWidget(label,1)
            if isinstance(control,(Segmented,SliderValue)):
                control.setMaximumWidth(330);control.setSizePolicy(QSizePolicy.Policy.Expanding,QSizePolicy.Policy.Fixed);layout.addWidget(control,2)
            else:
                control.setMaximumWidth(220);layout.addWidget(control,0,Qt.AlignmentFlag.AlignRight|Qt.AlignmentFlag.AlignVCenter)
        row.setMinimumHeight(52);self.addWidget(row)
