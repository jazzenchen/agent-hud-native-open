"""Original compact TokenBarsChart geometry on indexed local model buckets."""
import time
from PySide6.QtCore import Qt,QRectF
from PySide6.QtGui import QPainterPath,QColor

EMPTY_REPORT={}

def series(panel,client,data,period):
    from stats_widgets import columns
    hours={'day':24,'week':168,'month':720}[period]
    local=data.get('local',{});stats=local.get('history_stats') or local.get('stats') or EMPTY_REPORT
    now=time.time()
    cache=getattr(panel,'_chart_series',{});panel._chart_series=cache
    previous=cache.get((client,period))
    # Retain the report object, so Python object-ID reuse cannot serve old data.
    if previous and previous[0] is stats and previous[1]==int(now//900):return previous[2]
    models=sorted({row['model'] for row in stats.get('model_buckets',[])})
    rows=columns(stats,hours,now=now)
    by_model={model:columns({'buckets':[row for row in stats['model_buckets'] if row['model']==model]},hours,now=now) for model in models}
    result=dict(rows=rows,models=models,by_model=by_model,total=sum(row['total'] for row in rows),reported=bool(stats.get('event_count')))
    cache[(client,period)]=(stats,int(now//900),result)
    return result


def paint(panel,p,width,client,data,block):
    from stats_widgets import model_colors
    from views import color,text,compact
    from panel_plan import spacing_metrics
    values=series(panel,client,data,block['period']);rows=values['rows'];models=values['models']
    palette=model_colors(panel.meter.light());top=spacing_metrics(panel.layout().get('style',{}).get('spacing','regular'))['chartTop']
    plot=QRectF(6,top,width-12,40);peak=max(1,max((row['total'] for row in rows),default=0));step=plot.width()/max(1,len(rows))
    p.fillRect(QRectF(plot.left(),plot.bottom()-1,plot.width(),1),color('divider',painter=p))
    for index,row in enumerate(rows):
        if not row['total']:continue
        gap=min(2,step*.2);x=plot.left()+index*step+gap/2;bottom=plot.bottom()-1
        height=row['total']/peak*(plot.height()-2);clip=QPainterPath();clip.addRoundedRect(QRectF(x,bottom-height,step-gap,height),2,2)
        p.save();p.setClipPath(clip,Qt.ClipOperation.IntersectClip)
        parts=[(palette[i%len(palette)],values['by_model'][model][index]['total']) for i,model in enumerate(models)] if models else [(color('secondary',painter=p),row['total'])]
        for ink,amount in parts:
            part=amount/peak*(plot.height()-2);bottom-=part;p.fillRect(QRectF(x,bottom,step-gap,part),QColor(ink))
        p.restore()
        panel.hits.append((QRectF(plot.left()+index*step,plot.top(),step,plot.height()),('metric_hint',time.strftime('%m-%d %H:%M',time.localtime(row['at']))+'\n'+compact(row['total'])+' Tokens · 本机已观测记录')))
    if not values['total']:text(p,plot,'此时间窗口内没有 Token 消耗' if values['reported'] else '暂无可读取的 Token 记录',11,'secondary',align=Qt.AlignmentFlag.AlignCenter)
    return top+40
