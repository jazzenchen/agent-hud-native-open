"""SourcesPane's provider list and detail column, backed by passive discovery."""
from PySide6.QtCore import Qt,QRectF,QSize,QTimer,QPointF
from PySide6.QtGui import QColor,QPainter,QFont
from PySide6.QtWidgets import QWidget,QVBoxLayout,QHBoxLayout,QListWidget,QListWidgetItem,QLabel,QPushButton,QStyledItemDelegate,QStyle,QScrollArea,QMessageBox,QAbstractItemView
from agent_catalog import detect_sources,VENDORS,SUPPORTED
from settings_controls import Switch,SettingRows,CardSurface,is_light
from theme import tokens
from views import artwork


class ProviderList(QListWidget):
    def dropEvent(self,event):
        target=self.itemAt(event.position().toPoint())
        if target is None or not target.data(Qt.ItemDataRole.UserRole)['installed']:event.ignore();return
        super().dropEvent(event)


class ProviderDelegate(QStyledItemDelegate):
    def paint(self,p,option,index):
        row=index.data(Qt.ItemDataRole.UserRole);t=tokens(is_light(self.parent()))
        rect=QRectF(option.rect).adjusted(5,2,-5,-2)
        p.save();p.setRenderHint(QPainter.RenderHint.Antialiasing);p.setPen(Qt.PenStyle.NoPen)
        if option.state & QStyle.StateFlag.State_Selected:
            p.setBrush(QColor('#dceafa' if t['light'] else '#2b3f53'));p.drawRoundedRect(rect,7,7)
        if row['installed']:
            p.setPen(QColor(t['muted']))
            for y in (-2,1):p.drawLine(QPointF(rect.left()+5,rect.center().y()+y),QPointF(rect.left()+14,rect.center().y()+y))
        artwork().draw(p,row['vendor'],QRectF(rect.left()+24,rect.center().y()-10,20,20),1 if row['installed'] else .4,light=t['light'])
        name=QFont('Segoe UI');name.setPixelSize(12);name.setWeight(QFont.Weight.DemiBold if option.state & QStyle.StateFlag.State_Selected else QFont.Weight.Normal);p.setFont(name)
        p.setPen(QColor(t['ink'] if row['installed'] else t['muted']))
        p.drawText(rect.adjusted(52,6,-3,-19),Qt.AlignmentFlag.AlignLeft|Qt.AlignmentFlag.AlignVCenter|Qt.TextFlag.TextWordWrap,row['vendor'])
        name.setPixelSize(10);name.setWeight(QFont.Weight.Normal);p.setFont(name);p.setPen(QColor(t['muted']))
        p.drawText(rect.adjusted(52,rect.height()-19,-3,-2),Qt.AlignmentFlag.AlignLeft|Qt.AlignmentFlag.AlignVCenter,'运行中' if row['running'] else '已安装' if row['installed'] else '未检测到')
        p.restore()


