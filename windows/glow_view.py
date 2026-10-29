"""Windows transparent, input-through compositor for source GlowMotion math."""
import time,math
from PySide6.QtCore import Qt,QTimer,QRectF,QPointF
from PySide6.QtGui import QColor,QPainter,QPen,QFont,QPainterPath,QTransform,QLinearGradient,QBrush,QPixmap
from PySide6.QtWidgets import QWidget
from glow_logic import gain,strength,distance,sheen,noise,BAYER
from motion import animations_enabled

class GlowView(QWidget):
    def __init__(self,meter):
        super().__init__(None,Qt.WindowType.Tool|Qt.WindowType.FramelessWindowHint|Qt.WindowType.WindowStaysOnTopHint|Qt.WindowType.WindowTransparentForInput|Qt.WindowType.WindowDoesNotAcceptFocus)
        self.meter=meter;self.started=time.monotonic();self.margin=0
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.timer=QTimer(self);self.timer.setTimerType(Qt.TimerType.PreciseTimer);self.timer.setInterval(16);self.timer.timeout.connect(self.update)
        self._grid_key=None;self._grid_cells=[]
        self._soft_key=None;self._soft_image=None

    def sync(self):
        cfg=self.meter.settings
        if cfg.get('mode','simple')=='simple' or cfg.get('glow_hidden') or not self.meter.isVisible() or self.meter.dragging:
            self.hide();self.timer.stop();return
        pitch=cfg['grid_pitch']
        self.margin=math.ceil(cfg['glow_range']+3*cfg['glow_blur'] if cfg['glow_style']=='blur' else (cfg['grid_core']+cfg['grid_fade'])*pitch)
        geo=self.meter.geometry().adjusted(-self.margin,-self.margin,self.margin,self.margin)
        if self.geometry()!=geo:self.setGeometry(geo)
        if not self.isVisible():self.show();self.meter.raise_()
        if animations_enabled():
            if not self.timer.isActive():self.timer.start()
        else:self.timer.stop()
        self.update()

    def paintEvent(self,event):
        cfg=self.meter.settings;p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        margin=self.margin;w=self.meter.width();h=self.meter.height();radius=self.meter.corner
        if cfg['glow_outward']:
            exterior=QPainterPath();exterior.addRect(QRectF(self.rect()))
            interior=QTransform.fromTranslate(margin,margin).map(self.meter.surface_path())
            p.setClipPath(exterior.subtracted(interior))
        moving=animations_enabled();seconds=time.monotonic()-self.started if moving else 0.
        effect=cfg['glow_effect'] if moving else 'breathe'
        if not moving:self.timer.stop()
        running=any(r.get('state')=='running' for data in self.meter.group_data.values() for r in data.get('local',{}).get('sessions',[]))
        period=cfg['glow_working'] if running else cfg['glow_idle'];pitch=cfg['grid_pitch']
        from views import level,tightest,color
        self.meter.palette_colors()
        tint=QColor(self.meter.palette_colors()[level(tightest(self.meter.data))])
        def ink(alpha,x):
            c=QColor(tint)
            if effect=='flow':
                white=sheen(seconds,period,x/max(1,self.width()))*.7
                c.setRgbF(c.redF()+(1-c.redF())*white,c.greenF()+(1-c.greenF())*white,c.blueF()+(1-c.blueF())*white)
            c.setAlphaF(max(0,min(1,alpha*cfg['glow_brightness'])));return c
        if cfg['glow_style']=='blur':
            extent=cfg['glow_range']+3*cfg['glow_blur']
            if effect=='breathe':
                key=(w,h,radius,margin,tint.rgba(),cfg['glow_range'],cfg['glow_blur'],cfg['glow_brightness'])
                if key!=self._soft_key:
                    self._soft_key=key;self._soft_image=QPixmap(self.size());self._soft_image.fill(Qt.GlobalColor.transparent)
                    cached=QPainter(self._soft_image);cached.setRenderHint(QPainter.RenderHint.Antialiasing);cached.setBrush(Qt.BrushStyle.NoBrush)
                    for spread in range(math.ceil(extent),0,-2):
                        alpha=.06*math.exp(-max(0,spread-cfg['glow_range'])**2/max(1,2*cfg['glow_blur']**2))
                        cached.setPen(QPen(ink(alpha,0),3));cached.drawRoundedRect(QRectF(margin-spread,margin-spread,w+2*spread,h+2*spread),radius+spread,radius+spread)
                    cached.end()
                p.setOpacity(gain(effect,seconds,period,0,0,pitch,self.width(),cfg['glow_depth']))
                p.drawPixmap(0,0,self._soft_image);p.end();return
            for spread in range(math.ceil(extent),0,-2):
                base=.06*math.exp(-max(0,spread-cfg['glow_range'])**2/max(1,2*cfg['glow_blur']**2))
                gradient=QLinearGradient(0,0,self.width(),0)
                for stop in range(17):
                    x=self.width()*stop/16
                    motion=gain(effect,seconds,period,x,spread,pitch,self.width(),cfg['glow_depth'],stop,round(spread))
                    gradient.setColorAt(stop/16,ink(base*motion,x))
                p.setPen(QPen(QBrush(gradient),3));p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawRoundedRect(QRectF(margin-spread,margin-spread,w+2*spread,h+2*spread),radius+spread,radius+spread)
        else:
            style=cfg['glow_style'];step_y=pitch*(2 if style=='braille' else 1)
            font=QFont('Consolas');font.setPixelSize(max(5,round(pitch*cfg['grid_density'])));p.setFont(font)
            key=(w,h,radius,margin,pitch,step_y,cfg['grid_core'],cfg['grid_fade'],cfg['glow_outward'])
            if key!=self._grid_key:
                self._grid_key=key;self._grid_cells=[]
                for row in range(math.ceil(self.height()/step_y)):
                    y=(row+.5)*step_y
                    for column in range(math.ceil(self.width()/pitch)):
                        x=(column+.5)*pitch;d=distance(x-margin,y-margin,w,h,radius)
                        if d<0 and cfg['glow_outward']:continue
                        resting=strength(max(0,d),pitch,cfg['grid_core'],cfg['grid_fade'])
                        if resting*1.2>=.06:self._grid_cells.append((column,row,x,y,d,resting))
            for column,row,x,y,d,resting in self._grid_cells:
                    alpha=resting*gain(effect,seconds,period,x,max(0,d),pitch,self.width(),cfg['glow_depth'],column,row)
                    if alpha<.06:continue
                    p.setPen(ink(alpha,x));p.setBrush(ink(alpha,x))
                    size=pitch*.3*cfg['grid_density']
                    if style=='dots':p.drawEllipse(QPointF(x,y),size/2,size/2)
                    elif style=='blocks':p.fillRect(QRectF(x-size,y-size,2*size,2*size),ink(alpha,x))
                    else:
                        if style=='ascii':mark=' .:-=+*#%@'[min(9,round(min(1,alpha)*9))]
                        elif style=='binary':mark='1' if noise(column,row,math.floor(seconds*8))>.5 else '0'
                        else:
                            bits=0
                            for dot,(cx,cy,bit) in enumerate(((0,0,0),(0,1,1),(0,2,2),(1,0,3),(1,1,4),(1,2,5),(0,3,6),(1,3,7))):
                                if .1+.9*alpha>(BAYER[((row*4+cy)&3)*4+((column*2+cx)&3)]+.5)/16:bits|=1<<bit
                            mark=chr(0x2800+bits)
                        p.drawText(QRectF(x-pitch/2,y-step_y/2,pitch,step_y),Qt.AlignmentFlag.AlignCenter,mark)
        p.end()
