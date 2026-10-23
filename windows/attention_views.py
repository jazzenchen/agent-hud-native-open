"""PermissionAlertDetailView / completion card, in the shared Windows shell.

Layout and decisions translate the original alert views. This module has no
client execution and never decides a permission merely by entering the card.
"""
from pathlib import PureWindowsPath
import math
from PySide6.QtCore import Qt,QRectF
from PySide6.QtGui import QColor,QPen,QFontMetricsF


def geometry(event,w):
    from views import font
    if event['kind']=='quota':
        button_y=236 if event.get('other_limits') else 218
        return dict(button_y=button_y,queue_y=button_y+42,inset_height=0)
    if event['kind']=='reset_credits':return dict(button_y=178,queue_y=220,inset_height=0)
    if event['kind']!='permission':return dict(button_y=206,queue_y=248,inset_height=68)
    detail=event.get('detail') or ''
    if event.get('removed') or event.get('added'):
        detail='\n'.join(['− '+line for line in event.get('removed','').splitlines()[:6]]+['+ '+line for line in event.get('added','').splitlines()[:6]])
    metrics=QFontMetricsF(font(11));lines=max(1,min(12 if event.get('removed') or event.get('added') else 6,
        math.ceil(metrics.boundingRect(QRectF(0,0,max(1,w-44),10000),int(Qt.TextFlag.TextWordWrap),detail).height()/max(1,metrics.lineSpacing()))))
    inset=lines*14+16;buttons=76+inset+12+(18 if event.get('suggestions') else 0)
    return dict(button_y=buttons,queue_y=buttons+38,inset_height=inset,detail=detail)


def height(meter):
    event=meter.attention_event();layout=geometry(event,meter.panel.content_width()-36)
    return layout['queue_y']+max(0,len(meter.attention_events)-1)*30