class AgentsPage(QWidget):
    def __init__(self,settings):
        super().__init__();self.settings=settings;self.manager=settings.manager;self.signature=None
        root=QHBoxLayout(self);root.setContentsMargins(0,0,0,0);root.setSpacing(20)
        left=QWidget();left.setFixedWidth(152);column=QVBoxLayout(left);column.setContentsMargins(0,0,0,0);column.setSpacing(12)
        count=QLabel(f'{len(VENDORS)} 个智能体');count.setProperty('subtitle',True);column.addWidget(count)
        self.list=ProviderList();self.list.setObjectName('providerList');self.list.setItemDelegate(ProviderDelegate(self.list))
        self.list.setDragDropMode(QAbstractItemView.DragDropMode.InternalMove);self.list.setDefaultDropAction(Qt.DropAction.MoveAction)
        self.list.model().rowsMoved.connect(lambda *args:QTimer.singleShot(0,self.persist_order))
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff);column.addWidget(self.list,1)
        tip=QLabel('拖动分组或窗口，调整光晕和面板中的顺序。');tip.setProperty('subtitle',True);tip.setWordWrap(True);column.addWidget(tip)
        root.addWidget(left);right=QWidget();right_column=QVBoxLayout(right);right_column.setContentsMargins(0,0,0,0);right_column.setSpacing(12)
        refresh=QPushButton('刷新账户');refresh.setProperty('smallAction',True);refresh.clicked.connect(self.refresh_accounts);right_column.addWidget(refresh,0,Qt.AlignmentFlag.AlignRight)
        self.detail=QWidget();self.detail_layout=QVBoxLayout(self.detail);self.detail_layout.setContentsMargins(0,0,8,32);self.detail_layout.setSpacing(22)
        details=QScrollArea();details.setWidgetResizable(True);details.setFrameShape(QScrollArea.Shape.NoFrame);details.setWidget(self.detail)
        details.setStyleSheet('QScrollArea,QScrollArea>QWidget>QWidget{background:transparent;border:0}')
        details.viewport().setAutoFillBackground(False)
        right_column.addWidget(details,1);root.addWidget(right,1)
        self.list.currentRowChanged.connect(self.select);self.refresh()
        self.timer=QTimer(self);self.timer.setInterval(10000);self.timer.timeout.connect(self.refresh)
        self.setMinimumHeight(350)

    def showEvent(self,event):
        super().showEvent(event);self.refresh();self.timer.start()
    def hideEvent(self,event):
        self.timer.stop();super().hideEvent(event)
    def refresh_accounts(self):
        self.manager.refresh_now();self.refresh(force=True)
    def refresh(self,force=False):
        if not getattr(self.manager,'preview',False):
            from runtime import running_clients
            active=running_clients()
        else:active=self.manager.data
        rows=([dict(vendor=vendor,installed=vendor in self.manager.data,running=vendor in self.manager.data,supported=vendor in SUPPORTED) for vendor in VENDORS]
              if getattr(self.manager,'preview',False) else detect_sources(active))
        order=self.manager.settings.get('provider_order',VENDORS)
        rows.sort(key=lambda row:(not row['installed'],order.index(row['vendor'])))
        signature=tuple((row['vendor'],row['installed'],row['running'],repr(self.manager.data.get(row['vendor'],{}).get('quota',{})),self.manager.data.get(row['vendor'],{}).get('local',{}).get('stats',{}).get('event_count')) for row in rows)
        if signature==self.signature and not force:return
        self.signature=signature;selected=getattr(self.settings,'selected_provider',next(iter(self.manager.data),'Claude'))
        self.list.blockSignals(True);self.list.clear();target=0
        for i,row in enumerate(rows):
            item=QListWidgetItem();item.setData(Qt.ItemDataRole.UserRole,row);item.setSizeHint(QSize(140,64 if len(row['vendor'])>11 else 50));self.list.addItem(item)
            if not row['installed']:item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsDragEnabled & ~Qt.ItemFlag.ItemIsDropEnabled)
            if row['vendor']==selected:target=i
        self.list.setCurrentRow(target);self.list.blockSignals(False);self.select(target)

    def section(self,title,subtitle=None):
        group=QWidget();column=QVBoxLayout(group);column.setContentsMargins(0,0,0,0);column.setSpacing(12)
        heading=QLabel(title);heading.setProperty('sectionTitle',True);column.addWidget(heading)
        if subtitle:
            note=QLabel(subtitle);note.setProperty('subtitle',True);note.setWordWrap(True);column.addWidget(note)
        card=CardSurface();form=SettingRows(card);column.addWidget(card);self.detail_layout.addWidget(group);return form

    def select(self,index):
        if index<0:return
        row=self.list.item(index).data(Qt.ItemDataRole.UserRole);vendor=row['vendor'];self.settings.selected_provider=vendor
        while self.detail_layout.count():
            item=self.detail_layout.takeAt(0)
            if item.widget():item.widget().deleteLater()
        data=self.manager.data.get(vendor,{})
        if row['supported']:
            quota=data.get('quota',{});account=quota.get('account') or {}
            form=self.section('账户')
            from usage_display import account_label
            name=QLabel(account_label(quota));name.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse);name.setWordWrap(True)
            form.addRow('上次读数账户' if quota.get('stale') else '当前账户',name)
            identities=quota.get('accounts') or ([account] if account else [])
            for identity in identities:
                evidence='服务方确认' if identity.get('evidence')=='account' else '本地资料' if identity.get('evidence')=='profile' else '凭据独立范围，身份未确认'
                label=QLabel(evidence if len(identities)==1 else identity.get('label','')+' · '+evidence);label.setWordWrap(True)
                form.addRow('识别依据',label) if len(identities)==1 else form.addRow(label)
            if quota.get('plan'):form.addRow('订阅',QLabel(str(quota['plan'])))
            for wallet in quota.get('wallets',[]):
                form.addRow('余额',QLabel(f"{wallet.get('currency','')} {wallet['balance']:.2f}"))
            if quota.get('stale'):form.addRow(QLabel('当前显示上次成功读数，正在重试。'))
            try:
                from providers import DATA
                from usage_ledger import UsageLedger
                history=UsageLedger(DATA/'usage-ledger.sqlite').report(vendor).get('accounts',[]) if not getattr(self.manager,'preview',False) else []
                for previous in history[:4]:
                    if previous['id']!=account.get('id'):form.addRow('曾识别账户',QLabel(previous['label']))
            except Exception:pass
            form=self.section('显示窗口')
            switch=Switch();switch.setObjectName('agent_enabled_'+vendor);switch.setChecked(vendor in self.manager.settings['enabled_clients']);switch.setAccessibleName(vendor)
            switch.toggled.connect(lambda on:self.toggle(vendor,on));form.addRow(vendor,switch)
            if vendor=='GitHub Copilot':
                consent=Switch();consent.setObjectName('read_copilot_quota');consent.setChecked(self.manager.settings.get('read_copilot_quota',False))
                consent.toggled.connect(lambda on:self.copilot_consent(consent,on));form.addRow('读取 GitHub Copilot 额度',consent)
            if quota.get('windows'):
                for window in quota['windows']:
                    choice=Switch();choice.setChecked(window['label'] not in self.manager.settings.get('hidden_windows',{}).get(vendor,[]))
                    choice.setAccessibleName(vendor+' '+window['label']);choice.toggled.connect(lambda on,label=window['label']:self.toggle_window(vendor,label,on))
                    form.addRow(window['label'],choice)
            else:
                from quota_state import quota_notice
                note=QLabel(quota_notice(quota,vendor) if row['running'] else '打开客户端后，自动读取当前账户和额度。');note.setProperty('subtitle',True);note.setWordWrap(True);form.addRow(note)
        form=self.section('接入状态')
        state='运行中' if row['running'] else '已安装' if row['installed'] else '未检测到'
        status=QLabel(state);form.addRow(vendor,status)
        from provider_registry import QUOTA_VENDORS
        detail=('官方计划额度已接入；Token 由实际使用计划的客户端记录。' if vendor=='GLM' else '账户额度、会话与 Token 已接入；只在客户端运行时读取。' if vendor in QUOTA_VENDORS else '本地会话与 Token 已接入；账户额度请以上方实际接入状态为准。') if row['supported'] else '已检测到本机客户端或资料；额度和会话接入尚未完成。' if row['installed'] else '安装客户端后自动检测；额度和会话接入尚未完成。'
        note=QLabel(detail);note.setProperty('subtitle',True);note.setWordWrap(True);form.addRow(note)
        self.detail_layout.addStretch()

    def toggle(self,vendor,on):
        values=set(self.manager.settings['enabled_clients']);values.add(vendor) if on else values.discard(vendor)
        self.settings.write('enabled_clients',sorted(values))
    def persist_order(self):
        self.settings.write('provider_order',[self.list.item(i).data(Qt.ItemDataRole.UserRole)['vendor'] for i in range(self.list.count())])
    def copilot_consent(self,switch,on):
        if on and QMessageBox.question(self,'读取 GitHub Copilot 额度？','将读取 GitHub CLI 登录信息（GH_TOKEN、GITHUB_TOKEN、Windows 凭据管理器中的 gh:github.com 或 GitHub CLI 的 hosts.yml），向 api.github.com 查询 Copilot 额度。',QMessageBox.StandardButton.Yes|QMessageBox.StandardButton.Cancel,QMessageBox.StandardButton.Cancel)!=QMessageBox.StandardButton.Yes:
            switch.blockSignals(True);switch.setChecked(False);switch.blockSignals(False);return
        self.settings.write('read_copilot_quota',on)
    def toggle_window(self,vendor,label,on):
        values={key:list(labels) for key,labels in self.manager.settings.get('hidden_windows',{}).items()};hidden=set(values.get(vendor,[]))
        hidden.discard(label) if on else hidden.add(label);values[vendor]=sorted(hidden);self.settings.write('hidden_windows',values)
