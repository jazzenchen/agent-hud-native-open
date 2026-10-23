"""AccountSection / AccountWalletRow counterparts, without credential reads."""
import math,time
from usage_display import window_account
from quota_insights import number


def sections(quota):
    """First-row order, one anonymous scope, no merging by account label."""
    current=quota.get('account') or {};current_id=current.get('id','')
    identities={value['id']:value for value in quota.get('accounts',[]) if isinstance(value,dict) and value.get('id')}
    if current_id:identities[current_id]={**identities.get(current_id,{}),**current}
    grouped={}
    def ensure(key,observation=None):
        if key not in grouped:
            account=observation or identities.get(key)
            is_current=account.get('is_current',account.get('isCurrent',key==current_id if current_id else True)) if account else True
            reading={**quota,'windows':[],'wallets':[],'accounts':[],'account':account,'credit_balance':None}
            if key!=current_id:
                reading['plan']=(account or {}).get('plan_label') or (account or {}).get('plan')
                reading['at']=(account or {}).get('observed_at')
            else:reading['plan']=(account or {}).get('plan_label') or (account or {}).get('plan') or quota.get('plan')
            grouped[key]=dict(id=key,account=account,is_current=bool(is_current),quota=reading)
        return grouped[key]
    for row in quota.get('windows',[]):
        observation=row.get('account') if isinstance(row.get('account'),dict) else None
        key=window_account(row) or current_id
        ensure(key,observation)['quota']['windows'].append(row)
    for wallet in quota.get('wallets',[]):
        key=window_account(wallet) or current_id
        ensure(key)['quota']['wallets'].append(wallet)
    if quota.get('credit_balance'):
        ensure(current_id)['quota']['credit_balance']=quota['credit_balance']
    if not grouped and current_id:ensure(current_id)
    return list(grouped.values())


def wallet_labels(wallet):
    from billing_metrics import money
    def amount(key):
        value=number(wallet.get(key));return money(value,str(wallet.get('currency') or 'USD')) if value is not None else 'N/A'
    if wallet.get('kind') in ('onDemand','on_demand'):
        return '按需付费','已用 '+amount('used')+' · 上限 '+amount('limit')
    return '预付余额',amount('balance')


def reading_label(section,now=None):
    quota=section['quota'];account=section.get('account') or {}
    if section['is_current'] and not quota.get('stale') and not quota.get('error_code') and not account.get('warning'):return '当前账户'
    now=time.time() if now is None else now;at=number(quota.get('at'))
    total=max(0,int(math.floor(max(0,now-(at if at is not None else now))+.5)));hours,minutes=divmod(total//60,60)
    ago=f'{hours}h' if hours and minutes==0 else f'{hours}h {minutes:02d}m' if hours else f'{minutes}m'
    return '上次读取 '+ago+' 前'


def header_lines(section,width,half=False):
    from views import font
    from PySide6.QtGui import QFontMetricsF
    from PySide6.QtCore import Qt
    account=section.get('account') or {};quota=section['quota'];fm=QFontMetricsF(font(11))
    label=str(account.get('label') or account.get('display_name') or '账户身份未确认')
    plan=str(quota.get('plan') or '')
    status=reading_label(section)
    plan=fm.elidedText(plan,Qt.TextElideMode.ElideRight,max(0,width-12-20-fm.horizontalAdvance(status)-20))
    reserved=fm.horizontalAdvance(plan)+(6 if plan else 0)
    if half and fm.horizontalAdvance(label)+reserved+fm.horizontalAdvance(status)+8>width-12:status=''
    status_width=fm.horizontalAdvance(status)
    label=fm.elidedText(label,Qt.TextElideMode.ElideMiddle,max(20,width-12-reserved-status_width-8))
    details=[]
    warning=account.get('warning') or (quota.get('error_message') if section['is_current'] else None)
    notice=account.get('notice')
    if quota.get('stale') and section['is_current'] and not warning:warning='上次成功读数，正在重试'
    from quota_cells import _name_lines
    for value,ink in ((warning,'warning'),(notice if notice!=warning else None,'secondary')):
        if value:
            lines,line_height=_name_lines(str(value),str(value),width-12,11)
            for line in lines[:2]:details.append((line,ink,line_height))
    return dict(label=label,plan=plan,status=status,status_width=status_width,details=details,height=15+sum(part[2]+2 for part in details))


def paint_header(panel,p,width,section,half=False):
    from views import text,font
    from PySide6.QtGui import QFontMetricsF
    from PySide6.QtCore import QRectF,Qt
    values=header_lines(section,width,half);name_width=QFontMetricsF(font(11)).horizontalAdvance(values['label'])
    p.save();p.setOpacity(p.opacity()*(.85 if section['is_current'] else .6))
    text(p,QRectF(6,0,name_width,15),values['label'],11,'text');p.restore()
    text(p,QRectF(12+name_width,0,max(0,width-name_width-values['status_width']-26),15),values['plan'],11,'secondary')
    text(p,QRectF(width-values['status_width']-6,0,values['status_width'],15),values['status'],11,'tertiary',align=Qt.AlignmentFlag.AlignRight)
    y=15
    for line,ink,height in values['details']:text(p,QRectF(6,y,width-12,height),line,11,ink);y+=height+2
    return values['height']


def wallet_height(wallet,width,half=False):
    from PySide6.QtGui import QFontMetricsF
    from views import font
    name,amount=wallet_labels(wallet)
    return 36 if half and QFontMetricsF(font(12,True)).horizontalAdvance(amount)+QFontMetricsF(font(12)).horizontalAdvance(name)+36>width else 22


def paint_wallet(p,width,wallet,half=False):
    from views import text,color
    from PySide6.QtCore import QRectF,Qt,QPointF
    from PySide6.QtGui import QPen
    name,amount=wallet_labels(wallet);height=wallet_height(wallet,width,half)
    p.setPen(QPen(color('tertiary',painter=p),1));p.setBrush(Qt.BrushStyle.NoBrush)
    if wallet.get('kind') in ('onDemand','on_demand'):
        p.drawEllipse(QRectF(6,7,8,8));text(p,QRectF(6,7,8,8),'$',7,'tertiary',align=Qt.AlignmentFlag.AlignCenter)
    else:
        p.drawRoundedRect(QRectF(6,7,9,7),1,1);p.drawLine(QPointF(6,9),QPointF(15,9))
    text(p,QRectF(26,0,width-32,22),name,12,'secondary')
    text(p,QRectF(26,16 if height>22 else 0,width-32,20),amount,12,'text',True,Qt.AlignmentFlag.AlignLeft if height>22 else Qt.AlignmentFlag.AlignRight)
    return height
