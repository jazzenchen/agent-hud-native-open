"""Native counterparts of UsageChartsCard, UsagePeriodsCard and HeatmapCard.

Geometry/hierarchy and kind colors follow the original Stats and Theme sources.
Only indexed ledger records are drawn; missing prices and history stay unknown.
"""
import math,re,time
from datetime import datetime,timedelta
from PySide6.QtCore import Qt,QRectF,QPointF
from PySide6.QtGui import QPainter,QColor,QPen,QFont,QPainterPath
from PySide6.QtWidgets import QWidget,QVBoxLayout,QHBoxLayout,QLabel,QComboBox,QCheckBox,QToolButton,QMenu
from settings_controls import Segmented
from source_design import DESKTOP
from usage_display import CHANNELS
from theme import tokens
from views import compact,font

LABELS=dict(fresh_input='输入',cache='缓存读取',cache_write='缓存写入',visible_output='输出',reasoning='推理')


def kind_colors(light):
    source=(DESKTOP/'Theme/Theme.swift').read_text(encoding='utf-8')
    names=dict(fresh_input='input',cache='cacheRead',cache_write='cacheWrite',visible_output='output',reasoning='reasoning')
    result={}
    for key,name in names.items():
        match=re.search(r'case \.'+name+r': Color\(hex: isLight \? 0x([0-9a-f]+) : 0x([0-9a-f]+)\)',source)
        if not match:raise ValueError('Original token color changed: '+name)
        result[key]='#'+match[1 if light else 2]
    return result


