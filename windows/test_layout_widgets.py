import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import errno,json,tempfile,unittest
from pathlib import Path
from copy import deepcopy
from unittest.mock import Mock,patch
from PySide6.QtCore import Qt,QObject
from PySide6.QtWidgets import QApplication,QPushButton
from PySide6.QtTest import QTest
from PySide6.QtGui import QColor
from application import Application
from preferences import load
from panel_layout import LayoutStore
from views import SimpleMeterView


class LayoutWidgets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def meter(self,writer=None):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load({}),lambda _:None,preview=True)
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
        meter.layout_store=LayoutStore(writer=writer)
        meter.set_data(dict(quota=dict(account={'id':'a'},windows=[dict(id=str(i),label='Quota '+str(i),used=10) for i in range(20)]),
                            local=dict(sessions=[dict(id='s',title='Test session',state='done',updated=1,tokens=1)])))
        meter.show();meter.open_panel();meter.panel.animation.jump(1.)
        return meter
    def manager(self):
        manager=Application.__new__(Application);manager.app=self.app;manager.settings=load({});manager.data={};manager.windows={};manager.settings_window=None
        manager.update=Mock();manager.refresh_themes=Mock();manager.tray=Mock();manager.menu=Mock();manager.preview=True
        folder=self.enterContext(tempfile.TemporaryDirectory());manager.config=Path(folder)/'settings.json'
        return manager

    def test_actual_draft_buttons_save_and_discard_even_when_all_sections_hidden(self):
        writes=[];meter=self.meter(writes.append);panel=meter.panel;store=meter.layout_store
        store.propose({'hiddenSections':['blocks','tokens','sessions']});panel.set_data(meter.data);panel.grab()
        bar=panel.draft_bar;self.assertTrue(bar.isVisible());self.assertTrue(panel.section_order()==[])
        self.assertLess(bar.geometry().bottom(),panel.height()-28)
        save=bar.findChild(QPushButton,'island-layout-save')
        QTest.mousePress(save,Qt.MouseButton.LeftButton);self.assertEqual(writes,[])
        QTest.mouseRelease(save,Qt.MouseButton.LeftButton)
        self.assertFalse(store.has_draft());self.assertEqual(writes[-1]['shared']['current']['hiddenSections'],['blocks','tokens','sessions'])
        self.assertFalse(bar.isVisible())
        store.propose({});panel.set_data(meter.data)
        QTest.mouseClick(bar.findChild(QPushButton,'island-layout-discard'),Qt.MouseButton.LeftButton)
        self.assertEqual(panel.section_order(),[]);self.assertEqual(len(writes),1)

    def test_failed_save_does_not_remove_real_draft_bar_or_lose_previous_state(self):
        def fail(_):raise OSError(errno.ENOSPC,'Disk full')
        meter=self.meter(fail);store=meter.layout_store;panel=meter.panel
        store.propose({'style':{'width':680}});panel.set_data(meter.data);revision=store.revision
        with patch('layout_draft_bar.QMessageBox.warning') as warning:
            QTest.mouseClick(panel.draft_bar.findChild(QPushButton,'island-layout-save'),Qt.MouseButton.LeftButton)
        warning.assert_called_once();self.assertEqual(store.revision,revision);self.assertTrue(panel.draft_bar.isVisible())
        self.assertEqual(panel.content_width(),580);self.assertEqual(store.current,{})

    def test_draft_bar_has_native_keyboard_action(self):
        meter=self.meter();meter.layout_store.propose({'countdown':False});meter.panel.set_data(meter.data)
        save=meter.panel.draft_bar.findChild(QPushButton,'island-layout-save');save.setFocus()
        QTest.keyClick(save,Qt.Key.Key_Space)
        self.assertFalse(meter.layout_store.has_draft());self.assertEqual(meter.layout_store.current,{'countdown':False})

    def test_footer_stays_fixed_while_long_content_scrolls_and_hits_stay_clipped(self):
        meter=self.meter();panel=meter.panel
        self.assertGreater(panel.natural_height(),panel.layout_height());panel.grab()
        before=next(rect.y()-panel.scroll_offset for rect,action in panel.hits if action=='settings')
        panel.scroll_offset=80;panel.grab()
        after=next(rect.y()-panel.scroll_offset for rect,action in panel.hits if action=='settings')
        self.assertEqual(before,after)
        for rect,action in panel.hits:
            if action not in ('settings','details'):self.assertLessEqual(rect.bottom()-panel.scroll_offset,panel.height()-73+1)

    def test_hidden_block_or_rows_do_not_destroy_reading_or_hide_token_source(self):
        meter=self.meter();original=deepcopy(meter.data);store=meter.layout_store
        store.propose({'blocks':{'Codex':{'hidden':True}}});meter.panel.set_data(meter.data)
        self.assertEqual(meter.panel.providers(),[]);self.assertEqual(len(meter.panel.sources()),1)
        self.assertEqual(meter.data,original)
        from usage_display import window_key
        rows=meter.data['quota']['windows'];store.propose({'blocks':{'Codex':{'hiddenRows':[window_key(rows[0])],'rows':[window_key(rows[4])]}}})
        shown=meter.panel.providers()[0][1]['quota']['windows']
        self.assertEqual(shown[0],rows[4]);self.assertNotIn(rows[0],shown);self.assertEqual(meter.data,original)

    def test_application_migrates_real_settings_and_restarts_without_reviving_legacy_fields(self):
        manager=self.manager();screen='screen-A'
        manager.settings.update(panel_tokens=False)
        manager.settings['placements'][screen]={'panel_width':680,'panel_sessions':False,'size':40}
        manager.setup_layouts()
        self.assertEqual(manager.screen_settings(screen)['panel_width'],680);self.assertFalse(manager.screen_settings(screen)['panel_tokens'])
        manager.apply_setting('panel_sessions',True,screen)
        saved=load(json.loads(manager.config.read_text(encoding='utf-8')))
        self.assertIn('layout_documents',saved);self.assertFalse(saved['placements'][screen]['panel_sessions'])
        manager.settings=saved;manager.setup_layouts()
        self.assertTrue(manager.screen_settings(screen)['panel_sessions']);self.assertEqual(manager.screen_settings(screen)['size'],40)
        manager.change_screen_layout(screen,'shared');self.assertEqual(manager.screen_settings(screen)['panel_width'],540)
        manager.change_screen_layout(screen,'revert');self.assertEqual(manager.screen_settings(screen)['panel_width'],680)

    def test_application_failed_atomic_layout_write_preserves_profile_and_draft(self):
        manager=self.manager();manager.setup_layouts();manager.save=Mock(side_effect=OSError(errno.ENOSPC,'Disk full'))
        manager.layouts.propose({'countdown':False});before=deepcopy(manager.settings)
        with self.assertRaisesRegex(RuntimeError,'磁盘空间不足'):manager.layouts.save_panel()
        self.assertEqual(manager.settings,before);self.assertTrue(manager.layouts.has_draft())

    def test_glass_secondary_and_tertiary_are_original_relative_ink_tints(self):
        meter=self.meter();meter.settings.update(hud_appearance='light',glass=True)
        palette=meter.palette_colors();self.assertEqual(QColor(palette['secondary']).alpha(),round(.65*255))
        self.assertEqual(QColor(palette['tertiary']).alpha(),round(.53*255));self.assertEqual(QColor(palette['secondary']).red(),0)
        self.assertIs(palette,meter.palette_colors())
        meter.settings['hud_appearance']='dark';self.assertEqual(QColor(meter.palette_colors()['secondary']).alpha(),round(.6*255))
        self.assertEqual(QColor(meter.palette_colors()['secondary']).red(),255)
        meter.settings.update(glass=False,transparency=0)
        self.assertEqual(QColor(meter.palette_colors()['secondary']).alpha(),255)

    def test_one_offered_measure_has_no_picker_and_replaces_unavailable_selection(self):
        meter=self.meter();panel=meter.panel;panel.metric_selection['Codex']='burn'
        meter.layout_store.propose({'blocks':{'Codex':{'measures':['cost']}}});panel.set_data(meter.data);panel.grab()
        self.assertEqual(panel.measure('Codex'),'cost')
        self.assertFalse([action for _,action in panel.hits if isinstance(action,tuple) and action[0]=='metric'])

    def test_original_shared_layout_settings_row_is_reachable_and_uses_saved_switches(self):
        from settings_window import SettingsWindow
        manager=self.manager();manager.setup_layouts();manager.layouts.propose({'hiddenSections':['tokens']})
        window=SettingsWindow(manager);self.addCleanup(window.close)
        self.assertTrue(window.value('panel_tokens',True))
        self.assertIsNotNone(window.stack.widget(2).findChild(QPushButton,'settings-layout-reset'))
        self.assertIsNone(window.stack.widget(2).findChild(QObject,'panel_width'))
        manager.layouts.save();window.rebuild()
        self.assertFalse(window.value('panel_tokens',True))
        button=window.stack.widget(2).findChild(QPushButton,'settings-layout-revert');self.assertTrue(button.isEnabled())
        QTest.mouseClick(button,Qt.MouseButton.LeftButton)
        self.assertTrue(window.value('panel_tokens',True))

    def test_cells_keep_names_complete_and_keep_height_across_metrics(self):
        from quota_cells import geometry,name_lines
        meter=self.meter();panel=meter.panel
        row=dict(label='Very long quota window with emoji 🎮 and 中文名称',short_name='Very long quota window with emoji 🎮 and 中文名称',used=27)
        lines,_=name_lines(row,65,11)
        self.assertEqual(''.join(lines),row['label'])
        for widget in ('ring','number'):
            meter.layout_store.propose({'blocks':{'Codex':{'widget':widget,'columns':6}}});panel.set_data(meter.data)
            initial=panel.natural_height();panel.grab()
            for metric in ('burn','tokens','consumed','cost','quota'):
                panel.metric_selection['Codex']=metric;panel.grab()
                self.assertEqual(panel.natural_height(),initial)
            hints=[rect for rect,action in panel.hits if isinstance(action,tuple) and action[0]=='metric_hint']
            self.assertEqual(len(hints),20)
            for index,rect in enumerate(hints):
                self.assertTrue(all(not rect.intersects(other) for other in hints[index+1:]))

    def test_paired_cells_follow_source_width_floor_and_separate_agent_rule(self):
        meter=self.meter();panel=meter.panel
        meter.group_data={'Codex':meter.data,'Cursor':deepcopy(meter.data)}
        layout={'style':{'width':540},'blocks':{'Codex':{'widget':'ring','span':'half'},'Cursor':{'widget':'number','span':'half'}}}
        meter.layout_store.propose(layout);meter.settings['separates_agents']=False
        panel.set_data(meter.data);self.assertEqual([len(line) for line in panel.provider_lines()],[2])
        self.assertEqual([block['columns'] for block,_ in panel.provider_lines()[0]],[2,2])
        panel.grab();self.assertTrue(any(rect.left()>250 for rect,action in panel.hits if isinstance(action,tuple) and action[:2]==('metric','Cursor')))
        layout['style']['width']=480;meter.layout_store.propose(layout);panel.set_data(meter.data)
        self.assertEqual([len(line) for line in panel.provider_lines()],[1,1])
        meter.settings['separates_agents']=True;self.assertEqual([len(line) for line in panel.provider_lines()],[1])

    def test_changing_widget_resets_measure_but_same_widget_refresh_keeps_it(self):
        meter=self.meter();panel=meter.panel;panel.measure('Codex')
        panel.metric_selection['Codex']='cost';self.assertEqual(panel.measure('Codex'),'cost')
        panel.set_data(meter.data);self.assertEqual(panel.measure('Codex'),'cost')
        meter.layout_store.propose({'blocks':{'Codex':{'widget':'number'}}})
        self.assertEqual(panel.measure('Codex'),'quota')
        meter.layout_store.propose({'blocks':{'Codex':{'widget':'chart','measures':['quota']}}})
        self.assertEqual(panel.measures('Codex'),['tokens'])

    def test_source_layout_row_key_applies_to_all_accounts_but_settings_keys_stay_separate(self):
        from usage_display import window_key,panel_row_key
        meter=self.meter();rows=[dict(id=account+'/'+window,account_id=account,label=window,used=10) for account in ('a','b') for window in ('week','5h')]
        meter.set_data({'quota':{'windows':rows}})
        self.assertNotEqual(window_key(rows[0]),window_key(rows[2]))
        self.assertEqual(panel_row_key(rows[0]),panel_row_key(rows[2]))
        meter.layout_store.propose({'blocks':{'Codex':{'hiddenRows':['week']}}})
        shown=meter.panel.providers()[0][1]['quota']['windows']
        self.assertEqual([row['id'] for row in shown],['a/5h','b/5h'])

    def test_row_order_does_not_reorder_accounts_and_foreign_wallets_are_filtered(self):
        meter=self.meter()
        data=dict(quota=dict(account=dict(id='a',label='A'),accounts=[dict(id='b',label='B',is_current=False)],
            windows=[dict(id='a/week',account_id='a',label='Weekly',used=10),dict(id='b/5h',account_id='b',label='5h',used=20)],
            wallets=[dict(account_id='a',currency='USD',balance=1),dict(account_id='b',currency='USD',balance=2)]))
        meter.set_data(data);meter.layout_store.propose({'blocks':{'Codex':{'rows':['5h','week'],'widget':'ring'}}})
        shown=meter.panel.providers()[0][1]['quota']
        self.assertEqual([row['account_id'] for row in shown['windows']],['a','b']);meter.panel.grab()
        meter.layout_store.propose({'blocks':{'Codex':{'accounts':['b'],'widget':'number'}}})
        shown=meter.panel.providers()[0][1]['quota']
        self.assertEqual([wallet['balance'] for wallet in shown['wallets']],[2]);meter.panel.grab()

    def test_api_balance_uses_source_billing_key_and_picker_without_quota_percentage(self):
        from billing_metrics import legacy_account
        meter=self.meter();quota=dict(at=__import__('time').time(),windows=[],wallets=[dict(currency='CNY',balance=8.85)],is_available=True)
        account=legacy_account('DeepSeek',quota)
        account['periods']={'CNY':{'day':dict(cost='0.3',per_day='0.3',span=86400,tokens=30,tokens_per_hour=1,columns=[])}}
        meter.set_group_data({'DeepSeek':{'quota':{**quota,'api_billing':[account]}}})
        meter.panel.set_data(meter.data);self.assertEqual(meter.panel.providers(),[])
        self.assertEqual(meter.panel.provider_lines()[0][0][0]['key'],'api:DeepSeek')
        height=meter.panel.natural_height()
        for metric in ('quota','burn','tokens','consumed','cost'):
            meter.panel.metric_selection['api:DeepSeek']=metric;meter.panel.grab()
            self.assertEqual(meter.panel.natural_height(),height)
        self.assertTrue(any(isinstance(action,tuple) and action[:2]==('metric','api:DeepSeek') for _,action in meter.panel.hits))
        meter.layout_store.propose({'blocks':{'api:DeepSeek':{'accounts':['unavailable']}}})
        self.assertEqual(meter.panel.provider_lines(),[])
        self.assertEqual(meter.data['quota']['wallets'][0]['balance'],8.85)

    def test_multi_account_grid_has_separate_lines_instead_of_interleaving_cells(self):
        meter=self.meter();quota=dict(account=dict(id='a',label='Current'),accounts=[dict(id='b',label='Previous',is_current=False)],
            windows=[dict(id='a/5h',account_id='a',label='A-only window',used=10),dict(id='b/week',account_id='b',label='B-only window',used=20)])
        meter.set_data({'quota':quota});meter.layout_store.propose({'blocks':{'Codex':{'widget':'number','columns':4}}});meter.panel.set_data(meter.data);meter.panel.grab()
        hints={action[1].split('\n')[0]:rect for rect,action in meter.panel.hits if isinstance(action,tuple) and action[0]=='metric_hint'}
        self.assertGreater(hints['B-only window'].top(),hints['A-only window'].bottom())

    def test_settings_wallet_rows_preserve_cents_and_do_not_crash_on_on_demand_fields(self):
        from settings_window import SettingsWindow
        from agents_page import AgentsPage
        from PySide6.QtWidgets import QLabel
        manager=self.manager();manager.setup_layouts()
        manager.data={'Grok':{'quota':dict(wallets=[dict(currency='USD',balance=100.25),dict(currency='USD',kind='onDemand',used=0)],windows=[])}}
        window=SettingsWindow(manager);self.addCleanup(window.close);page=window.findChild(AgentsPage)
        index=next(index for index in range(page.list.count()) if page.list.item(index).data(Qt.ItemDataRole.UserRole)['vendor']=='Grok')
        page.select(index)
        labels={label.text() for label in page.findChildren(QLabel)}
        self.assertIn('$100.25',labels);self.assertIn('已用 $0.00 · 上限 N/A',labels)

    def test_simple_meter_and_peek_show_api_money_and_do_not_resurrect_hidden_balance(self):
        import time
        from billing_metrics import legacy_account
        from usage_display import visible_quota
        from PySide6.QtGui import QFontMetricsF
        from views import font
        meter=self.meter();quota=dict(at=time.time(),windows=[],wallets=[dict(currency='CNY',balance=1234.5),dict(currency='USD',balance=0)],is_available=True)
        quota['api_billing']=[legacy_account('DeepSeek',quota)]
        meter.set_group_data({'DeepSeek':{'quota':quota}});meter.grab();meter.peek.refresh()
        self.assertEqual(meter.label,'¥1,234.50');self.assertIsNone(meter._used['DeepSeek'])
        self.assertEqual(meter.peek.rows,[('余额','¥1,234.50',None)]);self.assertEqual(meter.peek.row_inks,['critical'])
        self.assertGreaterEqual(meter.cells[0][1].width()-meter.mark_size-meter.label_spacing,QFontMetricsF(font(meter.figure_size)).horizontalAdvance(meter.label))
        hidden=visible_quota(quota,'DeepSeek',{'hidden_accounts':['DeepSeek']})
        meter.set_group_data({'DeepSeek':{'quota':hidden}});meter.peek.refresh()
        self.assertEqual(meter.label,'–');self.assertEqual(meter.peek.rows,[]);self.assertEqual(meter.panel.billing_providers(),{})
        self.assertEqual(quota['api_billing'][0]['balances'][0]['balance'],1234.5)
        unavailable={'quota':dict(at=time.time(),windows=[],wallets=[],is_available=False)}
        from views import meter_label
        self.assertEqual(meter_label('DeepSeek',unavailable),('–','critical'))

    def test_peek_omits_previous_accounts_and_deduplicates_current_short_names(self):
        meter=self.meter();meter.set_data(dict(quota=dict(account=dict(id='a',label='Current'),accounts=[dict(id='b',label='Old',is_current=False)],
            windows=[dict(label='Previous only',account_id='b',used=99),dict(label='Current window',short_name='5h',account_id='a',used=10),dict(label='Duplicate window',short_name='5h',account_id='a',used=20)])))
        meter.peek.refresh();self.assertEqual(meter.peek.rows,[('5h','10%',10)])

    def test_failed_settings_toggle_rebuilds_from_saved_layout(self):
        from settings_window import SettingsWindow
        from PySide6.QtWidgets import QCheckBox
        manager=self.manager();manager.setup_layouts();manager.save=Mock(side_effect=OSError(errno.ENOSPC,'Disk full'))
        window=SettingsWindow(manager);self.addCleanup(window.close)
        switch=window.stack.widget(2).findChild(QCheckBox,'panel_tokens')
        with patch('settings_window.QMessageBox.warning') as warning:
            switch.setChecked(False);QTest.qWait(10)
        warning.assert_called_once()
        self.assertTrue(window.stack.widget(2).findChild(QCheckBox,'panel_tokens').isChecked())
        self.assertTrue(manager.saved_screen_settings(window.selected_screen)['panel_tokens'])


if __name__=='__main__':unittest.main()
