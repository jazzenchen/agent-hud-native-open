"""Qt counterparts of SimpleMeterView and the SwiftUI HoverPanelView tree.

Palette, geometry and timing come from source_design (the original Swift files).
The Windows layer supplies native glass, font substitution, windows and painting.
"""
from datetime import datetime
import math

from PySide6.QtCore import Qt, QRectF, QPointF, QSize, QTimer, QVariantAnimation, QEasingCurve
from PySide6.QtGui import QColor, QFont, QFontMetricsF, QImage, QPainter, QPainterPath, QPen, QPixmap, QRegion,QCursor
from PySide6.QtWidgets import QWidget, QMenu, QApplication

from material import frosted_backdrop,rounded_native_window
from source_design import DESIGN
from look_logic import stand_in
from theme import resolves_light,apply_widget_theme
from motion import SpringDriver,animations_enabled
from peek_view import AgentPeekView

COLORS = DESIGN['colors']


def font(size, bold=False):
    result = QFont('Segoe UI')  # Windows system substitute for Font.ui's SF Pro.
    result.setFamilies(['Segoe UI','Microsoft YaHei UI'])
    result.setPixelSize(int(size))
    result.setWeight(QFont.Weight.DemiBold if bold else QFont.Weight.Normal)
    return result


def color(name, alpha=None, painter=None):
    colors=COLORS
    if painter is not None:
        device=painter.device();owner=device.meter if hasattr(device,'meter') else device
        if hasattr(owner,'palette_colors'):colors=owner.palette_colors()
    result = QColor(colors.get(name, name))
    if alpha is not None:result.setAlpha(alpha)
    return result


def level(used):
    return 'idle' if used is None else ('critical' if used >= 90 else 'warning' if used >= 70 else 'ok')


def tightest(data):
    values = [float(row['used']) for row in data.get('quota', {}).get('windows', []) if row.get('used') is not None]
    return max(values) if values else None


def compact(value):
    if value is None:
        return '–'
    return f'{value / 1e6:.1f}M' if value >= 1e6 else (f'{value/1000:.0f}k' if value >= 1000 else str(value))


def reset_label(value,now=None):
    if not value:
        return ''
    try:
        deadline=float(value) if isinstance(value,(float,int)) else datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()
        remaining=max(0,int(deadline-(datetime.now().timestamp() if now is None else now)))
        days,hours=divmod(remaining//3600,24);minutes=(remaining%3600)//60
        if days:return f'{days}天 {hours}时'
        if hours:return f'{hours}时 {minutes}分'
        return f'{max(1,minutes)}分' if remaining else '重置中'
    except (ValueError, OSError):
        return ''


class Artwork:
    """AgentArtwork's original PNGs and exact brand tint, not replacement icons."""
    def __init__(self):
        self.images = {}
        for client, name, tint in [('Codex', 'chatgpt', '#10a37f'), ('Cursor', 'cursor', '#f5f5f7')]:
            image = QImage(str(DESIGN['resources'] / (name + '.png')))
            if image.isNull():
                raise RuntimeError('Upstream agent artwork missing: ' + name)
            image = image.scaled(128, 128, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
            p = QPainter(image)
            p.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceIn)
            p.fillRect(image.rect(), QColor(tint))
            p.end()
            self.images[client] = image

    def draw(self, painter, client, rect, opacity=1):
        painter.save()
        painter.setOpacity(painter.opacity() * opacity)
        image=self.images[client]
        device=painter.device();meter=device.meter if hasattr(device,'meter') else device
        if client=='Cursor' and hasattr(meter,'light') and meter.light() and not (device is meter and meter.settings.get('mode')=='notch'):
            image=image.copy();tint=QPainter(image);tint.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceIn)
            tint.fillRect(image.rect(),QColor('#1d1d1f'));tint.end()
        painter.drawImage(rect, image)
        painter.restore()


ARTWORK = None


def artwork():
    global ARTWORK
    if ARTWORK is None:
        ARTWORK = Artwork()
    return ARTWORK


