"""Compact APIBillingCard / BillingBlock painted with the source's columns."""
import time
from PySide6.QtCore import QRectF,Qt
from PySide6.QtGui import QFontMetricsF
from panel_plan import spacing_metrics
from billing_metrics import figures,level,decimal


def account_geometry(panel,width,account,block,now):
    minute=int(now//60);spacing=panel.layout().get('style',{}).get('spacing','regular')
    key=(block['key'],account['id'],width,block['widget'],tuple(block['measures']),block['period'],block['span'],spacing,minute)
    cache=getattr(panel,'_billing_geometry_cache',{});previous=cache.get(key)
    if previous and previous[0] is account:return previous[1]
    value=_account_geometry(panel,width,account,block,now)
    if len(cache)>32:cache={stored:entry for stored,entry in cache.items() if stored[-1]==minute}
    if len(cache)>32:cache={}
    cache[key]=(account,value);panel._billing_geometry_cache=cache
    return value


def _account_geometry(panel,width,account,block,now):
    from views import font
    from quota_cells import _name_lines
    spacing=spacing_metrics(panel.layout().get('style',{}).get('spacing','regular'));y=20;notice=[]
    if account.get('notice'):
        lines,line_height=_name_lines(str(account['notice']),str(account['notice']),width-32,11)
        notice=[(line,line_height) for line in lines[:2]];y+=spacing['blockParts']+len(notice)*line_height
    rows=[];balances=account.get('balances') or [dict(currency='CNY',balance=None)]
    for balance in balances:
        y+=spacing['blockParts'];options=[figures(account,balance,metric,block['period'],now) for metric in block['measures']]
        widest=max((max(QFontMetricsF(font(11)).horizontalAdvance(caption),QFontMetricsF(font(15,True)).horizontalAdvance(value)) for pair in options for caption,value,_ in pair),default=0)
        stacked=block['span']=='half' and 2*widest+24>width-32
        row_height=70+spacing['blockParts'] if stacked else 35
        if block['widget']=='chart':row_height=35+spacing['chartTop']+40
        rows.append(dict(y=y,balance=balance,stacked=stacked,height=row_height));y+=row_height
    return dict(height=y,notice=notice,rows=rows)


def height(panel,width,data,block):
    spacing=spacing_metrics(panel.layout().get('style',{}).get('spacing','regular'));accounts=data['billing_accounts']
    return sum(account_geometry(panel,width,account,block,time.time())['height'] for account in accounts)+max(0,len(accounts)-1)*(spacing['blocks']+spacing['divided'])


def paint(panel,p,width,key,data,block):
    from views import artwork,text,color,divider
    from quota_metric_views import picker
    now=time.time();spacing=spacing_metrics(panel.layout().get('style',{}).get('spacing','regular'));y=0
    for index,account in enumerate(data['billing_accounts']):
        if index:
            if panel.layout().get('style',{}).get('separators',True):divider(p,y+spacing['divided'],width)
            y+=spacing['blocks']+spacing['divided']
        first_hit=len(panel.hits);p.save();p.translate(0,y)
        geometry=account_geometry(panel,width,account,block,now)
        vendor=account['provider'];title=vendor+' · API';artwork().draw(p,account['vendor'],QRectF(6,2,14,14))
        picker_width=min(len(block['measures'])*22-2,86 if width<300 else 108) if index==0 and len(block['measures'])>1 else 0
        text(p,QRectF(26,0,width-picker_width-34,20),title,13,'text',True)
        if picker_width:picker(panel,p,width,key)
        note_y=20+spacing['blockParts']
        for line,line_height in geometry['notice']:text(p,QRectF(26,note_y,width-32,line_height),line,11,'warning');note_y+=line_height
        for row in geometry['rows']:
            balance=row['balance'];pair=figures(account,balance,panel.measure(key),block['period'],now)
            if block['widget']=='chart':pair=(figures(account,balance,'cost',block['period'],now)[0],)
            for side,(caption,value,ink) in enumerate(pair):
                x=26 if row['stacked'] else 26+side*((width-32-24)/2+24)
                top=row['y']+side*(35+spacing['blockParts']) if row['stacked'] else row['y']
                col_width=width-32 if row['stacked'] or block['widget']=='chart' else (width-32-24)/2
                text(p,QRectF(x,top,col_width,14),caption,11,'secondary')
                text(p,QRectF(x,top+17,col_width,18),value,15,ink,True)
            hint='余额来自服务方；费用仅估算本机已记录请求，并非实付账单。'
            if not account.get('legacy'):hint+=' 仅使用此账户明确归属的记录。'
            panel.hits.append((QRectF(26,row['y'],width-32,row['height']),('metric_hint',hint)))
            if block['widget']=='chart':
                currency=balance.get('currency') or 'CNY';metrics=account.get('periods',{}).get(currency,{}).get(block['period'])
                columns=metrics.get('columns',[]) if metrics else [];plot=QRectF(6,row['y']+35+spacing['chartTop'],width-12,40)
                peak=max([decimal(column.get('amount')) or 0 for column in columns]+[1e-12]);step=plot.width()/max(1,len(columns))
                p.fillRect(QRectF(plot.left(),plot.bottom()-1,plot.width(),1),color('divider',painter=p))
                for column_index,column in enumerate(columns):
                    amount=decimal(column.get('amount'))
                    if amount is None or amount<=0:continue
                    bar_height=float(amount/decimal(peak))*38;gap=min(2,step*.2);x=plot.left()+column_index*step+gap/2
                    p.setPen(Qt.PenStyle.NoPen);p.setBrush(color(level(account,balance,now) or 'secondary',painter=p));p.drawRoundedRect(QRectF(x,plot.bottom()-1-bar_height,step-gap,bar_height),2,2)
                if not metrics or metrics.get('cost') is None:text(p,plot,'暂无价格',11,'secondary',align=Qt.AlignmentFlag.AlignCenter)
                elif decimal(metrics['cost'])==0:text(p,plot,'此时间窗口内没有费用',11,'secondary',align=Qt.AlignmentFlag.AlignCenter)
        p.restore()
        for hit_index in range(first_hit,len(panel.hits)):
            rect,action=panel.hits[hit_index];panel.hits[hit_index]=(rect.translated(0,y),action)
        y+=geometry['height']
    return y
