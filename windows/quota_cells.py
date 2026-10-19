"""Native painting counterpart of the original QuotaCell / QuotaCellGrid.

Measurements are shared by layout and painting. Names wrap instead of eliding;
captions give way to their short form and then to a reserved blank line.
"""
import math,time
from functools import lru_cache
from PySide6.QtCore import Qt,QRectF
from PySide6.QtGui import QFontMetricsF,QTextLayout,QTextOption,QPen
from panel_plan import grid_geometry,cell_width
from quota_insights import number
from quota_metric_views import presentation

RINGS={'small':(40,3,10),'medium':(46,4,11),'large':(60,5,13)}


def window_names(row):
    # Localization.modelLabel / shortModelLabel deliberately keep quota names
    # in English in both languages. Provider-supplied short names take priority.
    raw=str(row.get('label') or row.get('id') or '—')
    full={'Desktop / CLI':'Account quota','CLI':'Account quota','window.session':'Current session','window.weekly':'Weekly limit · All models'}.get(raw,raw)
    if raw.startswith('window.weekly.'):full='Weekly limit · '+raw[len('window.weekly.'):]
    fallback={'Desktop / CLI':'Quota','CLI':'Quota','window.session':'5h','window.weekly':'Weekly'}.get(raw)
    if fallback is None:fallback=(raw[len('window.weekly.'):] if raw.startswith('window.weekly.') else raw).split()[0] if raw.split() else raw
    short=str(row.get('short_name') or row.get('shortName') or fallback)
    return full,short


def name_lines(row,width,size):
    full,short=window_names(row)
    return _name_lines(full,short,width,size)


@lru_cache(maxsize=512)
def _name_lines(full,short,width,size):
    from views import font
    metrics=QFontMetricsF(font(size))
    for value in (full,short):
        if metrics.horizontalAdvance(value)<=width:return (value,),math.ceil(metrics.height())
    layout=QTextLayout(short,font(size));option=QTextOption()
    option.setWrapMode(QTextOption.WrapMode.WrapAtWordBoundaryOrAnywhere);layout.setTextOption(option)
    layout.beginLayout();lines=[]
    while True:
        line=layout.createLine()
        if not line.isValid():break
        line.setLineWidth(max(1,width))
        # QTextLayout indices count UTF-16 code units, while Python counts
        # Unicode scalars. Keep astral characters intact when wrapping names.
        encoded=short.encode('utf-16-le');start=line.textStart()*2
        lines.append(encoded[start:start+line.textLength()*2].decode('utf-16-le'))
    layout.endLayout()
    return tuple(lines) or ('—',),math.ceil(metrics.height())


def fitting(values,width,size):
    from views import font
    metrics=QFontMetricsF(font(size))
    return next((value for value in values if value and metrics.horizontalAdvance(value)<=width),'')


def geometry(rows,width,block,spacing='regular'):
    columns=block.get('columns',4);count=min(columns,max(1,len(rows)))
    cell=cell_width(width,columns if len(rows)>columns else count)
    heights=[];names=[];ring=block['widget']=='ring'
    for row in rows:
        lines,line_height=name_lines(row,cell,12 if ring else 11);names.append((lines,line_height))
        heights.append((min(cell,RINGS[block.get('ringSize','medium')][0])+10 if ring else 6+19)+len(lines)*line_height+14)
    rects,height=grid_geometry(heights,width,columns,spacing)
    return rects,names,height


def paint(panel,p,width,rows,quota,block,metric,spacing='regular'):
    from views import color,text,level,font
    rects,names,height=geometry(rows,width,block,spacing)
    at=number(quota.get('at'));fresh=not quota.get('stale') and not quota.get('error_code') and at is not None and 0<=time.time()-at<=1800
    for row,rect,(lines,line_height) in zip(rows,rects,names):
        p.save();p.translate(rect['x'],rect['y']);w=rect['width']
        used=number(row.get('used'));shown=presentation(row,metric,fresh)
        caption=shown['detail'] if metric!='quota' or block.get('countdown',True) else ''
        warning=metric=='burn' and shown['warning'];ink='secondary' if shown['value']=='—' else level(used) if metric=='quota' else 'warning' if warning else 'ok'
        ring=block['widget']=='ring';y=0
        if ring:
            diameter,stroke,figure=RINGS[block.get('ringSize','medium')];diameter=min(w,diameter)
            bounds=QRectF((w-diameter)/2+stroke/2,stroke/2,diameter-stroke,diameter-stroke)
            p.setBrush(Qt.BrushStyle.NoBrush);p.setPen(QPen(color('track',painter=p),stroke));p.drawEllipse(bounds)
            if used is not None:
                fraction=max(0,min(1,used/100))
                if metric=='burn' and shown['fraction']>fraction:
                    tint=color('warning' if warning else 'secondary',painter=p);tint.setAlphaF(tint.alphaF()*.38)
                    p.setPen(QPen(tint,stroke,Qt.PenStyle.SolidLine,Qt.PenCapStyle.RoundCap));p.drawArc(bounds,90*16,round(-min(1,shown['fraction'])*360*16))
                p.setPen(QPen(color(level(used),painter=p),stroke,Qt.PenStyle.SolidLine,Qt.PenCapStyle.RoundCap))
                if fraction:p.drawArc(bounds,90*16,round(-fraction*360*16))
            share='—' if used is None else f'{used:.0f}%'
            text(p,QRectF(0,0,w,diameter),share,figure,'secondary' if used is None else level(used),True,Qt.AlignmentFlag.AlignCenter)
            y=diameter+5
        for line in lines:
            text(p,QRectF(0,y,w,line_height),line,12 if ring else 11,'text' if ring else 'secondary',ring,Qt.AlignmentFlag.AlignCenter if ring else Qt.AlignmentFlag.AlignLeft)
            y+=line_height
        if ring:y+=5
        else:
            y+=3
            value=shown['value'];short=value
            if metric=='burn' and value!='—':short=f'{float(value.split("%")[0]):.0f}%/h'
            if metric=='cost' and (cost:=row.get('metrics',{}).get('cost')):
                from quota_metric_views import short as compact
                first=sorted(cost['amounts'])[0];short=dict(USD='$',CNY='¥').get(first,first+' ')+compact(cost['amounts'][first])
            # Never elide an actual figure. Source's short candidate normally
            # fits; exceptionally large figures reserve their intrinsic width.
            value=fitting((value,short),w,15) or short
            text(p,QRectF(0,y,max(w,QFontMetricsF(font(15,True)).horizontalAdvance(value)),19),value,15,ink,True)
            y+=22
        long_caption=shown['value']+(' · '+caption if caption else '') if ring and metric!='quota' else caption
        displayed=fitting((long_caption,shown['value'] if ring and metric!='quota' else ''),w,11)
        text(p,QRectF(0,y,w,14),displayed,11,'warning' if warning else 'secondary',align=Qt.AlignmentFlag.AlignCenter if ring else Qt.AlignmentFlag.AlignLeft)
        p.restore()
        spoken=', '.join(value for value in ((('—' if used is None else f'{used:.0f}%') if ring and metric!='quota' else ''),shown['value'],caption) if value)
        panel.hits.append((QRectF(rect['x'],rect['y'],w,rect['height']),('metric_hint',str(row.get('label',''))+'\n'+spoken)))
    return height