def text(p, rect, value, size=13, ink='text', bold=False, align=Qt.AlignmentFlag.AlignLeft):
    p.setFont(font(size, bold))
    p.setPen(color(ink,painter=p))
    p.drawText(rect, align | Qt.AlignmentFlag.AlignVCenter, str(value))


def divider(p, y, width):
    p.setPen(QPen(color('divider',painter=p), 1))
    p.drawLine(QPointF(0, y), QPointF(width, y))


class SimpleMeterView(QWidget):
    """One separate SimpleMeterConfig item, with no glow (as upstream Simple)."""
    def __init__(self, client, screen, settings, menu_callback, preview=False):
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.Tool | Qt.WindowType.WindowStaysOnTopHint)
        self.client, self.screen, self.settings = client, screen, settings
        self.menu_callback, self.preview = menu_callback, preview
        self.data = dict(local=dict(sessions=[]), quota=dict(windows=[]))
        self.group_data={client:self.data}
        self._used={};self._reading_start={};self._reading_target={}
        self.reading_animation=QVariantAnimation(self);self.reading_animation.setDuration(300)
        self.reading_animation.setEasingCurve(QEasingCurve.Type.OutCubic)
        self.reading_animation.valueChanged.connect(self.reading_frame)
        self.cells=[]
        self.anchor = QPointF(0, 0)
        self.native_glass = False
        self.dragging=False
        self.press_position=None
        self.press_origin=None
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setMouseTracking(True)
        self.setWindowTitle('Agent HUD · ' + client)
        self.setAccessibleName(client + ' 额度')
        self.panel = HoverPanelView(self)
        self.peek = AgentPeekView(self)
        self.enter_timer = QTimer(self)
        self.enter_timer.setSingleShot(True)
        self.enter_timer.setInterval(220)
        self.enter_timer.timeout.connect(self.hover)
        self.leave_timer = QTimer(self)
        self.leave_timer.setSingleShot(True)
        self.leave_timer.setInterval(450)
        self.leave_timer.timeout.connect(self.maybe_close)
        self.alt_timer=QTimer(self);self.alt_timer.setInterval(50);self.alt_timer.timeout.connect(self.check_alt)
        self.edge_timer=QTimer(self);self.edge_timer.setInterval(50);self.edge_timer.timeout.connect(self.check_top_edge)
        from glow_view import GlowView
        self.glow=GlowView(self)
        self.refresh_size()

    def refresh_size(self):
        self.enter_timer.setInterval(round(self.settings.get('hover_delay',400)))
        self.leave_timer.setInterval(round(self.settings.get('collapse_delay',200)))
        if self.settings.get('immediate_top') and self.isVisible() and not self.preview:self.edge_timer.start()
        else:self.edge_timer.stop()
        size = self.settings['size']
        tight, loose = max(3, round(size*.18)), round(size*.45)
        label = '–' if tightest(self.data) is None else f'{tightest(self.data):.0f}%'
        self.label = label
        self.mark_size, self.left, self.top = size, tight+1, tight
        self.label_spacing = round(size*.23)
        self.figure_size = round(9*max(1, size/26))
        label_width = math.ceil(QFontMetricsF(font(self.figure_size)).horizontalAdvance(label))
        widths=[]
        for client,data in self.group_data.items():
            value=tightest(data);label='–' if value is None else f'{value:.0f}%'
            width=math.ceil(QFontMetricsF(font(self.figure_size)).horizontalAdvance(label))
            widths.append(self.left+size+(self.label_spacing+width if self.settings.get('show_numbers',True) else 0)+loose)
        mode=self.settings.get('mode','simple');horizontal=mode=='notch' or self.settings.get('edge','top') in ('top','bottom')
        self.cells=[]
        if mode=='simple':
            gap=round(size*self.settings.get('gap',.45));cursor=0
            for client,width in zip(self.group_data,widths):
                rect=QRectF(cursor,0,width,size+tight*2) if horizontal else QRectF(0,cursor,width,size+tight*2)
                self.cells.append((client,rect));cursor+=(width if horizontal else size+tight*2)+gap
            self.setFixedSize(round(cursor-gap) if horizontal else max(widths),size+tight*2 if horizontal else round(cursor-gap))
        else:
            logo=self.settings.get('logo_size',20);distance=self.settings.get('edge_distance',2)
            gap=round(logo*self.settings.get('logo_gap',.4));run=len(widths)*logo+max(0,len(widths)-1)*gap
            if mode=='notch':self.setFixedSize(int(DESIGN['notch_width']+2*DESIGN['flare']),24);distance=2;logo=min(20,logo);run=len(widths)*logo+max(0,len(widths)-1)*gap
            else:self.setFixedSize(round(run) if horizontal else round(logo+2*distance),round(logo+2*distance) if horizontal else round(run))
            for i,client in enumerate(self.group_data):
                along=i*(logo+gap)+(self.width()-run)/2 if horizontal or mode=='notch' else i*(logo+gap)
                rect=QRectF(along,distance,logo,logo) if horizontal or mode=='notch' else QRectF(distance,along,logo,logo)
                self.cells.append((client,rect))
        self.corner = min(round(size*.73), self.height()/2)
        self.round_mask()

    def round_mask(self):
        shape = self.surface_path()
        self.setMask(QRegion(shape.toFillPolygon().toPolygon()))
        if self.settings.get('mode','simple')=='simple' and self.isVisible():rounded_native_window(self,self.corner)

    def surface_path(self):
        shape=QPainterPath()
        if self.settings.get('mode')=='notch':
            w=self.width();h=self.height();top=DESIGN['flare'];bottom=DESIGN['notch_radius']
            shape.moveTo(0,0);shape.quadTo(top,0,top,top);shape.lineTo(top,h-bottom)
            shape.quadTo(top,h,top+bottom,h);shape.lineTo(w-top-bottom,h)
            shape.quadTo(w-top,h,w-top,h-bottom);shape.lineTo(w-top,top);shape.quadTo(w-top,0,w,0);shape.closeSubpath()
        else:shape.addRoundedRect(QRectF(self.rect()),self.corner,self.corner)
        return shape

    def apply_material(self):
        apply_widget_theme(self,self.light())
        glass=self.settings['glass'] and self.settings.get('mode','simple')=='simple'
        self.native_glass = not self.preview and glass and frosted_backdrop(self.winId(),True,self.settings.get('transparency',50),self.light(),self.settings.get('glass_style','material'))
        if not glass and not self.preview:
            frosted_backdrop(self.winId(), False)
        if self.panel.isVisible():self.panel.apply_material()
        if self.peek.isVisible():self.peek.apply_material()
        if self.settings.get('mode','simple')=='simple':rounded_native_window(self,self.corner)
        self.update()

    def light(self):
        appearance=self.settings.get('hud_appearance','dark')
        return resolves_light(appearance)

    def palette_colors(self):
        light=self.light()
        return {**DESIGN['colors'],**(DESIGN['light_colors'] if light else {}),
            **(dict(ok='#1f9d4c',warning='#c08000') if light else {}),
            'divider':'#14000000' if light else '#1affffff',
            'outline':'#1a000000' if light else '#24ffffff',
            'track':'#1a000000' if light else '#24ffffff'}

    def surface_fill(self,native):
        fill=QColor('#f5f5f7' if self.light() else '#000000')
        fill.setAlpha(18 if native else round(255*stand_in(self.settings.get('transparency',50),self.settings['glass'],self.settings.get('glass_style','material'))))
        return fill

    def set_data(self, data):
        self.data = data
        self.group_data={self.client:data}
        self.refresh_data()

    def set_group_data(self,data):
        self.group_data=data
        if self.client not in data:self.client=next(iter(data))
        self.data=data[self.client];self.refresh_data()

    def refresh_data(self):
        targets={client:tightest(data) for client,data in self.group_data.items()}
        if targets!=self._reading_target:
            self.reading_animation.stop();self._reading_start=dict(self._used);self._reading_target=targets
            if self.preview or not self.isVisible() or not animations_enabled():self._used=dict(targets)
            else:
                self.reading_animation.setStartValue(0.);self.reading_animation.setEndValue(1.);self.reading_animation.start()
        self.refresh_size()
        self.panel.set_data(self.data)
        self.peek.refresh()
        used = tightest(self.data)
        from quota_state import quota_notice
        quota=self.data.get('quota',{});state=quota_notice(quota,self.client)
        self.setToolTip(f'{self.client} · 已用 {used:.0f}%'+(' · '+state if state else '') if used is not None else f'{self.client} · {state}')
        self.update()

    def reading_frame(self,progress):
        self._used={client:(self._reading_start[client]+(target-self._reading_start[client])*float(progress)
                    if target is not None and self._reading_start.get(client) is not None else target)
                    for client,target in self._reading_target.items()}
        self.update()

    def place(self, x, y):
        self.move(int(x), int(y))
        self.anchor = QPointF(self.geometry().center().x(), self.geometry().bottom()+6)
        if self.panel.isVisible():
            self.panel.reposition()
        if self.peek.isVisible():self.peek.reposition()
        self.glow.sync()

    def paintEvent(self, event):
        self.palette_colors()
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        path = self.surface_path()
        # The dark glass stand-in is used only for an offscreen preview/fallback.
        fill = self.surface_fill(self.native_glass)
        mode=self.settings.get('mode','simple')
        if mode!='logos':
            p.fillPath(path,QColor('black') if mode=='notch' else fill)
            if mode!='notch':p.setPen(QPen(color('outline',painter=p),1));p.drawPath(path)
        for client,cell in self.cells:
            if mode!='simple':
                if self.settings.get('show_logos',True):artwork().draw(p,client,cell)
                continue
            p.save();p.translate(cell.topLeft())
            rect = QRectF(self.left, self.top, self.mark_size, self.mark_size)
            used = self._used.get(client,tightest(self.group_data[client]));width = self.settings['ring_width']
            ring = rect.adjusted(width/2,width/2,-width/2,-width/2)
            p.setPen(QPen(color('track',painter=p),width))
            if self.settings.get('show_rings',True):p.drawEllipse(ring)
            if used is not None and self.settings.get('show_rings',True):
                p.setPen(QPen(color(level(used),painter=p),width,Qt.PenStyle.SolidLine,Qt.PenCapStyle.RoundCap))
                p.drawArc(ring,90*16,-round(min(100,max(0,used))*3.6*16))
            logo = round(self.mark_size*.55)
            artwork().draw(p,client,QRectF(rect.center().x()-logo/2,rect.center().y()-logo/2,logo,logo))
            label_rect = QRectF(rect.right()+self.label_spacing,0,cell.width()-rect.right()-self.label_spacing-round(self.mark_size*.45),cell.height())
            label='–' if used is None else f'{used:.0f}%'
            if self.settings.get('show_numbers',True):text(p,label_rect,label,self.figure_size,level(used),align=Qt.AlignmentFlag.AlignRight)
            p.restore()
        p.end()

    def enterEvent(self, event):
        if self.preview and not self.isWindow():return
        self.leave_timer.stop()
        if not self.dragging:
            if self.settings.get('requires_alt'):
                if not self.preview:self.alt_timer.start()
                self.check_alt()
            else:self.enter_timer.start()

    def showEvent(self,event):
        super().showEvent(event)
        if self.settings.get('immediate_top') and not self.preview:self.edge_timer.start()

    def check_alt(self):
        if self.underMouse() and QApplication.queryKeyboardModifiers() & Qt.KeyboardModifier.AltModifier:
            self.hover();self.alt_timer.stop()

    def check_top_edge(self):
        point=QCursor.pos();rect=self.geometry();screen=self.screen.geometry()
        if self.settings.get('edge','top')=='top' and rect.left()<=point.x()<=rect.right() and screen.top()<=point.y()<=screen.top()+1 and not self.panel.isVisible() and not self.dragging:
            self.hover()

    def select_at(self,point):
        for client,rect in self.cells:
            if rect.contains(point) and client!=self.client:
                self.client=client;self.data=self.group_data[client];self.panel.set_data(self.data)
                if self.peek.isVisible():self.peek.refresh();self.peek.reposition()
                break

    def leaveEvent(self, event):
        self.alt_timer.stop()
        self.enter_timer.stop()
        self.leave_timer.start()

    def open_panel(self):
        origin=self.geometry().united(self.peek.geometry()) if self.peek.isVisible() else self.geometry()
        self.peek.dismiss(immediate=True)
        if not self.panel.isVisible():self.panel.source_rect=origin
        self.panel.open()

    def hover(self):
        if self.panel.pinned:return
        if self.settings.get('requires_alt') and not QApplication.queryKeyboardModifiers() & Qt.KeyboardModifier.AltModifier:return
        if self.settings.get('mode','simple') in ('simple','logos'):self.peek.open()
        else:self.open_panel()

    def maybe_close(self):
        if not self.underMouse() and not self.peek.underMouse() and not self.panel.underMouse() and not self.panel.pinned:
            self.peek.dismiss();self.panel.collapse()

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.RightButton:
            self.menu_callback(event.globalPosition().toPoint())
        elif event.button() == Qt.MouseButton.LeftButton:
            self.select_at(event.position())
            horizontal=self.settings.get('edge','top') in ('top','bottom')
            self.grab_fraction=event.position().x()/max(1,self.width()) if horizontal else event.position().y()/max(1,self.height())
            self.press_position=event.globalPosition().toPoint()
            self.press_origin=self.pos()
            self.enter_timer.stop()

    def mouseMoveEvent(self,event):
        if self.press_position is None:self.select_at(event.position());return
        delta=event.globalPosition().toPoint()-self.press_position
        if not self.dragging and delta.manhattanLength() < QApplication.startDragDistance():return
        self.dragging=True
        self.leave_timer.stop();self.enter_timer.stop()
        self.panel.pinned=False;self.panel.hide()
        self.panel.animation.stop();self.peek.dismiss(immediate=True)
        self.glow.hide()
        self.move(self.press_origin+delta)

    def mouseReleaseEvent(self,event):
        if event.button()!=Qt.MouseButton.LeftButton or self.press_position is None:return
        dragged=self.dragging
        self.dragging=False;self.press_position=None
        if dragged:
            if hasattr(self,'placement_callback'):self.placement_callback(self,event.globalPosition().toPoint())
        else:
            self.panel.pinned = not self.panel.pinned
            self.open_panel() if self.panel.pinned else self.panel.collapse()

    def hide_all(self):
        self.reading_animation.stop()
        self.panel.animation.stop()
        self.peek.dismiss(immediate=True)
        self.alt_timer.stop();self.edge_timer.stop()
        self.glow.hide();self.glow.timer.stop()
        self.panel.pinned = False
        self.panel.hide()
        self.hide()


