"""QuotaAlertDetailView / ResetCreditAlertDetailView on the actual HUD surface."""
import math
from datetime import datetime
from PySide6.QtCore import QRectF,Qt
from PySide6.QtGui import QColor,QFontMetricsF,QPen


def duration(seconds,round_up=True):
    if seconds is None:return '—'
    minutes=max(1 if round_up else 0,math.ceil(max(0,seconds)/60) if round_up else round(max(0,seconds))//60)
    return f'{minutes//60}h{minutes%60:02d}m' if minutes>=60 else f'{minutes}m'


def compact(event):
    if event['kind']=='reset_credits':return f'获得 {event["added"]} 次重置'
    if event['event']=='reset':return '已重置'
    if event['remaining']<=.5:return '已耗尽'
    return duration(event['time_to_exhaust'])+' 后耗尽' if event.get('time_to_exhaust') else '即将耗尽'


def paint(panel,p,w,event):
    from views import text,color,font,artwork
    from attention_views import geometry
    meter=panel.meter;layout=geometry(event,w);grant=event['kind']=='reset_credits'
    calm=grant or event.get('event')=='reset';light=meter.light();glass=meter.settings.get('glass') or meter.settings.get('transparency',0)>0
    fill=QColor(('#0f7b57' if calm else '#a8521c') if light else ('#6cd8ac' if calm else '#e9a16d'))
    accent=(('#0a5a3f' if calm else '#7c3b12') if light else ('#a8ecd0' if calm else '#f6c9a6')) if glass else fill.name()
    def ink(alpha):
        value=color('text',painter=p);value.setAlpha(round(alpha*255));return value.name(QColor.NameFormat.HexArgb)
    artwork().draw(p,event['vendor'],QRectF(0,0,22,22))
    text(p,QRectF(31,0,w-135,18),event['vendor'],13,'text',True)
    label=event.get('label') or '使用量重置'
    text(p,QRectF(31,18,w-135,16),QFontMetricsF(font(10)).elidedText(label,Qt.TextElideMode.ElideMiddle,w-135),10,ink(.42))
    text(p,QRectF(w-97,0,97,24),'新增重置' if grant else '已重置' if calm else '额度预警',10,accent,True,Qt.AlignmentFlag.AlignRight)
    if grant:
        title=f'账户获得了 {event["added"]} 次使用量重置。'
        expiry=next((row.get('expiresAt') for row in event.get('credits',[]) if row.get('expiresAt')),None)
        date=datetime.fromtimestamp(expiry).strftime('%m/%d') if isinstance(expiry,(int,float)) and 0<expiry<253402300799 else '—'
        metrics=[('+'+str(event['added']),'新增'),(str(event['available']),'可用次数'),(date,'最早到期')]
    else:
        title=('此窗口已重置，其他窗口仍有限制。' if event.get('other_limits') else '此窗口额度已重置。') if calm else '当前窗口额度已耗尽，等待重置。' if event['remaining']<=.5 else '按最近的消耗速率，预计将在重置前耗尽。' if event.get('time_to_exhaust') else '已用额度达到危险阈值，请留意后续任务。'
        interval=event['reset']-event['at'] if event.get('reset') else None
        date=datetime.fromtimestamp(event['reset']) if interval is not None and interval>=86400 and 0<event['reset']<253402300799 else None
        reset=('周'+'一二三四五六日'[date.weekday()]+' '+date.strftime('%H:%M')) if date else duration(interval,False)
        metrics=[(f'{100-event["remaining"]:.0f}%','已用额度'),(f'{event["remaining"]:.0f}%' if calm else duration(event.get('time_to_exhaust')),'剩余额度' if calm else '预计耗尽'),(reset,'下次重置')]
    text(p,QRectF(0,53,w,36),title,12,ink(.58),align=Qt.AlignmentFlag.AlignLeft|Qt.AlignmentFlag.AlignTop|Qt.TextFlag.TextWordWrap)
    cell=(w-24)/3
    for index,(value,label) in enumerate(metrics):
        x=index*(cell+12)
        size=23
        while size>12 and QFontMetricsF(font(size)).horizontalAdvance(value)>cell:size-=1
        text(p,QRectF(x,103,cell,30),value,size,'text')
        text(p,QRectF(x,137,cell,16),label,10,ink(.4))
    if not grant:
        text(p,QRectF(0,171,w-70,17),event['label'],10,ink(.42))
        text(p,QRectF(w-70,171,70,17),f'{100-event["remaining"]:.0f}%',10,ink(.42),align=Qt.AlignmentFlag.AlignRight)
        p.setPen(Qt.PenStyle.NoPen);p.setBrush(color('track',painter=p));p.drawRoundedRect(QRectF(0,194,w,4),2,2)
        p.setBrush(fill);p.drawRoundedRect(QRectF(0,194,w*(100-event['remaining'])/100,4),2,2)
        if event.get('other_limits'):
            text(p,QRectF(0,204,w,18),QFontMetricsF(font(10)).elidedText('、'.join(event['other_limits'])+'额度仍已耗尽',Qt.TextElideMode.ElideRight,w),10,accent)
    rect=QRectF(0,layout['button_y'],w,30)
    p.setPen(Qt.PenStyle.NoPen);p.setBrush(fill);p.drawRoundedRect(rect,7,7)
    text(p,rect,'查看用量统计  ↗',12,'#ffffff' if light else '#102116',True,Qt.AlignmentFlag.AlignCenter)
    live=any(row['id']==event['id'] for row in meter.attention_events)
    if live:panel.hits.append((rect,('attention',event['id'],'usage')))
    y=layout['queue_y']
    for other in meter.attention_events:
        if other['id']==event['id']:continue
        text(p,QRectF(0,y,w,26),QFontMetricsF(font(11)).elidedText(other['vendor']+' · '+other.get('summary',''),Qt.TextElideMode.ElideRight,w),11,'secondary')
        panel.hits.append((QRectF(0,y,w,28),('attention',other['id'],'select')));y+=30
