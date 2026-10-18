"""Qt counterparts of SimpleMeterView and the SwiftUI HoverPanelView tree.

Palette, geometry and timing come from source_design (the original Swift files).
The Windows layer supplies native glass, font substitution, windows and painting.
"""
from datetime import datetime
import math

from PySide6.QtCore import Qt, QRectF, QPointF, QSize, QTimer, QVariantAnimation, QEasingCurve
from PySide6.QtGui import QColor, QFont, QFontMetricsF, QImage, QPainter, QPainterPath, QPen, QPixmap, QRegion
from PySide6.QtWidgets import QWidget, QMenu

from material import frosted_backdrop
from source_design import DESIGN

COLORS = DESIGN['colors']


def font(size, bold=False):
    result = QFont('Segoe UI')  # Windows system substitute for Font.ui's SF Pro.
    result.setPixelSize(int(size))
    result.setWeight(QFont.Weight.DemiBold if bold else QFont.Weight.Normal)
    return result


def color(name, alpha=255):
    result = QColor(COLORS.get(name, name))
    result.setAlpha(alpha)
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


def reset_label(value):
    if not value:
        return ''
    try:
        date = datetime.fromtimestamp(value) if isinstance(value, (float, int)) else datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone()
        return date.strftime('%a %H:%M')
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
        painter.drawImage(rect, self.images[client])
        painter.restore()


ARTWORK = None


def artwork():
    global ARTWORK
    if ARTWORK is None:
        ARTWORK = Artwork()
    return ARTWORK


def text(p, rect, value, size=13, ink='text', bold=False, align=Qt.AlignmentFlag.AlignLeft):
    p.setFont(font(size, bold))
    p.setPen(color(ink))
    p.drawText(rect, align | Qt.AlignmentFlag.AlignVCenter, str(value))


def divider(p, y, width):
    p.setPen(QPen(QColor(255, 255, 255, 26), 1))
    p.drawLine(QPointF(0, y), QPointF(width, y))


