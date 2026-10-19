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