def paint(panel,p,w,event):
    if event['kind'] in ('quota','reset_credits'):
        from quota_alert_views import paint as news
        news(panel,p,w,event);return
    from views import text,color,font,artwork,compact
    meter=panel.meter;live=any(row['id']==event['id'] for row in meter.attention_events)
    permission=event['kind']=='permission';accent=color('warning' if permission else '#0a84ff',painter=p)
    layout=geometry(event,w)
    def ink(alpha):
        value=color('text',painter=p);value.setAlpha(round(255*alpha));return value.name(QColor.NameFormat.HexArgb)
    if permission:
        text(p,QRectF(2,0,w-70,18),'待审批',11,'secondary',True)
        text(p,QRectF(w-60,0,60,18),'⋯',12,'secondary',align=Qt.AlignmentFlag.AlignRight)
        p.setPen(Qt.PenStyle.NoPen);p.setBrush(color('secondary',painter=p))
        from PySide6.QtCore import QPointF
        for x in (w-14,w-10,w-6):p.drawEllipse(QPointF(x,9),.8,.8)
        text(p,QRectF(w-82,0,40,18),str(sum(row['kind']=='permission' for row in meter.attention_events)),10,accent.name(),True,Qt.AlignmentFlag.AlignRight)
    else:
        if not panel.reminder.draw(p,event['vendor'],QRectF(0,0,24,24)):artwork().draw(p,event['vendor'],QRectF(0,0,24,24))
        text(p,QRectF(34,0,w-160,18),event['vendor'],13,'text',True)
        text(p,QRectF(34,18,w-160,16),event.get('model') or event['vendor'],11,ink(.45))
        text(p,QRectF(w-120,0,88,24),'有新回复',12,'#0a84ff')
        text(p,QRectF(w-24,0,24,24),'×',12,ink(.65),align=Qt.AlignmentFlag.AlignCenter)
    if permission and live:panel.hits.append((QRectF(w-30,0,30,22),('attention',event['id'],'inspect')))
    if not permission and live:panel.hits.append((QRectF(w-30,0,30,22),('attention',event['id'],'dismiss')))
    if permission and not panel.reminder.draw(p,event['vendor'],QRectF(12,35,13,13)):artwork().draw(p,event['vendor'],QRectF(12,35,13,13))
    project=PureWindowsPath(event.get('cwd') or '').name or event['vendor']
    name=project if permission else event['vendor']
    if permission:text(p,QRectF(33,31,w-140,24),QFontMetricsF(font(12,True)).elidedText(name,Qt.TextElideMode.ElideRight,w-140),12,'text',True)
    tool=(event.get('tool') or 'TOOL').rsplit('__',1)[-1]
    badge={'Bash':'BASH','Edit':'EDIT','Write':'EDIT','MultiEdit':'EDIT','apply_patch':'EDIT','Read':'READ','Glob':'FIND','Grep':'FIND','WebFetch':'WEB','AskUserQuestion':'ASK','ExitPlanMode':'PLAN'}.get(tool,tool.upper()[:6]) if permission else event.get('model') or ''
    if permission:text(p,QRectF(w-100,33,88,20),badge,10,accent.name(),True,Qt.AlignmentFlag.AlignRight)
    if permission:
        cwd=event.get('cwd') or ''
        text(p,QRectF(12,54,w-24,15),QFontMetricsF(font(10)).elidedText(cwd,Qt.TextElideMode.ElideMiddle,w-24),10,'tertiary')
        detail=layout['detail']
        inset=QColor('#08000000' if meter.light() else '#0cffffff')
        p.setPen(Qt.PenStyle.NoPen);p.setBrush(inset);p.drawRoundedRect(QRectF(12,76,w-24,layout['inset_height']),7,7)
        p.save();p.setClipRect(QRectF(22,82,w-44,layout['inset_height']-12))
        text(p,QRectF(22,82,w-44,layout['inset_height']-12),detail,11,ink(.8),align=Qt.AlignmentFlag.AlignLeft|Qt.AlignmentFlag.AlignTop|Qt.TextFlag.TextWordWrap)
        p.restore()
        if event.get('suggestions'):
            rule=event['suggestions'][0]
            label=', '.join(r['toolName']+('('+str(r.get('ruleContent'))+')' if r.get('ruleContent') else '') for r in rule['rules'])
            text(p,QRectF(12,layout['button_y']-19,w-24,17),QFontMetricsF(font(9)).elidedText(label,Qt.TextElideMode.ElideMiddle,w-24),9,'tertiary')
    else:
        text(p,QRectF(0,62,w,42),event.get('summary') or event['vendor'],15,'text',False,Qt.AlignmentFlag.AlignLeft|Qt.AlignmentFlag.AlignTop|Qt.TextFlag.TextWordWrap)
        text(p,QRectF(0,112,w,58),event.get('message') or '一轮会话已完成。',12,ink(.68),align=Qt.AlignmentFlag.AlignLeft|Qt.AlignmentFlag.AlignTop|Qt.TextFlag.TextWordWrap)
        if event['id'] in meter.attention_navigation_failed:
            text(p,QRectF(12,183,w-24,18),'无法回到会话，请重试或查看 Token 用量',10,'critical')
    def button(x,width,label,action,role='quiet'):
        rect=QRectF(x,layout['button_y'],width,22 if permission else 28)
        button_ink=color('ok' if role in ('allow','allow_rule') else 'critical' if role=='deny' else '#0a84ff' if role=='primary' else 'secondary',painter=p)
        if role=='allow':
            from source_design import DESIGN
            button_ink=QColor(DESIGN['status_colors']['ok'])
        fill=QColor(button_ink);fill.setAlpha(255 if role in ('allow','primary') else 0 if role=='allow_rule' else 28)
        p.setPen(QPen(button_ink if role in ('deny','allow_rule') else QColor('transparent'),.8));p.setBrush(fill);p.drawRoundedRect(rect,6,6)
        text(p,rect,label,11 if permission else 10,'#102116' if role=='allow' else '#ffffff' if role=='primary' else button_ink.name(),True,Qt.AlignmentFlag.AlignCenter)
        if live:panel.hits.append((rect,('attention',event['id'],action)))
    if permission:
        if event.get('questions'):button(w-121,109,'回答问题…','question','allow')
        elif event.get('plan'):button(w-121,109,'审阅计划…','plan','allow')
        else:
            button(12,60,'拒绝','deny','deny')
            if event.get('suggestions'):
                button(w-208,90,'总是允许','always','allow_rule')
            button(w-112,100,'批准一次','allow','allow')
    else:
        button(12,112,'查看 Token 用量','usage')
        if getattr(meter,'attention_can_navigate',lambda _:False)(event):button(w-130,118,'回到会话','navigate','primary')
    y=layout['queue_y']
    for other in meter.attention_events:
        if other['id']==event['id']:continue
        text(p,QRectF(12,y,w-24,26),QFontMetricsF(font(11)).elidedText(other['vendor']+' · '+other.get('summary',''),Qt.TextElideMode.ElideRight,w-24),11,'secondary')
        panel.hits.append((QRectF(0,y,w,28),('attention',other['id'],'select')));y+=30