class HoverPanelView(QWidget):
    """HoverPanelView's provider block -> token chart -> session list -> footer."""
    def __init__(self, meter):
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.Tool | Qt.WindowType.WindowStaysOnTopHint)
        self.meter = meter
        self.data = meter.data
        self.setWindowTitle('Agent HUD · '+meter.client+' · 面板')
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setMouseTracking(True)
        self.pinned = False
        self.progress = 0.
        self.native_glass = False
        self.hits = []
        self.animation = SpringDriver(self,frequency=1520/DESIGN['animation_ms'])
        self.animation.valueChanged.connect(self.animate)
        self.animation.finished.connect(self.finished)
        self.setFixedSize(int(DESIGN['agent_width']),300)

    def set_data(self,data):
        self.data=data
        if self.isVisible() and self.progress > .99:
            self.animate(1.)
        self.update()

    def layout_height(self):
        rows=max(1,len(self.data.get('quota',{}).get('windows',[])[:5]))
        sessions=self.data.get('local',{}).get('sessions',[])[:int(self.meter.settings.get('session_limit',5))]
        cfg=self.meter.settings
        return 14+(43+rows*28+18 if cfg.get('panel_quota',True) else 0)+(92+18 if cfg.get('panel_tokens',True) else 0)+(22+max(1,len(sessions))*25+18 if cfg.get('panel_sessions',True) else 0)+17+28+14

    def reposition(self):
        screen=self.meter.screen.availableGeometry()
        edge='top' if self.meter.settings.get('mode')=='notch' else self.meter.settings.get('edge','top')
        geom=self.meter.geometry()
        width=self.content_width();height=self.layout_height()
        x=geom.center().x()-width/2
        y=geom.bottom()+6
        if edge=='bottom':y=geom.top()-height-6
        elif edge=='left':x=geom.right()+6;y=geom.center().y()-height/2
        elif edge=='right':x=geom.left()-width-6;y=geom.center().y()-height/2
        x=max(screen.left()+6,min(x,screen.right()-width-6))
        y=max(screen.top()+3,min(y,screen.bottom()-height-3))
        origin=getattr(self,'source_rect',geom)
        self.move(round(origin.x()+(x-origin.x())*self.progress),round(origin.y()+(y-origin.y())*self.progress))

    def open(self):
        self.animate(self.progress)
        self.show()
        self.reposition()
        self.apply_material()
        self.animation.retarget(1.)

    def apply_material(self):
        apply_widget_theme(self,self.meter.light())
        cfg=self.meter.settings
        self.native_glass=not self.meter.preview and cfg['glass'] and frosted_backdrop(self.winId(),True,cfg.get('transparency',50),self.meter.light(),cfg.get('glass_style','material'))
        if not cfg['glass'] and not self.meter.preview:frosted_backdrop(self.winId(),False)
        rounded_native_window(self,getattr(self,'corner',16))
        self.update()

    def collapse(self):
        self.animation.retarget(0.)

    def animate(self,value):
        self.progress=max(0,min(1,float(value)))
        # Grow the shell in both dimensions; keep content at its final width to
        # avoid line wrapping and chart reflow during the source's 400ms curve.
        target=self.content_width()
        origin=getattr(self,'source_rect',self.meter.geometry())
        start=min(target,max(1,origin.width()));start_height=origin.height()
        self.setFixedSize(round(start+(target-start)*self.progress),max(1,round(start_height+(self.layout_height()-start_height)*self.progress)))
        self.corner=self.meter.corner+(16-self.meter.corner)*self.progress
        self.reposition()
        shape=QPainterPath()
        shape.addRoundedRect(QRectF(self.rect()),self.corner,self.corner)
        self.setMask(QRegion(shape.toFillPolygon().toPolygon()))
        if self.isVisible():rounded_native_window(self,self.corner)
        self.update()

    def content_width(self):
        return min(int(self.meter.settings.get('panel_width',540)-100),self.meter.screen.availableGeometry().width()-16)

    def finished(self):
        if self.progress < .01:
            self.hide()

    def enterEvent(self,event):
        self.meter.leave_timer.stop()

    def leaveEvent(self,event):
        self.meter.leave_timer.start()

    def paintEvent(self,event):
        self.meter.palette_colors()
        p=QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        shell_alpha=min(1,max(0,self.progress*4))
        p.setOpacity(shell_alpha)
        path=QPainterPath()
        radius=getattr(self,'corner',16)
        path.addRoundedRect(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5),radius,radius)
        fill=self.meter.surface_fill(self.native_glass)
        p.fillPath(path,fill)
        p.setPen(QPen(color('outline',painter=p),1))
        p.drawPath(path)
        p.setClipPath(path)
        phase=min(1,max(0,(self.progress-.1)/.9))
        p.setOpacity(phase*phase*(3-2*phase))
        p.translate(18+(self.width()-self.content_width())/2,14+6*(1-self.progress))
        w=self.content_width()-36
        self.hits=[]
        y=0
        for key,block in [('panel_quota',lambda:self.provider_block(p,w)),('panel_tokens',lambda:self.token_block(p,y,w)),('panel_sessions',lambda:self.sessions_block(p,y,w))]:
            if self.meter.settings.get(key,True):
                y=block();divider(p,y+8,w);y+=18
        y+=17
        self.gear(p,QPointF(14,y+14))
        text(p,QRectF(40,y,w-80,28),'已用额度 · 仅当前客户端',10,'tertiary',align=Qt.AlignmentFlag.AlignCenter)
        self.chart_icon(p,QPointF(w-14,y+14))
        self.hits.append((QRectF(0,y,30,28),'settings'))
        self.hits.append((QRectF(w-30,y,30,28),'details'))
        p.end()

    def provider_block(self,p,w):
        artwork().draw(p,self.meter.client,QRectF(6,2,14,14))
        text(p,QRectF(26,0,w-100,20),self.meter.client,13,'text',True)
        text(p,QRectF(w-64,0,64,20),'%',10,'secondary',align=Qt.AlignmentFlag.AlignRight)
        text(p,QRectF(6,23,w/2,15),'个人账户',10,'secondary')
        text(p,QRectF(w/2,23,w/2-6,15),'上次读数 · 重试中' if self.data.get('quota',{}).get('stale') else '当前账户',10,'tertiary',align=Qt.AlignmentFlag.AlignRight)
        y=43
        rows=self.data.get('quota',{}).get('windows',[])[:5]
        if not rows:
            from quota_state import quota_notice
            notice=quota_notice(self.data.get('quota',{}),self.meter.client)
            fm=QFontMetricsF(font(11))
            text(p,QRectF(6,y,w-12,28),fm.elidedText(notice,Qt.TextElideMode.ElideRight,w-12),11,'secondary')
            return y+28
        for row in rows:
            used=float(row['used']);ink=level(used)
            p.setPen(Qt.PenStyle.NoPen);p.setBrush(color(ink,painter=p))
            p.drawEllipse(QPointF(10,y+14),4,4)
            label={'Weekly':'每周限额','5-hour':'5 小时限额','Included':'包含用量'}.get(row['label'],row['label'])
            text(p,QRectF(26,y,DESIGN['label_width'],28),label,13,'text',True)
            start=26+DESIGN['label_width']+12;bar_w=w-start-130
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(color('track',painter=p))
            p.drawRoundedRect(QRectF(start,y+12,bar_w,4),2,2)
            p.setBrush(color(ink,painter=p))
            p.drawRoundedRect(QRectF(start,y+12,bar_w*max(0,min(1,used/100)),4),2,2)
            text(p,QRectF(start+bar_w+8,y,45,28),f'{used:.0f}%',12,ink,True,Qt.AlignmentFlag.AlignRight)
            if self.meter.settings.get('reset_countdown',True):text(p,QRectF(w-76,y,70,28),reset_label(row.get('reset')),10,'secondary',align=Qt.AlignmentFlag.AlignRight)
            y+=28
        return y

    def token_block(self,p,y,w):
        text(p,QRectF(0,y,100,20),'Tokens',13,'text',True)
        text(p,QRectF(100,y,w-100,20),'最近会话 · 各会话累计',10,'secondary',align=Qt.AlignmentFlag.AlignRight)
        items=[r for r in self.data.get('local',{}).get('sessions',[]) if r.get('tokens') is not None][:12]
        chart_y=y+27
        if not items:
            text(p,QRectF(6,chart_y,w-12,55),'暂无可读取的 Token 记录',11,'tertiary')
        else:
            maximum=max(1,max(row['tokens'] for row in items))
            gap=5;bw=min(24,(w-12-(len(items)-1)*gap)/len(items))
            for index,row in enumerate(reversed(items)):
                x=6+index*(bw+gap);height=55*row['tokens']/maximum
                breakdown=row.get('breakdown') or {}
                parts=[(breakdown.get('cache',0),'#b098df'),(breakdown.get('input',0),'#69a9e9'),
                       (breakdown.get('reasoning',0),'#de86af'),(breakdown.get('output',0),'#e99d52')]
                if not any(n for n,_ in parts):parts=[(row['tokens'],'#b098df')]
                total=max(1,sum(n for n,_ in parts));bottom=chart_y+55
                for amount,tint in parts:
                    part=height*amount/total;bottom-=part
                    p.fillRect(QRectF(x,bottom,bw,max(0,part)),QColor(tint))
                self.hits.append((QRectF(x,chart_y,bw,55),row))
            p.setPen(QPen(color('divider',painter=p),1))
            p.drawLine(QPointF(6,chart_y+56),QPointF(w-6,chart_y+56))
        return chart_y+65

    def sessions_block(self,p,y,w):
        items=self.data.get('local',{}).get('sessions',[])
        running=sum(row['state']=='running' for row in items)
        text(p,QRectF(0,y,90,20),'会话',13,'text',True)
        text(p,QRectF(100,y,w-100,20),f'{running} 个运行中' if running else '最近会话',12,'secondary',align=Qt.AlignmentFlag.AlignRight)
        y+=22
        if not items:
            text(p,QRectF(6,y,w-12,25),'等待新会话',11,'tertiary')
            return y+25
        fm=QFontMetricsF(font(12))
        for row in items[:int(self.meter.settings.get('session_limit',5))]:
            artwork().draw(p,self.meter.client,QRectF(1,y+5,14,14),.7 if row['state']!='running' else 1)
            p.setPen(QPen(self.meter.surface_fill(False),2));p.setBrush(color('ok' if row['state']=='running' else 'tertiary',painter=p))
            p.drawEllipse(QPointF(15,y+18),3,3)
            name=fm.elidedText(row['title'],Qt.TextElideMode.ElideRight,w-94)
            text(p,QRectF(22,y,w-94,25),name,12,'secondary')
            text(p,QRectF(w-65,y,65,25),compact(row.get('tokens'))+' tok' if row.get('tokens') is not None else '–',11,'secondary',align=Qt.AlignmentFlag.AlignRight)
            self.hits.append((QRectF(0,y,w,25),row));y+=25
        return y

    def gear(self,p,center):
        p.save();p.translate(center);p.setPen(QPen(color('secondary',painter=p),1.3))
        p.setBrush(Qt.BrushStyle.NoBrush);p.drawEllipse(QPointF(0,0),5,5);p.drawEllipse(QPointF(0,0),1.8,1.8)
        for i in range(8):
            p.rotate(45);p.drawLine(QPointF(0,-5),QPointF(0,-7))
        p.restore()

    def chart_icon(self,p,center):
        p.setPen(Qt.PenStyle.NoPen);p.setBrush(color('secondary',painter=p))
        for x,h in [(-6,5),(-1,11),(4,8)]:p.drawRoundedRect(QRectF(center.x()+x,center.y()+6-h,3,h),.7,.7)

    def mousePressEvent(self,event):
        if event.button()==Qt.MouseButton.RightButton:
            self.meter.menu_callback(event.globalPosition().toPoint());return
        if self.progress<.98:return
        point=event.position()-QPointF(18,14)
        for rect,action in reversed(self.hits):
            if rect.contains(point):
                if action=='settings':
                    if hasattr(self.meter,'settings_callback'):self.meter.settings_callback()
                    else:self.meter.menu_callback(event.globalPosition().toPoint())
                elif action=='details' and hasattr(self.meter,'usage_callback'):
                    self.pinned=True
                    self.meter.usage_callback(self.meter.client,self.data)
                elif isinstance(action,dict):
                    from PySide6.QtWidgets import QMessageBox
                    self.pinned=True
                    label={'running':'运行中','done':'已结束','stopped':'已停止','error':'异常','unknown':'最后记录'}
                    QMessageBox.information(self,'会话',action['title']+'\n\n'+label.get(action['state'],'最后记录')+'\n会话累计 Tokens: '+compact(action.get('tokens')))
                break
