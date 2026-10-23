"""Qt counterparts of SimpleMeterView and the SwiftUI HoverPanelView tree.

Palette, geometry and timing come from source_design (the original Swift files).
The Windows layer supplies native glass, font substitution, windows and painting.
"""
from datetime import datetime
import math

from PySide6.QtCore import Qt, QRect, QRectF, QPointF, QSize, QTimer, QVariantAnimation, QEasingCurve, QEvent
from PySide6.QtGui import QColor, QFont, QFontMetricsF, QImage, QPainter, QPainterPath, QPen, QPixmap, QRegion,QCursor
from PySide6.QtWidgets import QWidget, QMenu, QApplication

from material import frosted_backdrop,rounded_native_window,PanelFrost
from source_design import DESIGN
from look_logic import stand_in,dimming
from theme import resolves_light,apply_widget_theme
from motion import SpringDriver,SourceCurveDriver,animations_enabled
from peek_view import AgentPeekView
from surface_shape import surface_path

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
    from quota_insights import number
    values = [value for row in data.get('quota', {}).get('windows', []) if (value:=number(row.get('used'))) is not None]
    return max(values) if values else None


_UNSET=object()
def meter_label(client,data,used=_UNSET):
    if used is _UNSET:used=tightest(data)
    if used is not None:return f'{used:.0f}%',level(used)
    if client=='DeepSeek':
        from balance_display import balance_lines
        balances=balance_lines(client,data.get('quota',{}),include_empty=True)
        if balances:return balances[0]['value'],balances[0]['ink']
        return '–','secondary'
    return '–',level(None)


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
        import re
        self.images = {}
        catalog=(DESIGN['resources'].parent/'Components/AgentLogo.swift').read_text(encoding='utf-8').split('// A mark')[0]
        names=dict(re.findall(r'"([^"]+)": "([^"]+)"',catalog));names['Codex']='chatgpt'
        for client,name in names.items():
            image = QImage(str(DESIGN['resources'] / (name + '.png')))
            if image.isNull():
                raise RuntimeError('Upstream agent artwork missing: ' + name)
            image = image.scaled(128, 128, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
            if name=='chatgpt':
                p=QPainter(image);p.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceIn);p.fillRect(image.rect(),QColor('#10a37f'));p.end()
            self.images[client] = image

    def draw(self, painter, client, rect, opacity=1,light=None):
        painter.save()
        painter.setOpacity(painter.opacity() * opacity)
        device=painter.device();meter=device.meter if hasattr(device,'meter') else device
        if light is None:light=hasattr(meter,'light') and meter.light() and not (device is meter and meter.settings.get('mode')=='notch')
        key=client+'-dark' if client in ('OpenCode','Qoder') and not light else client
        image=self.images.get(key)
        if image is None:
            painter.setPen(QColor('#1d1d1f' if light else '#f5f5f7'));painter.drawText(rect,Qt.AlignmentFlag.AlignCenter,client[:1]);painter.restore();return
        if client in ('Grok','Cursor','Kimi','Pi','GitHub Copilot','Hermes','ZCode'):
            image=image.copy();tint=QPainter(image);tint.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceIn)
            tint.fillRect(image.rect(),QColor('#1d1d1f' if light else '#f5f5f7'));tint.end()
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
    p.setPen(color(ink+'Text' if ink in ('ok','warning','critical','idle') else ink,painter=p))
    vertical=Qt.AlignmentFlag.AlignTop|Qt.AlignmentFlag.AlignBottom|Qt.AlignmentFlag.AlignVCenter|Qt.AlignmentFlag.AlignBaseline
    p.drawText(rect,align if align & vertical else align|Qt.AlignmentFlag.AlignVCenter,str(value))


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
        self.frost=PanelFrost()
        self.attention_events=[];self.selected_attention=None;self.retiring_attention=None;self._suspending=False
        self.attention_navigation_failed=set()
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
        from bot_player import BotPlayer
        self.bots=BotPlayer(self)
        self.refresh_size()

    def refresh_size(self):
        mode=self.settings.get('mode','simple')
        placement=(mode,self.settings.get('edge','top'))
        if getattr(self,'_previous_placement',placement)!=placement:
            self._suspending=True
            self.peek.dismiss(immediate=True);self.panel.pinned=False;self.panel.animation.jump(0.);self.panel.hide()
            self.glow.hide();self.glow.timer.stop()
            self.frost.clear()
            self._suspending=False
        self._previous_placement=placement
        self._previous_mode=mode
        self.enter_timer.setInterval(round(self.settings.get('hover_delay',400)))
        self.leave_timer.setInterval(round(self.settings.get('collapse_delay',200)))
        if self.settings.get('immediate_top') and self.isVisible() and not self.preview:self.edge_timer.start()
        else:self.edge_timer.stop()
        size = self.settings['size']
        tight, loose = max(3, round(size*.18)), round(size*.45)
        label = meter_label(self.client,self.data)[0]
        self.label = label
        self.mark_size, self.left, self.top = size, tight+1, tight
        self.label_spacing = round(size*.23)
        self.figure_size = round(9*max(1, size/26))
        label_width = math.ceil(QFontMetricsF(font(self.figure_size)).horizontalAdvance(label))
        widths=[]
        for client,data in self.group_data.items():
            label=meter_label(client,data)[0]
            width=math.ceil(QFontMetricsF(font(self.figure_size)).horizontalAdvance(label))
            widths.append(self.left+size+(self.label_spacing+width if self.settings.get('show_numbers',True) else 0)+loose)
        mode=self.settings.get('mode','simple');horizontal=mode=='notch' or self.settings.get('edge','top') in ('top','bottom')
        self.cells=[]
        if mode=='simple':
            from simple_geometry import simple_geometry
            labels=[math.ceil(QFontMetricsF(font(self.figure_size)).horizontalAdvance(meter_label(client,data)[0])) for client,data in self.group_data.items()]
            geometry=simple_geometry(size,self.settings.get('edge','top'),self.settings.get('show_rings',True),self.settings.get('show_numbers',True),self.settings.get('gap',.45),labels)
            self.simple_geometry=geometry;self.mark_size=geometry['mark'];self.logo_size=geometry['logo'];self.label_spacing=geometry['spacing']
            self.cells=[(client,QRectF(*rect)) for client,rect in zip(self.group_data,geometry['cells'])]
            self.setFixedSize(geometry['width'],geometry['height'])
        else:
            logo=self.settings.get('logo_size',20);distance=self.settings.get('edge_distance',2)
            gap=round(logo*self.settings.get('logo_gap',.4));run=len(widths)*logo+max(0,len(widths)-1)*gap
            if mode=='notch':self.setFixedSize(int(DESIGN['notch_width']+2*DESIGN['flare']),24);distance=2;logo=min(20,logo);run=len(widths)*logo+max(0,len(widths)-1)*gap
            else:self.setFixedSize(round(run) if horizontal else round(logo+2*distance),round(logo+2*distance) if horizontal else round(run))
            for i,client in enumerate(self.group_data):
                along=i*(logo+gap)+(self.width()-run)/2 if horizontal or mode=='notch' else i*(logo+gap)
                rect=QRectF(along,distance,logo,logo) if horizontal or mode=='notch' else QRectF(distance,along,logo,logo)
                self.cells.append((client,rect))
        self.corner = geometry['corner'] if mode=='simple' else min(round(size*.73),min(self.width(),self.height())/2)
        self.round_mask()

    def round_mask(self):
        if self.settings.get('mode')=='logos':
            # A bare logo queue has no capsule silhouette. Applying the Simple
            # rounded mask shaved the outside agents' artwork on side docks.
            self.clearMask()
            return
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
        else:shape=surface_path(self.rect(),self.corner)
        return shape

    def apply_material(self):
        apply_widget_theme(self,self.light())
        glass=self.settings['glass'] and self.settings.get('mode','simple')=='simple'
        self.native_glass=False
        if not self.preview:frosted_backdrop(self.winId(),False)
        if not glass:self.frost.clear()
        elif self.frost.image is None and self.isVisible() and not self.preview and not self.panel.isVisible() and not self.peek.isVisible():
            # A newly enabled glass look must not sample its own opaque/tinted
            # surface. This runs on a look change, never on an idle paint timer.
            self.hide();self.show()
        if self.panel.isVisible():self.panel.apply_material()
        if self.peek.isVisible():self.peek.apply_material()
        if self.settings.get('mode','simple')=='simple':rounded_native_window(self,self.corner)
        self.update()

    def light(self):
        appearance=self.settings.get('hud_appearance','dark')
        return resolves_light(appearance)

    def palette_colors(self):
        light=self.light();key=(light,self.settings['glass'],self.settings.get('transparency',0)>0)
        if getattr(self,'_palette_key',None)==key:return self._palette_value
        status=DESIGN['status_colors'];see_through=self.settings['glass'] or self.settings.get('transparency',0)>0
        fill={key:status[{'ok':'okHUDLight','warning':'warningHUDLight','critical':'criticalLight'}[key]] if light else status[key] for key in ('ok','warning','critical')}
        inks={key+'Text':DESIGN['glass_text'][key+('Light' if light else 'Dark')] if see_through else status[{'ok':'okTextHUDLight','warning':'warningTextHUDLight','critical':'criticalTextHUDLight'}[key]] if light else status[key] for key in ('ok','warning','critical')}
        palette={**DESIGN['colors'],**(DESIGN['light_colors'] if light else {}),
            **fill,**inks,'idleText':status['idleTextLight' if light else 'idle'],
            'divider':'#14000000' if light else '#1affffff',
            'outline':'#1a000000' if light else '#24ffffff',
            'track':'#1a000000' if light else '#24ffffff'}
        if see_through:
            values=('true' if light else 'false','true','true' if self.settings['glass'] else 'false')
            entry=next(row for key,row in DESIGN['see_through_greys'].items() if all(asked==actual or asked=='_' for asked,actual in zip(key.split(','),values)))
            for name in ('secondary','tertiary','idle'):
                ink=QColor('black' if light else 'white');ink.setAlpha(round(entry[name]*255));palette[name]=ink.name(QColor.NameFormat.HexArgb)
            palette['idleText']=palette['secondary']
        self._palette_key=key;self._palette_value=palette
        return palette

    def surface_fill(self,native):
        fill=QColor('#f5f5f7' if self.light() else '#000000')
        opacity=dimming(self.settings.get('transparency',50),True,self.settings.get('glass_style','material')) if native else stand_in(self.settings.get('transparency',50),self.settings['glass'],self.settings.get('glass_style','material'))
        fill.setAlpha(round(255*opacity))
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
        self.bots.sync()
        used = tightest(self.data)
        from quota_state import quota_notice
        quota=self.data.get('quota',{});state=quota_notice(quota,self.client)
        self.setToolTip(f'{self.client} · 已用 {used:.0f}%'+(' · '+state if state else '') if used is not None else f'{self.client} · {state}')
        if self.client=='DeepSeek':self.setToolTip(self.client+' · 余额 '+meter_label(self.client,self.data)[0]+(' · '+state if state else ''))
        self.update()

    def reading_frame(self,progress):
        self._used={client:(self._reading_start[client]+(target-self._reading_start[client])*float(progress)
                    if target is not None and self._reading_start.get(client) is not None else target)
                    for client,target in self._reading_target.items()}
        self.update()

    def place(self, x, y):
        from PySide6.QtCore import QPoint
        target=QRect(QPoint(int(x),int(y)),self.size())
        recapture=self.isVisible() and not self.preview and not self.dragging and not self.frost.covers(target) and self.settings.get('mode')=='simple' and self.settings['glass']
        if recapture:self.hide()
        self.move(int(x), int(y))
        if recapture:self.show()
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
        mode=self.settings.get('mode','simple')
        if mode!='logos':
            sampled=mode=='simple' and self.frost.paint(p,self,path)
            fill=self.surface_fill(sampled)
            p.fillPath(path,QColor('black') if mode=='notch' else fill)
            if mode!='notch' and (not sampled or self.settings.get('glass_style')=='material'):
                p.setPen(QPen(color('outline',painter=p),1));p.drawPath(path)
        for client,cell in self.cells:
            if mode!='simple':
                if self.settings.get('show_logos',True) and not self.bots.draw(p,client,cell):artwork().draw(p,client,cell)
                continue
            p.save();p.translate(cell.topLeft())
            rect = QRectF(0,0,self.mark_size,self.mark_size)
            used = self._used.get(client,tightest(self.group_data[client]));width = self.settings['ring_width']
            ring = rect.adjusted(width/2,width/2,-width/2,-width/2)
            p.setPen(QPen(color('track',painter=p),width))
            if self.settings.get('show_rings',True):p.drawEllipse(ring)
            if used is not None and self.settings.get('show_rings',True):
                p.setPen(QPen(color(level(used),painter=p),width,Qt.PenStyle.SolidLine,Qt.PenCapStyle.RoundCap))
                p.drawArc(ring,90*16,-round(min(100,max(0,used))*3.6*16))
            logo = self.logo_size
            logo_rect=QRectF(rect.center().x()-logo/2,rect.center().y()-logo/2,logo,logo)
            if not self.bots.draw(p,client,logo_rect):artwork().draw(p,client,logo_rect)
            label_rect = QRectF(rect.right()+self.label_spacing,0,max(0,cell.width()-rect.right()-self.label_spacing),cell.height())
            label,ink=meter_label(client,self.group_data[client],used)
            if self.settings.get('show_numbers',True):text(p,label_rect,label,self.figure_size,ink,align=Qt.AlignmentFlag.AlignRight)
            p.restore()
        p.end()

    def enterEvent(self, event):
        if self.preview and not self.isWindow():return
        self.select_at(QPointF(self.mapFromGlobal(QCursor.pos())))
        self.leave_timer.stop()
        if not self.dragging:
            if self.settings.get('requires_alt'):
                if not self.preview:self.alt_timer.start()
                self.check_alt()
            else:self.enter_timer.start()

    def show(self):
        if not self.isVisible() and not self.preview and self.settings['glass'] and self.settings.get('mode')=='simple':
            bounds=QRect(self.geometry());screen=self.screen.geometry()
            # Cache the strip's travel axis so changes in agent count or label
            # width don't expose the end of a previously smaller snapshot.
            if self.settings.get('edge') in ('top','bottom'):
                bounds.setLeft(screen.left());bounds.setRight(screen.right())
            else:bounds.setTop(screen.top());bounds.setBottom(screen.bottom())
            self.frost.capture(self.screen,bounds)
        super().show()

    def showEvent(self,event):
        super().showEvent(event)
        self.bots.sync()
        if self.settings.get('immediate_top') and not self.preview:self.edge_timer.start()

    def hideEvent(self,event):
        self._suspending=True
        self.bots.stop()
        self.enter_timer.stop();self.leave_timer.stop()
        self.peek.dismiss(immediate=True)
        self.panel.pinned=False;self.panel.animation.jump(0.)
        self.glow.hide();self.glow.timer.stop()
        self.frost.clear()
        self._suspending=False
        super().hideEvent(event)

    def attention_event(self):
        selected=next((row for row in self.attention_events if row['id']==self.selected_attention),None)
        return selected or next((row for row in self.attention_events if row['kind']=='permission'),None) or next(iter(self.attention_events),None) or self.retiring_attention

    def set_attention(self,events):
        previous=self.attention_event();identifiers=tuple(row['id'] for row in self.attention_events)
        self.attention_events=list(events)
        active={row['id'] for row in events}
        for dialog in tuple(getattr(self,'attention_dialogs',[])):
            if dialog.property('attention_id') not in active:dialog.reject()
        changed=identifiers!=tuple(row['id'] for row in events)
        if not events and previous and self.panel.isVisible():
            self.retiring_attention=previous;self.panel.collapse()
        elif events:
            self.retiring_attention=None
            event=self.attention_event()
            if changed and event['vendor'] in self.group_data:
                self.client=event['vendor'];self.data=self.group_data[self.client];self.panel.data=self.data
            if self.panel.isVisible():self.panel.animate(self.panel.progress)
            else:self.show_reminder()
        elif changed:self.peek.dismiss(immediate=True)
        if changed:self.bots.sync();self.panel.reminder.sync()
        self.update();self.panel.update()

    def show_reminder(self):
        if self.isVisible() and self.attention_events and not self._suspending and not self.panel.isVisible():
            if not self.peek.isVisible():self.peek.open()
            else:self.peek.refresh();self.peek.reposition()

    def check_alt(self):
        if self.underMouse() and QApplication.queryKeyboardModifiers() & Qt.KeyboardModifier.AltModifier:
            self.hover();self.alt_timer.stop()

    def check_top_edge(self):
        point=QCursor.pos();rect=self.geometry();screen=self.screen.geometry()
        if self.settings.get('edge','top')=='top' and rect.left()<=point.x()<=rect.right() and screen.top()<=point.y()<=screen.top()+1 and not self.panel.isVisible() and not self.dragging:
            self.hover()

    def select_at(self,point):
        if self.panel.pinned:return
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
        self.enter_timer.stop();self.leave_timer.stop()
        origin=self.geometry().united(self.peek.geometry()) if self.peek.isVisible() else self.geometry()
        self.peek.dismiss(immediate=True)
        if not self.panel.isVisible():self.panel.source_rect=origin
        self.panel.open()

    def hover(self):
        if not self.isVisible() or self.dragging:return
        if self.panel.pinned:return
        if self.settings.get('requires_alt') and not QApplication.queryKeyboardModifiers() & Qt.KeyboardModifier.AltModifier:return
        if self.attention_events:self.open_panel()
        elif self.settings.get('mode','simple') in ('simple','logos') and self.settings.get('separates_agents',True):self.peek.open()
        else:self.open_panel()

    def maybe_close(self):
        if not self.underMouse() and not self.peek.underMouse() and not self.panel.underMouse():
            if not self.attention_events:self.peek.dismiss()
            self.panel.collapse()

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
        self.frost.clear()
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
        self._suspending=True
        self.enter_timer.stop();self.leave_timer.stop()
        self.reading_animation.stop()
        self.panel.animation.jump(0.)
        self.peek.dismiss(immediate=True)
        self.alt_timer.stop();self.edge_timer.stop()
        self.glow.hide();self.glow.timer.stop()
        self.panel.pinned = False
        self.panel.hide()
        self.hide()
        self._suspending=False


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
        self.frost=PanelFrost()
        self.hits = []
        self.scroll_offset=0.
        self.metric_selection={}
        self.animation = SourceCurveDriver(self,duration=DESIGN['animation_ms']/1000)
        self.animation.valueChanged.connect(self.animate)
        self.animation.finished.connect(self.finished)
        self.resize(int(DESIGN['agent_width']),300)
        from bot_player import ReminderPlayer
        self.reminder=ReminderPlayer(self)
        from layout_draft_bar import LayoutDraftBar
        self.draft_bar=LayoutDraftBar(self)

    def showEvent(self,event):
        super().showEvent(event);self.reminder.sync()

    def hideEvent(self,event):
        self.reminder.stop();super().hideEvent(event)

    def set_data(self,data):
        self.data=data
        if self.isVisible() and self.progress > .99:
            self.animate(1.)
        self.draft_bar.sync()
        self.update()

    def layout(self):
        store=getattr(self.meter,'layout_store',None)
        from panel_layout import legacy_layout
        key=(id(store),store.revision,self.meter.screen.name()) if store is not None else tuple(self.meter.settings.get(name) for name in ('panel_width','session_limit','panel_quota','panel_tokens','panel_sessions','reset_countdown'))
        if getattr(self,'_layout_key',None)!=key:
            self._layout_value=store.effective(self.meter.screen.name()) if store is not None else legacy_layout(self.meter.settings)
            self._layout_key=key
        return self._layout_value

    def section_order(self):
        layout=self.layout();order=layout.get('sections',['blocks','tokens','sessions'])
        return [section for section in order if section not in layout.get('hiddenSections',[])]

    def measures(self,client):
        from panel_plan import block_plan
        return block_plan(client,'billing' if client.startswith('api:') else 'quota',self.layout().get('blocks',{}).get(client,{}))['measures']

    def measure(self,client):
        offered=self.measures(client);selected=self.metric_selection.get(client)
        identities=getattr(self,'_measure_identities',{});self._measure_identities=identities
        identity=(self.layout().get('blocks',{}).get(client,{}).get('widget','number' if client.startswith('api:') else 'bar'),tuple(offered))
        if client in identities and identities[client]!=identity:selected=None;self.metric_selection.pop(client,None)
        identities[client]=identity
        return selected if selected in offered else offered[0]

    def provider_lines(self):
        from panel_plan import plan
        providers={**dict(self.providers()),**self.billing_providers()};layout=self.layout()
        # providers() already applies account/row filtering to defensive copies.
        # The planner now resolves presentation and pairing only.
        changes={key:{name:value for name,value in change.items() if name not in ('accounts','hiddenRows','rows')} for key,change in layout.get('blocks',{}).items()}
        arranged=plan({**layout,'blocks':changes},[dict(key=key,kind='billing' if key.startswith('api:') else 'quota') for key in providers],self.content_width()-36,
                      not self.meter.settings.get('separates_agents',True) or self.meter.settings.get('mode')=='notch')
        return [[(block,providers[block['key']]) for block in line] for line in arranged['lines']]

    def provider_height(self,w,data,block):
        if block['kind']=='billing':
            from billing_widgets import height
            return height(self,w,data,block)
        return self.provider_content(w,block['key'],data,block)

    def billing_providers(self):
        from billing_metrics import legacy_account
        result={};changes=self.layout().get('blocks',{})
        for client,data in self.sources():
            if client!='DeepSeek':continue
            quota=data.get('quota',{});accounts=quota.get('api_billing',[]) if 'api_billing' in quota else [legacy_account(client,quota)]
            for account in accounts:
                key='api:'+account['provider'];change=changes.get(key,{})
                if change.get('hidden') or account['id'] in self.meter.settings.get('hidden_accounts',[]):continue
                if change.get('accounts') and account['id'] not in change['accounts']:continue
                result.setdefault(key,{'billing_accounts':[]})['billing_accounts'].append(account)
        return result

    def provider_content(self,w,client,data,block,p=None):
        from panel_accounts import sections,header_lines,paint_header,wallet_height,paint_wallet
        from panel_plan import spacing_metrics
        spacing=self.layout().get('style',{}).get('spacing','regular');parts=spacing_metrics(spacing)['blockParts'];half=block['span']=='half'
        groups=sections(data.get('quota',{}));y=20
        if not groups and block['widget']!='chart':groups=[dict(account=None,is_current=True,quota={**data.get('quota',{}),'windows':data.get('quota',{}).get('windows',[])})]
        def draw(callback,opacity=1):
            if p is None:return
            first_hit=len(self.hits);p.save();p.translate(0,y);p.setOpacity(p.opacity()*opacity);callback();p.restore()
            for index in range(first_hit,len(self.hits)):
                rect,action=self.hits[index];self.hits[index]=(rect.translated(0,y),action)
        for group in groups:
            quota=group['quota'];rows=quota.get('windows',[]);wallets=quota.get('wallets',[]);opacity=1 if group['is_current'] else .55
            if group['account']:
                y+=parts;draw(lambda:paint_header(self,p,w,group,half));y+=header_lines(group,w,half)['height']
            if quota.get('credit_balance'):
                from workbuddy_quota import credit_text
                left='剩余积分  '+credit_text(quota['credit_balance'],'remaining');right='总积分  '+credit_text(quota['credit_balance'],'total')
                stacked=QFontMetricsF(font(12,True)).horizontalAdvance(left)+QFontMetricsF(font(10)).horizontalAdvance(right)+20>w-12
                y+=parts
                def credits():
                    text(p,QRectF(6,0,w-12 if stacked else w*.58,22),left,12,'text',True)
                    text(p,QRectF(6 if stacked else w*.58,22 if stacked else 0,w-12 if stacked else w*.42-6,22),right,10,'secondary',align=Qt.AlignmentFlag.AlignLeft if stacked else Qt.AlignmentFlag.AlignRight)
                draw(credits,opacity);y+=44 if stacked else 22
            if block['widget']!='chart' and (rows or not wallets):
                y+=parts
                if rows and block['widget'] in ('ring','number'):
                    from quota_cells import geometry
                    height=geometry(rows,w,block,spacing)[2]
                else:height=max(1,len(rows))*28
                draw(lambda:self.quota_rows(p,w,client,{**data,'quota':quota},block),opacity);y+=height
            for wallet in wallets:
                y+=parts;draw(lambda:paint_wallet(p,w,wallet,half),opacity);y+=wallet_height(wallet,w,half)
        if block['widget']=='chart':
            from panel_charts import paint
            y+=parts;draw(lambda:paint(self,p,w,client,data,block));y+=40+spacing_metrics(spacing)['chartTop']
        return y

    def sources(self):
        return list(self.meter.group_data.items()) if not self.meter.settings.get('separates_agents',True) or self.meter.settings.get('mode')=='notch' else [(self.meter.client,self.data)]

    def providers(self):
        from usage_display import window_key,window_account,panel_row_key
        layout=self.layout();changes=layout.get('blocks',{});providers=[]
        for client,data in self.sources():
            if client=='DeepSeek':continue  # Its source block is APIBilling, never a quota percentage.
            change=changes.get(client,{})
            if change.get('hidden'):continue
            quota=data.get('quota',{});rows=quota.get('windows',[]);accounts=change.get('accounts',[])
            fallback=(quota.get('account') or {}).get('id','')
            kept=[row for row in rows if not {window_key(row),panel_row_key(row)}.intersection(change.get('hiddenRows',[])) and (not accounts or (window_account(row) or fallback) in accounts)]
            if rows and not kept:continue
            order=change.get('rows',[]);account_order=list(dict.fromkeys(window_account(row) or fallback for row in rows))
            def rank(row):return min((order.index(key) for key in (window_key(row),panel_row_key(row)) if key in order),default=len(order))
            kept=sorted(kept,key=lambda row:(account_order.index(window_account(row) or fallback),rank(row)))
            balance=quota.get('credit_balance') if not accounts or fallback in accounts else None
            wallets=[wallet for wallet in quota.get('wallets',[]) if not accounts or (window_account(wallet) or fallback) in accounts]
            if not rows and accounts and not balance and not wallets:continue
            providers.append((client,{**data,'quota':{**quota,'windows':kept,'credit_balance':balance,'wallets':wallets}}))
        order=layout.get('order',[])
        return sorted(providers,key=lambda pair:order.index(pair[0]) if pair[0] in order else len(order))

    def sessions(self):
        rows=[{**row,'_client':client} for client,data in self.sources() for row in data.get('local',{}).get('sessions',[])]
        return sorted(rows,key=lambda row:(row.get('state')!='running',-row.get('updated',0)))

    def natural_height(self):
        if self.meter.attention_event():
            from attention_views import height
            return height(self.meter)+28
        from panel_plan import spacing_metrics
        spacing=spacing_metrics(self.layout().get('style',{}).get('spacing','regular'));gap=spacing['blocks'];after=spacing['divided']+gap
        quota=sum(max(self.provider_height((self.content_width()-36-gap*(len(line)-1))/len(line),data,block) for block,data in line)+after for line in self.provider_lines())
        sessions=self.sessions()[:int(self.layout().get('sessions',{}).get('limit',5))]
        sections=self.section_order()
        return 14+(quota if 'blocks' in sections else 0)+(92+18 if 'tokens' in sections else 0)+(22+max(1,len(sessions))*25+18 if 'sessions' in sections else 0)+17+28+14+(40 if self.draft_bar.ready() else 0)

    def layout_height(self):
        return min(self.natural_height(),self.meter.screen.availableGeometry().height()-12)

    def reposition(self):
        self.move(self.position_for(self.progress))

    def position_for(self,progress):
        screen=self.meter.screen.availableGeometry()
        edge='top' if self.meter.settings.get('mode')=='notch' else self.meter.settings.get('edge','top')
        geom=self.meter.geometry()
        selected=next((rect for client,rect in self.meter.cells if client==self.meter.client),QRectF(self.meter.rect()))
        centre=QPointF(geom.x()+selected.center().x(),geom.y()+selected.center().y()) if self.meter.settings.get('separates_agents',True) else QPointF(geom.center())
        width=self.content_width();height=self.layout_height()
        x=centre.x()-width/2
        y=geom.bottom()+6
        if edge=='bottom':y=geom.top()-height-6
        elif edge=='left':x=geom.right()+6;y=centre.y()-height/2
        elif edge=='right':x=geom.left()-width-6;y=centre.y()-height/2
        x=max(screen.left()+6,min(x,screen.right()-width-6))
        y=max(screen.top()+3,min(y,screen.bottom()-height-3))
        origin=getattr(self,'source_rect',geom)
        from PySide6.QtCore import QPoint
        return QPoint(round(origin.x()+(x-origin.x())*progress),round(origin.y()+(y-origin.y())*progress))

    def open(self):
        if not self.isVisible():
            # Capture the full travel corridor before either surface is shown.
            # This also covers side/bottom anchored shrink animations.
            target=QRect(self.position_for(1.),QSize(self.content_width(),self.layout_height()))
            corridor=target.united(getattr(self,'source_rect',self.meter.geometry()))
            if self.meter.settings['glass'] and not self.meter.preview:
                self.frost.capture(self.meter.screen,corridor)
            else:self.frost.clear()
        self.animate(self.progress)
        self.show()
        self.reposition()
        self.apply_material()
        self.animation.retarget(1.)
        if self.pinned:
            self.raise_()
            self.activateWindow()
            self.setFocus(Qt.FocusReason.MouseFocusReason)

    def event(self,event):
        # A click keeps the panel open while interacting with it, not forever.
        # WindowDeactivate also covers switching to settings or another app;
        # FocusOut alone would fire when moving between controls in this panel.
        if event.type()==QEvent.Type.WindowDeactivate and self.isVisible():
            self._attention_press=None
            self.pinned=False
            self.meter.enter_timer.stop()
            self.meter.leave_timer.stop()
            self.meter.peek.dismiss(immediate=True)
            self.collapse()
        return super().event(event)

    def apply_material(self):
        apply_widget_theme(self,self.meter.light())
        cfg=self.meter.settings
        self.native_glass=False
        if not self.meter.preview:frosted_backdrop(self.winId(),False)
        if not cfg['glass']:self.frost.clear()
        rounded_native_window(self,getattr(self,'corner',DESIGN['full_corner']))
        self.update()

    def collapse(self):
        self.pinned=False
        self.animation.retarget(0.)

    def animate(self,value):
        self.progress=max(0,min(1,float(value)))
        # Grow the shell in both dimensions; keep content at its final width to
        # avoid line wrapping and chart reflow during the source's 400ms curve.
        target=self.content_width()
        origin=getattr(self,'source_rect',self.meter.geometry())
        start=min(target,max(1,origin.width()));start_height=origin.height()
        extent=QSize(round(start+(target-start)*self.progress),max(1,round(start_height+(self.layout_height()-start_height)*self.progress)))
        # Move and resize in one native transaction. Separate calls briefly put
        # the old backing surface at the new side-edge position while shrinking.
        self.setGeometry(QRect(self.position_for(self.progress),extent))
        self.corner=self.meter.corner+(DESIGN['full_corner']-self.meter.corner)*self.progress
        shape=QPainterPath()
        shape=surface_path(self.rect(),self.corner)
        self.setMask(QRegion(shape.toFillPolygon().toPolygon()))
        if self.isVisible():rounded_native_window(self,self.corner)
        self.update()
        self.draft_bar.sync()

    def content_width(self):
        event=self.meter.attention_event()
        if event and event['kind'] in ('quota','reset_credits'):return min(int(DESIGN['alert_width']),self.meter.screen.availableGeometry().width()-16)
        single=self.meter.settings.get('separates_agents',True) and self.meter.settings.get('mode')!='notch'
        width=int(self.layout().get('style',{}).get('width',540))
        # PanelStyle.agentPanelWidth keeps a 440pt floor even when the shared
        # panel is configured narrower than its default 540pt width.
        if single:width=max(440,width-100)
        return min(width,self.meter.screen.availableGeometry().width()-16)

    def finished(self):
        if self.progress < .01:
            self.hide()
            self.frost.clear()
            self.meter.retiring_attention=None
            self.meter.show_reminder()

    def enterEvent(self,event):
        self.meter.leave_timer.stop()

    def leaveEvent(self,event):
        if self.isVisible():self.meter.leave_timer.start()

    def paintEvent(self,event):
        self.meter.palette_colors()
        p=QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        shell_alpha=min(1,max(0,self.progress*4))
        p.setOpacity(shell_alpha)
        path=QPainterPath()
        radius=getattr(self,'corner',16)
        path=surface_path(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5),radius)
        sampled=self.frost.paint(p,self,path)
        fill=self.meter.surface_fill(sampled)
        p.fillPath(path,fill)
        # Clear/regular glass has no extra hairline in HUDLook.outline.
        if not sampled or self.meter.settings.get('glass_style')=='material':
            p.setPen(QPen(color('outline',painter=p),1));p.drawPath(path)
        p.setClipPath(path)
        phase=min(1,max(0,(self.progress-.1)/.9))
        p.setOpacity(phase*phase*(3-2*phase))
        self.scroll_offset=max(0,min(self.scroll_offset,self.natural_height()-self.layout_height()))
        p.translate(18+(self.width()-self.content_width())/2,14+6*(1-self.progress)-self.scroll_offset)
        w=self.content_width()-36
        self.hits=[]
        attention=self.meter.attention_event()
        if attention:
            from attention_views import paint
            paint(self,p,w,attention);p.end();return
        y=0;p.save()
        # The source draft bar and footer sit outside scrolling content. Keep
        # them reachable even with every section hidden or a very long panel.
        bottom=self.height()-59-(40 if self.draft_bar.ready() else 0)
        p.setClipRect(QRectF(0,self.scroll_offset-14,w,max(0,bottom)),Qt.ClipOperation.IntersectClip)
        for section in self.section_order():
            if section=='blocks':
                from panel_plan import spacing_metrics
                spacing=spacing_metrics(self.layout().get('style',{}).get('spacing','regular'))
                for line in self.provider_lines():
                    width=(w-spacing['blocks']*(len(line)-1))/len(line);height=0
                    for column,(block,data) in enumerate(line):
                        x=column*(width+spacing['blocks']);first_hit=len(self.hits)
                        p.save();p.translate(x,y);height=max(height,self.provider_block(p,width,block['key'],data,block));p.restore()
                        for index in range(first_hit,len(self.hits)):
                            rect,action=self.hits[index];self.hits[index]=(rect.translated(x,y),action)
                    if len(line)>1 and self.layout().get('style',{}).get('separators',True):
                        p.fillRect(QRectF(w/2-.5,y,1,height),color('divider',painter=p))
                    y+=height
                    if self.layout().get('style',{}).get('separators',True):divider(p,y+spacing['divided'],w)
                    y+=spacing['divided']+spacing['blocks']
            else:
                y=self.token_block(p,y,w) if section=='tokens' else self.sessions_block(p,y,w)
                divider(p,y+8,w);y+=18
        p.restore()
        visible=QRectF(0,self.scroll_offset-14,w,max(0,bottom))
        self.hits=[(rect.intersected(visible),action) for rect,action in self.hits if rect.intersects(visible)]
        y=self.height()-56+self.scroll_offset
        self.gear(p,QPointF(14,y+14))
        text(p,QRectF(40,y,w-80,28),'已用额度',10,'tertiary',align=Qt.AlignmentFlag.AlignCenter)
        self.chart_icon(p,QPointF(w-14,y+14))
        self.hits.append((QRectF(0,y,30,28),'settings'))
        self.hits.append((QRectF(w-30,y,30,28),'details'))
        p.end()

    def provider_block(self,p,w,client=None,data=None,block=None):
        client=client or self.meter.client;data=self.data if data is None else data
        if block is not None and block['kind']=='billing':
            from billing_widgets import paint
            return paint(self,p,w,client,data,block)
        if block is None:
            from panel_plan import block_plan
            block=block_plan(client,'quota',self.layout().get('blocks',{}).get(client,{}))
        artwork().draw(p,client,QRectF(6,2,14,14))
        picker_width=0 if len(self.measures(client))==1 else min(len(self.measures(client))*22-2,86 if w<300 else 108)
        from quota_metric_views import picker,presentation
        if block['widget']=='chart':
            from panel_charts import series
            values=series(self,client,data,block['period'])
            period={'day':'24 小时','week':'7 天','month':'30 天'}[block['period']]
            total=compact(values['total']) if values['reported'] else '—'
            from quota_cells import fitting
            label=fitting((period+' · '+total,total),max(0,w-34-QFontMetricsF(font(13,True)).horizontalAdvance(client)),11)
            picker_width=QFontMetricsF(font(11)).horizontalAdvance(label)
            text(p,QRectF(w-picker_width,0,picker_width,20),label,11,'secondary',align=Qt.AlignmentFlag.AlignRight)
        else:picker(self,p,w,client)
        text(p,QRectF(26,0,w-picker_width-34,20),client,13,'text',True)
        return self.provider_content(w,client,data,block,p)

    def quota_rows(self,p,w,client,data,block):
        from quota_metric_views import presentation
        quota=data.get('quota',{});y=0
        rows=data.get('quota',{}).get('windows',[])
        if not rows:
            from quota_state import quota_notice
            notice=quota_notice(data.get('quota',{}),client)
            fm=QFontMetricsF(font(11))
            text(p,QRectF(6,y,w-12,28),fm.elidedText(notice,Qt.TextElideMode.ElideRight,w-12),11,'secondary')
            return y+28
        if block['widget'] in ('ring','number'):
            from quota_cells import paint
            first_hit=len(self.hits);p.save();p.translate(0,y)
            height=paint(self,p,w,rows,quota,block,self.measure(client),self.layout().get('style',{}).get('spacing','regular'));p.restore()
            for index in range(first_hit,len(self.hits)):
                rect,action=self.hits[index];self.hits[index]=(rect.translated(0,y),action)
            return y+height
        for row in rows:
            from quota_insights import number
            used=number(row.get('used'));ink=level(used)
            metric=self.measure(client)
            import time
            at=number(quota.get('at'));fresh=not quota.get('stale') and not quota.get('error_code') and at is not None and 0<=time.time()-at<=1800
            shown=presentation(row,metric,fresh)
            value_ink=ink if metric=='quota' else 'warning' if shown['warning'] else 'ok'
            marker_ink='tertiary' if shown['value']=='—' else value_ink
            p.setPen(Qt.PenStyle.NoPen);p.setBrush(color(marker_ink,painter=p))
            p.drawEllipse(QPointF(10,y+14),4,4)
            label={'Weekly':'每周限额','5-hour':'5 小时限额','Included':'包含用量'}.get(row['label'],row['label'])
            value_width=max(DESIGN['metric_value_width'],math.ceil(QFontMetricsF(font(13,True)).horizontalAdvance(shown['value'])))
            detail_width=DESIGN['metric_detail_width']
            label_width=max(70,min(DESIGN['label_width'],w-value_width-detail_width-65))
            text(p,QRectF(26,y,label_width,28),QFontMetricsF(font(13,True)).elidedText(label,Qt.TextElideMode.ElideRight,label_width),13,'text',True)
            start=26+label_width+12;bar_w=max(0,w-start-value_width-detail_width-15)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(color('track',painter=p))
            p.drawRoundedRect(QRectF(start,y+12,bar_w,4),2,2)
            if used is not None:
                fraction=max(0,min(1,used/100))
                if metric=='burn' and shown['fraction']>fraction:
                    projected=color('warning' if shown['warning'] else 'secondary',painter=p);projected.setAlphaF(projected.alphaF()*.38)
                    p.setBrush(projected);p.drawRoundedRect(QRectF(start,y+12,bar_w*max(0,min(1,shown['fraction'])),4),2,2)
                p.setBrush(color(ink,painter=p))
                p.drawRoundedRect(QRectF(start,y+12,bar_w*fraction,4),2,2)
            text(p,QRectF(start+bar_w+8,y,value_width,28),shown['value'],13,'secondary' if shown['value']=='—' else value_ink,True,Qt.AlignmentFlag.AlignRight)
            countdown=self.layout().get('blocks',{}).get(client,{}).get('countdown',self.layout().get('countdown',True))
            if metric!='quota' or countdown:text(p,QRectF(w-detail_width-6,y,detail_width,28),shown['detail'],12,'warning' if metric=='burn' and shown['warning'] else 'secondary',align=Qt.AlignmentFlag.AlignRight)
            if metric!='quota':
                local=(row.get('metrics') or {}).get('scope')=='local'
                hint='本机已观测记录；未推断账户归属。' if local else '已核对的用量记录。'
                if shown['value']=='—':hint='暂无此指标可核对的记录。'
                if metric=='cost':
                    from catalog_pricing import catalog
                    hint+=' 按价目估算，并非实付账单；价目核对：'+catalog().get('checkedOn','—')+'。'
                if metric=='burn':
                    hint='根据最近有效额度读数计算；'+shown['detail']+'。'
                    insight=row.get('insights') or {}
                    if shown['detail'] in ('采样中','重新采样'):
                        observed='不足1分' if (insight.get('elapsed') or 0)<60 else str(int(insight['elapsed']//60))+'分'
                        hint=('额度已重置，正在重新采样' if insight.get('after_reset') else '首次采样，正在积累预测数据')+'\n已采样 '+observed+'，预测至少需要'+str(int(insight['required']//60))+'分的有效记录'
                self.hits.append((QRectF(0,y,w,28),('metric_hint',hint)))
            y+=28
        return y

    def token_block(self,p,y,w):
        from usage_display import hourly
        text(p,QRectF(0,y,100,20),'Tokens',13,'text',True)
        text(p,QRectF(100,y,w-100,20),'最近 24 小时 · 每小时',10,'secondary',align=Qt.AlignmentFlag.AlignRight)
        reports=[data.get('local',{}).get('stats',{}) for _,data in self.sources()]
        items=hourly(reports) if any(r.get('event_count') for r in reports) else []
        chart_y=y+27
        if not items:
            text(p,QRectF(6,chart_y,w-12,55),'暂无可读取的 Token 记录',11,'tertiary')
        else:
            maximum=max(1,max(row['total'] for row in items))
            gap=3;bw=(w-12-(len(items)-1)*gap)/len(items)
            for index,row in enumerate(items):
                x=6+index*(bw+gap);height=55*row['total']/maximum
                parts=[(row.get('cache',0),'#b098df'),(row.get('fresh_input',0),'#69a9e9'),(row.get('cache_write',0),'#75bca0'),
                       (row.get('reasoning',0),'#de86af'),(row.get('visible_output',0),'#e99d52')]
                total=max(1,sum(n for n,_ in parts));bottom=chart_y+55
                for amount,tint in parts:
                    part=height*amount/total;bottom-=part
                    p.fillRect(QRectF(x,bottom,bw,max(0,part)),QColor(tint))
                self.hits.append((QRectF(x,chart_y,bw,55),'details'))
            p.setPen(QPen(color('divider',painter=p),1))
            p.drawLine(QPointF(6,chart_y+56),QPointF(w-6,chart_y+56))
        return chart_y+65

    def sessions_block(self,p,y,w):
        items=self.sessions()
        running=sum(row['state']=='running' for row in items)
        text(p,QRectF(0,y,90,20),'会话',13,'text',True)
        text(p,QRectF(100,y,w-100,20),f'{running} 个运行中' if running else '最近会话',12,'secondary',align=Qt.AlignmentFlag.AlignRight)
        y+=22
        if not items:
            text(p,QRectF(6,y,w-12,25),'等待新会话',11,'tertiary')
            return y+25
        fm=QFontMetricsF(font(12))
        for row in items[:int(self.layout().get('sessions',{}).get('limit',5))]:
            artwork().draw(p,row.get('_client',self.meter.client),QRectF(1,y+5,14,14),.7 if row['state']!='running' else 1)
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

    def wheelEvent(self,event):
        self.scroll_offset=max(0,min(self.natural_height()-self.layout_height(),self.scroll_offset-event.angleDelta().y()/3))
        self.update();event.accept()

    def mousePressEvent(self,event):
        if event.button()==Qt.MouseButton.RightButton:
            self.meter.menu_callback(event.globalPosition().toPoint());return
        if self.progress<.98:return
        point=event.position()-QPointF(18,14-self.scroll_offset)
        for rect,action in reversed(self.hits):
            if rect.contains(point):
                if isinstance(action,tuple) and action[0] in ('attention','metric'):
                    self._attention_press=(QRectF(rect),action)
                    return
                elif action=='settings':
                    if hasattr(self.meter,'settings_callback'):self.meter.settings_callback()
                    else:self.meter.menu_callback(event.globalPosition().toPoint())
                elif action=='details' and hasattr(self.meter,'usage_callback'):
                    self.pinned=True
                    self.meter.usage_callback(self.meter.client,self.data)
                elif isinstance(action,dict):
                    from PySide6.QtWidgets import QMessageBox
                    self.pinned=True
                    label={'running':'运行中','done':'已结束','stopped':'已停止','error':'异常','unknown':'最后记录'}
                    details=action['title']+'\n\n'+label.get(action['state'],'最后记录')+'\n会话累计 Tokens: '+compact(action.get('tokens'))
                    credits=action.get('credits')
                    if credits:
                        details+=f'\n已消耗积分: {credits["total"]:.2f}'
                        if credits['unattributed']>.005:details+=f'（未归因 {credits["unattributed"]:.2f}）'
                        if credits.get('size',0)>0:details+=f'\n上下文: {credits["used"]:,} / {credits["size"]:,} tokens'
                    QMessageBox.information(self,'会话',details)
                break

    def mouseReleaseEvent(self,event):
        pressed=getattr(self,'_attention_press',None);self._attention_press=None
        if not pressed or event.button()!=Qt.MouseButton.LeftButton or self.progress<.98:return
        point=event.position()-QPointF(18,14-self.scroll_offset)
        rect,action=pressed
        if rect.contains(point) and any(r.contains(point) and a==action for r,a in self.hits):
            if action[0]=='metric':self.metric_selection[action[1]]=action[2];self.update()
            else:
                from attention_views import dispatch
                dispatch(self.meter,action[1],action[2])

    def mouseMoveEvent(self,event):
        from quota_metrics import MEASURES
        point=event.position()-QPointF(18,14-self.scroll_offset)
        action=next((action for rect,action in reversed(self.hits) if rect.contains(point) and isinstance(action,tuple) and action[0] in ('metric','metric_hint')),None)
        self.setToolTip(action[1] if action and action[0]=='metric_hint' else '余额' if action and action[1].startswith('api:') and action[2]=='quota' else dict(MEASURES).get(action[2],'') if action else '')
        super().mouseMoveEvent(event)