def show_dialog(meter,event,kind):
    from PySide6.QtWidgets import QDialog,QVBoxLayout,QPlainTextEdit,QLabel,QCheckBox,QRadioButton,QLineEdit,QDialogButtonBox,QButtonGroup
    from theme import apply_widget_theme
    dialog=QDialog();dialog.setWindowTitle(event['vendor']+' · '+('回答问题' if kind=='question' else '审阅计划' if kind=='plan' else '完整请求'))
    dialog.resize(620,520);apply_widget_theme(dialog,meter.light())
    layout=QVBoxLayout(dialog);layout.setContentsMargins(20,20,20,20);layout.setSpacing(12)
    fields=[];accept_edits=None;note=None
    if kind=='question':
        from PySide6.QtWidgets import QScrollArea,QWidget
        area=QScrollArea();area.setWidgetResizable(True);body=QWidget();form=QVBoxLayout(body)
        for question in event['questions']:
            label=QLabel(question['question']);label.setWordWrap(True);form.addWidget(label)
            group=QButtonGroup(dialog);group.setExclusive(not question['multi']);options=[]
            for option in question['options']:
                control=QCheckBox(option['label']) if question['multi'] else QRadioButton(option['label'])
                control.setToolTip(option.get('description') or '');group.addButton(control);form.addWidget(control);options.append(control)
            custom=QLineEdit();custom.setPlaceholderText('也可以输入自己的回答');form.addWidget(custom)
            fields.append((question,options,custom))
        form.addStretch();area.setWidget(body);layout.addWidget(area)
    else:
        import json
        editor=QPlainTextEdit();editor.setReadOnly(True);editor.setPlainText(event.get('plan') if kind=='plan' else json.dumps(event.get('input',{}),ensure_ascii=False,indent=2))
        layout.addWidget(editor)
        if kind=='plan':
            accept_edits=QCheckBox('批准后接受本会话的后续文件编辑');accept_edits.setChecked(False);layout.addWidget(accept_edits)
            note=QLineEdit();note.setPlaceholderText('继续规划时的反馈（可选）');layout.addWidget(note)
    buttons=QDialogButtonBox(QDialogButtonBox.StandardButton.Cancel)
    if kind in ('question','plan'):
        confirm=buttons.addButton('提交回答' if kind=='question' else '批准计划',QDialogButtonBox.ButtonRole.AcceptRole)
        if kind=='question':
            def valid():confirm.setEnabled(all(any(control.isChecked() for control in controls) or custom.text().strip() for _,controls,custom in fields))
            for _,controls,custom in fields:
                for control in controls:control.toggled.connect(valid)
                custom.textChanged.connect(valid)
            valid()
        if kind=='plan':
            keep=buttons.addButton('继续规划',QDialogButtonBox.ButtonRole.RejectRole)
            keep.clicked.connect(lambda:meter.attention_callback(event['id'],'keep_planning',note=note.text()))
        def accepted():
            if kind=='question':
                answers={q['question']:', '.join([control.text() for control in controls if control.isChecked()]+([custom.text().strip()] if custom.text().strip() else [])) for q,controls,custom in fields}
                answers={key:value for key,value in answers.items() if value}
                meter.attention_callback(event['id'],'answer',answers=answers)
            else:meter.attention_callback(event['id'],'approve_plan',accept_edits=accept_edits.isChecked())
        buttons.accepted.connect(accepted)
    else:buttons.addButton(QDialogButtonBox.StandardButton.Close)
    buttons.accepted.connect(dialog.accept);buttons.rejected.connect(dialog.reject);layout.addWidget(buttons)
    if not hasattr(meter,'attention_dialogs'):meter.attention_dialogs=[]
    dialog.setProperty('attention_id',event['id'])
    meter.attention_dialogs.append(dialog)
    dialog.finished.connect(lambda _:meter.attention_dialogs.remove(dialog) if dialog in meter.attention_dialogs else None)
    dialog.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose);dialog.show();dialog.raise_();dialog.activateWindow()


def dispatch(meter,identifier,action):
    event=next((row for row in meter.attention_events if row['id']==identifier),None)
    if event is None:return
    if action=='select':meter.selected_attention=identifier;meter.panel.animate(meter.panel.progress);meter.panel.update();return
    if action in ('inspect','question','plan'):show_dialog(meter,event,action);return
    if action=='always':
        rule=event['suggestions'][0]
        meter.attention_callback(identifier,'always',update=rule)
        return
    if action=='usage':
        if hasattr(meter,'usage_callback'):meter.usage_callback(event['vendor'],meter.group_data.get(event['vendor'],meter.data))
        if event['kind'] in ('quota','reset_credits'):meter.attention_callback(identifier,'dismiss')
        return
    if action=='navigate':
        if getattr(meter,'attention_navigate',lambda _:False)(event):meter.attention_callback(identifier,'dismiss')
        else:meter.attention_navigation_failed.add(identifier);meter.panel.update()
        return
    meter.attention_callback(identifier,action)
