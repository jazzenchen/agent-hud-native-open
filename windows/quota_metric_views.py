"""Original compact measure picker and row text for the native painted panel."""
import time
from datetime import datetime,timedelta
from decimal import Decimal
from PySide6.QtCore import Qt,QRectF,QPointF
from PySide6.QtGui import QPainterPath,QPen,QColor
from quota_metrics import MEASURES
from quota_insights import number,outlook


def picker(panel,p,w,client):
    from views import color,text
    current=panel.measure(client);offered=panel.measures(client)
    if len(offered)==1:return
    available=min(len(offered)*22-2,86 if w<300 else len(offered)*22-2)
    button=(available-2*(len(offered)-1))/len(offered);x=w-available
    for index,metric in enumerate(offered):
        rect=QRectF(x+index*(button+2),0,button,18)
        if current==metric:
            fill=color('text',painter=p);fill.setAlpha(round(.12*255))
            p.setPen(Qt.PenStyle.NoPen);p.setBrush(fill);p.drawRoundedRect(rect,5,5)
        ink='text' if current==metric else 'tertiary'
        if metric in ('quota','consumed','cost'):
            text(p,rect,dict(quota='%',consumed='Σ',cost='$')[metric],9,ink,True,Qt.AlignmentFlag.AlignCenter)
        elif metric=='tokens':
            p.setPen(QPen(color(ink,painter=p),1));p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawArc(rect.adjusted(5,4,-5,-4),0,180*16)
            p.drawLine(QPointF(rect.center().x(),12),QPointF(rect.center().x()+3,6))
        else:
            cx=rect.center().x();path=QPainterPath();path.moveTo(cx,3)
            path.cubicTo(cx+1,7,cx+5,7,cx+3,12);path.cubicTo(cx,17,cx-6,12,cx-3,8);path.lineTo(cx-2,10);path.closeSubpath()
            p.setPen(Qt.PenStyle.NoPen);p.setBrush(color(ink,painter=p));p.drawPath(path)
        panel.hits.append((rect,('metric',client,metric)))


def short(value):
    value=float(value)
    for divisor,suffix in ((1000000000,'B'),(1000000,'M'),(1000,'k')):
        if value>=divisor:
            scaled=value/divisor;return (f'{scaled:.0f}' if scaled>=10 else f'{scaled:.1f}')+suffix
    return f'{value:g}'


def money(value,currency):
    symbol=dict(USD='$',CNY='¥').get(currency,currency+' ')
    amount=Decimal(str(value));cents=amount.quantize(Decimal('.01'))
    if cents==0 and amount>0:return '<'+symbol+'0.01'
    return symbol+(f'{cents:,.0f}' if abs(cents)>=100 else f'{cents:.2f}')


def forecast_time(at,now):
    date=datetime.fromtimestamp(at);today=datetime.fromtimestamp(now)
    if at-now>=7*86400:return f'{date.month}月{date.day}日 '+date.strftime('%H:%M')
    monday=today.date()-timedelta(days=today.weekday());other=date.date()-timedelta(days=date.weekday())
    weeks=max(0,(other-monday).days//7)
    return '下'*min(3,weeks)+'周'+'一二三四五六日'[date.weekday()]+' '+date.strftime('%H:%M')


def presentation(row,metric,fresh=True,now=None):
    from views import reset_label
    now=time.time() if now is None else now;used=number(row.get('used'))
    fraction=0 if used is None else min(1,max(0,used/100))
    result=dict(value='—',detail='—',fraction=fraction,warning=False)
    if metric=='quota':return dict(result,value='—' if used is None else f'{used:.0f}%',detail=reset_label(row.get('reset'),now))
    if not fresh or used is None:return result
    metrics=row.get('metrics') or {}
    if metric=='burn':
        insight=row.get('insights') or {};rate=number(insight.get('rate'));prediction=outlook(row,now)
        detail=dict(untimed='—',no_estimate='暂无预测',no_usage='暂无消耗',sampling='记录不足',exhausted='已耗尽').get(prediction['state'],'—')
        if prediction['state']=='sampling' and insight.get('required'):
            detail='重新采样' if insight.get('after_reset') else '采样中'
        warning=prediction['state']=='exhausted' or prediction.get('before_reset',False)
        if prediction['state']=='exhausts':
            detail=forecast_time(now+prediction['interval'],now) if warning else f'重置时 {prediction["projected"]:.0f}%' if prediction.get('projected') is not None else '记录不足'
        return dict(result,value='—' if rate is None else f'{rate:.1f}%/h',detail=detail,
                    warning=warning,fraction=1 if warning else (prediction.get('projected') or used)/100)
    if metric=='tokens' and (reply:=metrics.get('reply')):
        rate=reply['tokens_per_second'];return dict(result,value=f'{rate:.1f}/s' if rate<10 else f'{int(rate)}/s',detail=f'{reply["calls"]} 次回复')
    if metric=='consumed' and (consumed:=metrics.get('consumed')):
        detail='/ '+short(consumed['capacity']) if consumed.get('capacity') is not None else short(metrics['tokens_per_hour'])+'/h' if metrics.get('tokens_per_hour') is not None else '—'
        return dict(result,value=short(consumed['used']),detail=detail)
    if metric=='cost' and (cost:=metrics.get('cost')):
        currencies=sorted(cost['amounts']);first=currencies[0];others=currencies[1:]
        detail='+ '+' + '.join(money(cost['amounts'][key],key) for key in others) if others else money(Decimal(cost['amounts'][first])/Decimal(str(cost['hours'])),first)+'/h'
        return dict(result,value=money(cost['amounts'][first],first),detail=detail)
    return result