def columns(stats,hours,channels=CHANNELS,now=None,bucket_seconds=None):
    now=time.time() if now is None else now;seconds=bucket_seconds or (900 if hours<=24 else 86400)
    end=int(now//seconds)*seconds if seconds<86400 else int(datetime.fromtimestamp(now).replace(hour=0,minute=0,second=0,microsecond=0).timestamp());count=math.ceil(hours*3600/seconds)+1
    result={end-i*seconds:dict(at=end-i*seconds,**{key:0 for key in CHANNELS},total=0) for i in range(count)}
    for row in stats.get('buckets',[]):
        if not now-hours*3600<=row['at']<=now:continue
        slot=int(row['at']//seconds)*seconds if seconds<86400 else int(datetime.fromtimestamp(row['at']).replace(hour=0,minute=0,second=0,microsecond=0).timestamp())
        if slot not in result:continue
        for key in channels:result[slot][key]+=row.get(key,0)
        result[slot]['total']+=sum(row.get(key,0) for key in channels)
    return [result[key] for key in sorted(result)]


def period_totals(stats,now=None,channels=CHANNELS):
    now=time.time() if now is None else now;today=datetime.fromtimestamp(now).replace(hour=0,minute=0,second=0,microsecond=0).timestamp()
    starts=(today,now-7*86400,now-30*86400);rows=stats.get('buckets',[])
    return [sum(sum(row.get(key,0) for key in channels) for row in rows if start<=row['at']<=now) for start in starts]


class StatsCanvas(QWidget):
    def __init__(self,kind,parent=None):
        super().__init__(parent);self.kind=kind;self.stats={};self.hours=24;self.bucket_seconds=3600;self.channels=CHANNELS;self.hovered=None;self.client='';self.setMouseTracking(True)
        self.setMinimumHeight(dict(chart=224,agent=128,periods=120,heatmap=150)[kind])
    def light(self):return bool(self.window().property('uiLight'))
    def set_data(self,stats,client,hours,channels):
        self.stats=stats;self.client=client;self.hours=hours;self.channels=channels;self.update()
    def label(self,p,rect,value,size=12,bold=False,muted=False,align=Qt.AlignmentFlag.AlignLeft):
        p.setFont(font(size,bold));p.setPen(QColor(tokens(self.light())['muted' if muted else 'ink']));p.drawText(rect,align|Qt.AlignmentFlag.AlignVCenter,str(value))
    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing);t=tokens(self.light());colors=kind_colors(self.light());box=QRectF(self.rect()).adjusted(.5,.5,-.5,-.5)
        p.setBrush(QColor(t['card']));p.setPen(QPen(QColor(t['border']),1));p.drawRoundedRect(box,10,10)
        if self.kind=='chart':self.chart(p,colors)
        elif self.kind=='periods':self.periods(p,colors)
        elif self.kind=='heatmap':self.heatmap(p)
        else:self.agent(p,colors)
        p.end()
    def chart(self,p,colors):
        rows=columns(self.stats,self.hours,self.channels,bucket_seconds=self.bucket_seconds);total=sum(row['total'] for row in rows)
        self.label(p,QRectF(16,10,180,24),'Token 消耗',13,True);self.label(p,QRectF(self.width()-160,8,144,30),compact(total),20,True,align=Qt.AlignmentFlag.AlignRight)
        plot=QRectF(16,52,self.width()-32,136);peak=max((row['total'] for row in rows),default=0);width=plot.width()/max(1,len(rows));p.setPen(QPen(QColor(tokens(self.light())['divider']),1));p.drawLine(plot.bottomLeft(),plot.bottomRight())
        for i,row in enumerate(rows):
            x=plot.left()+i*width;gap=min(2,width*.2);height=row['total']/max(1,peak)*plot.height();bottom=plot.bottom()
            path=QPainterPath();path.addRoundedRect(QRectF(x+gap/2,bottom-height,width-gap,height),2,2);p.save();p.setClipPath(path);p.setPen(Qt.PenStyle.NoPen)
            for key in self.channels:
                part=row[key]/max(1,peak)*plot.height();bottom-=part;p.fillRect(QRectF(x+gap/2,bottom,width-gap,part),QColor(colors[key]))
            p.restore()
            if self.hovered==i:
                p.fillRect(QRectF(x,plot.top(),width,plot.height()),QColor('#180a84ff'))
        if not total:self.label(p,plot,'尚无已索引的用量' if self.channels else '未选择 Token 种类',12,muted=True,align=Qt.AlignmentFlag.AlignCenter)
        if rows:
            self.label(p,QRectF(16,190,180,20),datetime.fromtimestamp(rows[0]['at']).strftime('%m/%d %H:%M'),10,muted=True)
            self.label(p,QRectF(self.width()-196,190,180,20),datetime.fromtimestamp(rows[-1]['at']).strftime('%m/%d %H:%M'),10,muted=True,align=Qt.AlignmentFlag.AlignRight)
    def periods(self,p,colors):
        self.label(p,QRectF(14,8,200,23),'近期用量',13,True);values=period_totals(self.stats,channels=self.channels);width=(self.width()-28)/3
        for i,(name,total) in enumerate(zip(('今天','最近 7 天','最近 30 天'),values)):
            x=14+i*width
            if i:p.setPen(QPen(QColor(tokens(self.light())['divider']),1));p.drawLine(QPointF(x-8,40),QPointF(x-8,self.height()-14))
            self.label(p,QRectF(x,38,width-22,22),name,12,True);self.label(p,QRectF(x,65,width-22,26),compact(total) if total else '—',18,True)
    def agent(self,p,colors):
        self.label(p,QRectF(14,8,220,24),self.client,13,True);rows=columns(self.stats,self.hours,self.channels);total=sum(row['total'] for row in rows)
        self.label(p,QRectF(self.width()-190,8,174,24),compact(total)+' Tokens',13,True,align=Qt.AlignmentFlag.AlignRight)
        totals={key:sum(row.get(key,0) for row in rows) for key in self.channels};x=14
        for key,value in totals.items():
            width=(self.width()-28)*value/max(1,total);p.fillRect(QRectF(x,43,width,7),QColor(colors[key]));x+=width
        width=(self.width()-28)/max(1,len(self.channels))
        for i,key in enumerate(self.channels):
            x=14+i*width;p.fillRect(QRectF(x,69,6,6),QColor(colors[key]));self.label(p,QRectF(x+12,59,width-14,22),LABELS[key],10,muted=True);self.label(p,QRectF(x+12,82,width-14,23),compact(totals[key]),13,True)
    def heatmap(self,p):
        self.label(p,QRectF(14,8,240,24),'活跃记录',13,True);days={}
        for row in self.stats.get('buckets',[]):
            day=datetime.fromtimestamp(row['at']).date();days[day]=days.get(day,0)+sum(row.get(key,0) for key in self.channels)
        today=datetime.now().date();start=today-timedelta(days=364);start-=timedelta(days=start.weekday());peak=max(days.values(),default=0);cell=min(12,(self.width()-36)/53);gap=2
        for index in range(371):
            day=start+timedelta(days=index)
            if day>today:continue
            value=days.get(day,0);color=QColor(tokens(self.light())['track'])
            if value:color=QColor('#398ad6' if self.light() else '#6db0f4');color.setAlphaF(.2+.8*math.sqrt(value/max(1,peak)))
            p.setBrush(color);p.setPen(Qt.PenStyle.NoPen);p.drawRoundedRect(QRectF(14+(index//7)*cell,42+(index%7)*cell,cell-gap,cell-gap),2,2)
        self.label(p,QRectF(14,127,self.width()-28,18),'按已索引记录显示',10,muted=True)
    def mouseMoveEvent(self,event):
        if self.kind!='chart':return
        rows=columns(self.stats,self.hours,self.channels,bucket_seconds=self.bucket_seconds);index=int((event.position().x()-16)/max(1,self.width()-32)*len(rows))
        self.hovered=index if 0<=index<len(rows) else None
        if self.hovered is not None:
            row=rows[index];self.setToolTip(datetime.fromtimestamp(row['at']).strftime('%Y/%m/%d %H:%M')+' · '+compact(row['total'])+' Tokens')
        self.update()
    def leaveEvent(self,event):self.hovered=None;self.update()


class TokenDashboard(QWidget):
    def __init__(self,client,parent=None):
        super().__init__(parent);self.client=client;self.stats={};self.channels=[key for key in CHANNELS if key!='cache'];self.hours=24
        root=QVBoxLayout(self);root.setContentsMargins(0,0,0,0);root.setSpacing(12);controls=QHBoxLayout();controls.setSpacing(10)
        self.kinds_button=QToolButton();self.kinds_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup);self.kinds_button.setObjectName('statsKinds')
        self.kinds_menu=QMenu(self.kinds_button);self.kind_actions={}
        for label,keys in [('不含缓存读取',[key for key in CHANNELS if key!='cache']),('全部 Token',list(CHANNELS))]:self.kinds_menu.addAction(label,lambda checked=False,keys=keys:self.set_kinds(keys))
        self.kinds_menu.addSeparator()
        for key in CHANNELS:
            action=self.kinds_menu.addAction(LABELS[key]);action.setCheckable(True);action.setChecked(key in self.channels);action.toggled.connect(lambda on,key=key:self.toggle(key,on));self.kind_actions[key]=action
        self.kinds_button.setMenu(self.kinds_menu);controls.addWidget(self.kinds_button);controls.addStretch()
        self.bucket=Segmented([(900,'15min'),(1800,'30min'),(3600,'1hr'),(86400,'1d')]);self.bucket.setObjectName('statsBuckets');self.bucket.setCurrentIndex(2);self.bucket.currentIndexChanged.connect(self.change_bucket);controls.addWidget(self.bucket)
        self.range=Segmented([(5,'5 小时'),(24,'24 小时'),(168,'7 天'),(720,'30 天')]);self.range.setObjectName('statsRange')
        self.range.setCurrentIndex(1);self.range.currentIndexChanged.connect(self.change_range);controls.addWidget(self.range);root.addLayout(controls)
        self.cards=[]
        for kind in ('chart','agent','periods','heatmap'):
            card=StatsCanvas(kind);self.cards.append(card);root.addWidget(card)
    def set_data(self,stats):
        self.stats=stats
        label='不含缓存读取' if set(self.channels)==set(CHANNELS)-{'cache'} else '全部 Token' if len(self.channels)==5 else '、'.join(LABELS[key] for key in self.channels)
        self.kinds_button.setText('Token · '+label)
        for card in self.cards:card.bucket_seconds=86400 if self.hours==720 else self.bucket.currentData();card.set_data(stats,self.client,self.hours,self.channels)
    def set_kinds(self,keys):
        self.channels=list(keys)
        for key,action in self.kind_actions.items():action.blockSignals(True);action.setChecked(key in self.channels);action.blockSignals(False)
        self.set_data(self.stats)
    def toggle(self,key,on):
        if on and key not in self.channels:self.channels.append(key)
        elif not on and key in self.channels and len(self.channels)>1:self.channels.remove(key)
        action=self.kind_actions[key];action.blockSignals(True);action.setChecked(key in self.channels);action.blockSignals(False)
        self.set_data(self.stats)
    def change_range(self):self.hours=self.range.currentData();self.bucket.setVisible(self.hours!=720);self.set_data(self.stats)
    def change_bucket(self):self.set_data(self.stats)