class SimpleMeterView(QWidget):
    """One separate SimpleMeterConfig item, with no glow (as upstream Simple)."""
    def __init__(self, client, screen, settings, menu_callback, preview=False):
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.Tool | Qt.WindowType.WindowStaysOnTopHint)
        self.client, self.screen, self.settings = client, screen, settings
        self.menu_callback, self.preview = menu_callback, preview
        self.data = dict(local=dict(sessions=[]), quota=dict(windows=[]))
        self.anchor = QPointF(0, 0)
        self.native_glass = False
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setMouseTracking(True)
        self.setWindowTitle('Agent HUD · ' + client)
        self.setAccessibleName(client + ' 额度')
        self.panel = HoverPanelView(self)
        self.enter_timer = QTimer(self)
        self.enter_timer.setSingleShot(True)
        self.enter_timer.setInterval(220)
        self.enter_timer.timeout.connect(self.open_panel)
        self.leave_timer = QTimer(self)
        self.leave_timer.setSingleShot(True)
        self.leave_timer.setInterval(450)
        self.leave_timer.timeout.connect(self.maybe_close)
        self.refresh_size()

    def refresh_size(self):
        size = self.settings['size']
        tight, loose = max(3, round(size*.18)), round(size*.45)
        label = '–' if tightest(self.data) is None else f'{tightest(self.data):.0f}%'
        self.label = label
        self.mark_size, self.left, self.top = size, tight+1, tight
        self.label_spacing = round(size*.23)
        self.figure_size = round(9*max(1, size/26))
        label_width = math.ceil(QFontMetricsF(font(self.figure_size)).horizontalAdvance(label))
        self.setFixedSize(self.left+size+self.label_spacing+label_width+loose, size+tight*2)
        self.corner = min(round(size*.73), self.height()/2)
        self.round_mask()

    def round_mask(self):
        shape = QPainterPath()
        shape.addRoundedRect(QRectF(self.rect()), self.corner, self.corner)
        self.setMask(QRegion(shape.toFillPolygon().toPolygon()))

    def apply_material(self):
        self.native_glass = not self.preview and self.settings['glass'] and frosted_backdrop(self.winId())
        if not self.settings['glass'] and not self.preview:
            frosted_backdrop(self.winId(), False)
        self.update()

    def set_data(self, data):
        self.data = data
        self.refresh_size()
        self.panel.set_data(data)
        used = tightest(data)
        self.setToolTip(f'{self.client} · 已用 {used:.0f}%' if used is not None else f'{self.client} · 额度暂不可用')
        self.update()

    def place(self, x, y):
        self.move(int(x), int(y))
        self.anchor = QPointF(self.geometry().center().x(), self.geometry().bottom()+6)
        if self.panel.isVisible():
            self.panel.reposition()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        path = QPainterPath()
        path.addRoundedRect(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5), self.corner,self.corner)
        # The dark glass stand-in is used only for an offscreen preview/fallback.
        fill = QColor(0,0,0,18) if self.native_glass else QColor(28,28,30,245) if self.settings['glass'] else QColor(0,0,0)
        p.fillPath(path, fill)
        p.setPen(QPen(QColor(255,255,255,36),1))
        p.drawPath(path)
        rect = QRectF(self.left, self.top, self.mark_size, self.mark_size)
        used = tightest(self.data)
        width = self.settings['ring_width']
        ring = rect.adjusted(width/2,width/2,-width/2,-width/2)
        p.setPen(QPen(QColor(255,255,255,36),width))
        p.drawEllipse(ring)
        if used is not None:
            pen = QPen(color(level(used)),width,Qt.PenStyle.SolidLine,Qt.PenCapStyle.RoundCap)
            p.setPen(pen)
            p.drawArc(ring,90*16,-round(min(100,max(0,used))*3.6*16))
        logo = round(self.mark_size*.55)
        artwork().draw(p,self.client,QRectF(rect.center().x()-logo/2,rect.center().y()-logo/2,logo,logo))
        label_rect = QRectF(rect.right()+self.label_spacing,0,self.width()-rect.right()-self.label_spacing-round(self.mark_size*.45),self.height())
        text(p,label_rect,self.label,self.figure_size,level(used),align=Qt.AlignmentFlag.AlignRight)
        p.end()

    def enterEvent(self, event):
        self.leave_timer.stop()
        self.enter_timer.start()

    def leaveEvent(self, event):
        self.enter_timer.stop()
        self.leave_timer.start()

    def open_panel(self):
        self.panel.open()

    def maybe_close(self):
        if not self.underMouse() and not self.panel.underMouse() and not self.panel.pinned:
            self.panel.collapse()

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.RightButton:
            self.menu_callback(event.globalPosition().toPoint())
        elif event.button() == Qt.MouseButton.LeftButton:
            self.panel.pinned = not self.panel.pinned
            self.panel.open() if self.panel.pinned else self.panel.collapse()

    def hide_all(self):
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
        self.animation = QVariantAnimation(self)
        self.animation.setDuration(int(DESIGN['animation_ms']))
        curve = QEasingCurve(QEasingCurve.Type.BezierSpline)
        curve.addCubicBezierSegment(QPointF(.2,.8),QPointF(.2,1),QPointF(1,1))
        self.animation.setEasingCurve(curve)
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
        sessions=self.data.get('local',{}).get('sessions',[])[:5]
        return 14+20+17+rows*28+18+92+18+22+max(1,len(sessions))*25+18+34+14

    def reposition(self):
        screen=self.meter.screen.availableGeometry()
        x=max(screen.left()+6,min(self.meter.anchor.x()-self.width()/2,screen.right()-self.width()-6))
        self.move(round(x),round(self.meter.anchor.y()))

    def open(self):
        self.animation.stop()
        self.show()
        self.reposition()
        self.native_glass=not self.meter.preview and self.meter.settings['glass'] and frosted_backdrop(self.winId())
        if not self.meter.settings['glass'] and not self.meter.preview:
            frosted_backdrop(self.winId(),False)
        self.animation.setStartValue(self.progress)
        self.animation.setEndValue(1.)
        self.animation.start()

    def collapse(self):
        self.animation.stop()
        self.animation.setStartValue(self.progress)
        self.animation.setEndValue(0.)
        self.animation.start()

    def animate(self,value):
        self.progress=float(value)
        # Content's fixed 440pt layout is revealed along the upstream curve.
        self.setFixedSize(int(DESIGN['agent_width']),max(8,round(self.layout_height()*self.progress)))
        self.reposition()
        shape=QPainterPath()
        shape.addRoundedRect(QRectF(self.rect()),16,16)
        self.setMask(QRegion(shape.toFillPolygon().toPolygon()))
        self.update()

    def finished(self):
        if self.progress < .01:
            self.hide()

    def enterEvent(self,event):
        self.meter.leave_timer.stop()

    def leaveEvent(self,event):
        self.meter.leave_timer.start()

    def paintEvent(self,event):
        p=QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        path=QPainterPath()
        path.addRoundedRect(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5),16,16)
        fill=QColor(0,0,0,18) if self.native_glass else QColor(24,24,26,248) if self.meter.settings['glass'] else QColor(0,0,0)
        p.fillPath(path,fill)
        p.setPen(QPen(QColor(255,255,255,36),1))
        p.drawPath(path)
        p.setClipPath(path)
        p.setOpacity(min(1,max(0,(self.progress-.15)/.85)))
        p.translate(18,14)
        w=self.width()-36
        self.hits=[]
        y=self.provider_block(p,w)
        divider(p,y+8,w)
        y=self.token_block(p,y+18,w)
        divider(p,y+8,w)
        y=self.sessions_block(p,y+18,w)
        divider(p,y+8,w)
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
        text(p,QRectF(w/2,23,w/2-6,15),'当前账户',10,'tertiary',align=Qt.AlignmentFlag.AlignRight)
        y=43
        rows=self.data.get('quota',{}).get('windows',[])[:5]
        if not rows:
            notice=self.data.get('quota',{}).get('notice','正在读取额度…')
            if 'expired' in notice:
                notice='登录已过期，请在 Cursor 重新登录'
            fm=QFontMetricsF(font(11))
            text(p,QRectF(6,y,w-12,28),fm.elidedText(notice,Qt.TextElideMode.ElideRight,w-12),11,'secondary')
            return y+28
        for row in rows:
            used=float(row['used']);ink=level(used)
            p.setPen(Qt.PenStyle.NoPen);p.setBrush(color(ink))
            p.drawEllipse(QPointF(10,y+14),4,4)
            label={'Weekly':'每周限额','5-hour':'5 小时限额','Included':'包含用量'}.get(row['label'],row['label'])
            text(p,QRectF(26,y,DESIGN['label_width'],28),label,13,'text',True)
            start=26+DESIGN['label_width']+12;bar_w=w-start-130
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(255,255,255,31))
            p.drawRoundedRect(QRectF(start,y+12,bar_w,4),2,2)
            p.setBrush(color(ink))
            p.drawRoundedRect(QRectF(start,y+12,bar_w*max(0,min(1,used/100)),4),2,2)
            text(p,QRectF(start+bar_w+8,y,45,28),f'{used:.0f}%',12,ink,True,Qt.AlignmentFlag.AlignRight)
            text(p,QRectF(w-76,y,70,28),reset_label(row.get('reset')),10,'secondary',align=Qt.AlignmentFlag.AlignRight)
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
            p.setPen(QPen(QColor(255,255,255,22),1))
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
        for row in items[:5]:
            artwork().draw(p,self.meter.client,QRectF(1,y+5,14,14),.7 if row['state']!='running' else 1)
            p.setPen(QPen(QColor(20,20,22),2));p.setBrush(color('ok' if row['state']=='running' else 'tertiary'))
            p.drawEllipse(QPointF(15,y+18),3,3)
            name=fm.elidedText(row['title'],Qt.TextElideMode.ElideRight,w-94)
            text(p,QRectF(22,y,w-94,25),name,12,'secondary')
            text(p,QRectF(w-65,y,65,25),compact(row.get('tokens'))+' tok' if row.get('tokens') is not None else '–',11,'secondary',align=Qt.AlignmentFlag.AlignRight)
            self.hits.append((QRectF(0,y,w,25),row));y+=25
        return y

    def gear(self,p,center):
        p.save();p.translate(center);p.setPen(QPen(color('secondary'),1.3))
        p.setBrush(Qt.BrushStyle.NoBrush);p.drawEllipse(QPointF(0,0),5,5);p.drawEllipse(QPointF(0,0),1.8,1.8)
        for i in range(8):
            p.rotate(45);p.drawLine(QPointF(0,-5),QPointF(0,-7))
        p.restore()

    def chart_icon(self,p,center):
        p.setPen(Qt.PenStyle.NoPen);p.setBrush(color('secondary'))
        for x,h in [(-6,5),(-1,11),(4,8)]:p.drawRoundedRect(QRectF(center.x()+x,center.y()+6-h,3,h),.7,.7)

    def mousePressEvent(self,event):
        if event.button()==Qt.MouseButton.RightButton:
            self.meter.menu_callback(event.globalPosition().toPoint());return
        point=event.position()-QPointF(18,14)
        for rect,action in reversed(self.hits):
            if rect.contains(point):
                if action=='settings':self.meter.menu_callback(event.globalPosition().toPoint())
                elif action=='details' and hasattr(self.meter,'usage_callback'):
                    self.pinned=True
                    self.meter.usage_callback(self.meter.client,self.data)
                elif isinstance(action,dict):
                    from PySide6.QtWidgets import QMessageBox
                    self.pinned=True
                    label={'running':'运行中','done':'已结束','stopped':'已停止','error':'异常','unknown':'最后记录'}
                    QMessageBox.information(self,'会话',action['title']+'\n\n'+label.get(action['state'],'最后记录')+'\n会话累计 Tokens: '+compact(action.get('tokens')))
                break
