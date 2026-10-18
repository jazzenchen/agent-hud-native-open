"""Source AgentPeek line (Simple) / bubble (Dynamic), never the full hover panel."""
import math
from PySide6.QtCore import Qt,QRectF,QPointF
from PySide6.QtGui import QPainter,QPainterPath,QPen,QFontMetricsF,QRegion
from PySide6.QtWidgets import QWidget
from source_design import DESIGN
from motion import SpringDriver
from material import frosted_backdrop,rounded_native_window
from theme import apply_widget_theme

class AgentPeekView(QWidget):
    def __init__(self,meter):
        super().__init__(None,Qt.WindowType.Tool|Qt.WindowType.FramelessWindowHint|Qt.WindowType.WindowStaysOnTopHint|Qt.WindowType.WindowDoesNotAcceptFocus)
        self.meter=meter;self.progress=0.;self.native_glass=False;self.rows=[]
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground);self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setWindowTitle(DESIGN['app_name']);self.setMouseTracking(True)
        self.animation=SpringDriver(self,frequency=5.2);self.animation.valueChanged.connect(self.animate)
        self.animation.finished.connect(lambda:self.hide() if self.progress<.001 else None)
        self.target_width=1;self.target_height=26;self.corner=13

    @property
    def line(self):return self.meter.settings.get('mode','simple')=='simple'

    def refresh(self):
        from views import font
        cfg=self.meter.settings
        scale=max(1,cfg['size' if self.line else 'logo_size']/DESIGN['peek_height'])
        self.font_size=round(DESIGN['peek_font']*scale) if self.line else round(12*scale)
        self.spacing=round(12*scale);self.pair_gap=round(5*scale);self.padding=round(12*scale)
        self.rows=[]
        for row in self.meter.data.get('quota',{}).get('windows',[]):
            used=row.get('used');label={'5-hour':'5h'}.get(row['label'],row['label'])
            self.rows.append((label,'–' if used is None else f'{used:.0f}%',used))
        running=sum(row.get('state')=='running' for row in self.meter.data.get('local',{}).get('sessions',[]))
        self.running=running
        self.fallback=f'{running} 个运行中' if running else self.meter.client
        fm=QFontMetricsF(font(self.font_size));bold=QFontMetricsF(font(self.font_size,True))
        edge=cfg['edge'];self.tuck=round(self.meter.width()/2) if self.line and edge in ('left','right') else 0
        if self.line:
            cells=sum(math.ceil(fm.horizontalAdvance(label))+self.pair_gap+math.ceil(bold.horizontalAdvance(value)) for label,value,_ in self.rows)
            if not self.rows:cells=math.ceil(fm.horizontalAdvance(self.fallback))
            width=cells+max(0,len(self.rows)-1)*self.spacing+2*self.padding+self.tuck
            self.target_height=round(DESIGN['peek_height']*scale);self.target_width=min(width,self.meter.screen.availableGeometry().width()-12)
        else:
            self.target_width=round(196*scale);self.target_height=round(20*scale+18*scale*(1+len(self.rows)+(1 if running else 0)))
        self.corner=self.target_height/2 if self.line else 12
        if self.isVisible():self.animate(self.progress)

    def open(self):
        self.refresh();self.animate(self.progress)
        if not self.isVisible():self.show();self.apply_material();self.meter.raise_()
        self.animation.retarget(1.)

    def dismiss(self,immediate=False):
        if immediate:
            self.animation.jump(0.);self.hide()
        elif self.isVisible():self.animation.retarget(0.)

    def animate(self,progress):
        self.progress=max(0,min(1,float(progress)))
        start=max(1,min(self.target_width,self.meter.width()/2))
        self.setFixedSize(max(1,round(start+(self.target_width-start)*self.progress)),self.target_height)
        path=QPainterPath();path.addRoundedRect(QRectF(self.rect()),self.corner,self.corner)
        self.setMask(QRegion(path.toFillPolygon().toPolygon()))
        self.reposition()
        if self.isVisible():rounded_native_window(self,self.corner)
        self.update()

    def reposition(self):
        geom=self.meter.geometry();cfg=self.meter.settings;edge=cfg['edge']
        selected=next((rect for client,rect in self.meter.cells if client==self.meter.client),QRectF(self.meter.rect()))
        cx=geom.x()+selected.center().x();cy=geom.y()+selected.center().y()
        if edge=='left':x=geom.right()-self.tuck;y=cy-self.height()/2
        elif edge=='right':x=geom.left()-self.width()+self.tuck;y=cy-self.height()/2
        elif edge=='bottom':x=cx-self.width()/2;y=geom.top()-self.height()
        else:x=cx-self.width()/2;y=geom.bottom()+1
        screen=self.meter.screen.availableGeometry()
        self.move(round(max(screen.left()+2,min(x,screen.right()-self.width()-2))),round(max(screen.top()+2,min(y,screen.bottom()-self.height()-2))))

    def apply_material(self):
        apply_widget_theme(self,self.meter.light())
        cfg=self.meter.settings
        self.native_glass=not self.meter.preview and cfg['glass'] and frosted_backdrop(self.winId(),True,cfg['transparency'],self.meter.light(),cfg['glass_style'])
        if not self.meter.preview and not cfg['glass']:frosted_backdrop(self.winId(),False)
        rounded_native_window(self,self.corner);self.update()

    def paintEvent(self,event):
        from views import text,color,level,font
        p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        path=QPainterPath();path.addRoundedRect(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5),self.corner,self.corner)
        p.fillPath(path,self.meter.surface_fill(self.native_glass));p.setPen(QPen(color('outline',painter=p),1));p.drawPath(path);p.setClipPath(path)
        p.setOpacity(self.progress)
        x=self.padding+(self.tuck if self.meter.settings['edge']=='left' else 0)
        if self.line:
            fm=QFontMetricsF(font(self.font_size));bold=QFontMetricsF(font(self.font_size,True))
            if not self.rows:text(p,QRectF(x,0,self.target_width-x-self.padding,self.height()),self.fallback,self.font_size,'secondary')
            for label,value,used in self.rows:
                width=math.ceil(fm.horizontalAdvance(label));text(p,QRectF(x,0,width,self.height()),label,self.font_size,'secondary');x+=width+self.pair_gap
                width=math.ceil(bold.horizontalAdvance(value));text(p,QRectF(x,0,width,self.height()),value,self.font_size,level(used),True);x+=width+self.spacing
        else:
            y=10;text(p,QRectF(x,y,self.width()-2*x,18),self.meter.client,13,'text',True);y+=18
            for label,value,used in self.rows:
                text(p,QRectF(x,y,self.width()-2*x,18),label,self.font_size,'secondary')
                text(p,QRectF(x,y,self.width()-2*x,18),value,self.font_size,level(used),True,Qt.AlignmentFlag.AlignRight);y+=18
            if self.running:text(p,QRectF(x,y,self.width()-2*x,18),f'{self.running} 个运行中',self.font_size,'secondary')
        p.end()

    def enterEvent(self,event):self.meter.leave_timer.stop()
    def leaveEvent(self,event):self.meter.leave_timer.start()
    def mousePressEvent(self,event):
        if event.button()==Qt.MouseButton.LeftButton:self.pressed=True
        elif event.button()==Qt.MouseButton.RightButton:self.meter.menu_callback(event.globalPosition().toPoint())
    def mouseReleaseEvent(self,event):
        if event.button()==Qt.MouseButton.LeftButton:
            activate=getattr(self,'pressed',False) and self.rect().contains(event.position().toPoint());self.pressed=False
            if activate:self.meter.panel.pinned=True;self.meter.open_panel()
