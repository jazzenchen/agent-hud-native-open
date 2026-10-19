import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import json,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock,patch
from PySide6.QtWidgets import QApplication,QPushButton,QCheckBox
from application import Application
from preferences import load
from settings_window import SettingsWindow
from agent_catalog import VENDORS,detect_sources


class SettingsCases(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def manager(self):
        manager=Application.__new__(Application);manager.app=self.app;manager.settings=load({});manager.data={};manager.preview=True;manager.windows={}
        manager.tray=Mock();manager.monitor=Mock();manager.menu=Mock();manager.update=Mock();manager.refresh_themes=Mock()
        directory=Path(self.enterContext(tempfile.TemporaryDirectory()));manager.config=directory/'settings.json'
        return manager

    def test_upstream_inventory_is_complete_and_detection_never_runs_a_client(self):
        self.assertEqual(len(VENDORS),18);self.assertIn('Claude',VENDORS);self.assertIn('Antigravity',VENDORS);self.assertIn('WorkBuddy',VENDORS)
        with tempfile.TemporaryDirectory() as folder,patch('subprocess.Popen',side_effect=AssertionError('must not launch')):
            home=Path(folder);(home/'.codebuddy').mkdir()
            rows=detect_sources({'Codex'},home,process_names={'cursor.exe'},which=lambda _:None)
            by_name={row['vendor']:row for row in rows}
            self.assertTrue(by_name['CodeBuddy']['installed']);self.assertFalse(by_name['CodeBuddy']['running'])
            self.assertFalse(by_name['Cursor']['running']);self.assertTrue(by_name['Codex']['running'])
            self.assertFalse(by_name['Claude']['installed'])

    def test_equal_named_account_windows_have_independent_visibility_and_order(self):
        from usage_display import visible_quota,window_key
        from agents_page import WindowOrderList
        manager=self.manager()
        rows=[dict(label=label,account_id=account,used=10) for account in ('a','b') for label in ('5h','Weekly')]
        quota=dict(windows=rows,accounts=[dict(id=key,label=key) for key in ('a','b')])
        manager.data={'Codex':dict(quota=quota,local={})}
        manager.settings['hidden_windows']={'Codex':['5h']}
        window=SettingsWindow(manager);self.addCleanup(window.close);page=window.agent_page
        page.toggle_window('Codex',window_key(rows[0]),True)
        visible=visible_quota(quota,'Codex',manager.settings)['windows']
        self.assertIn(rows[0],visible);self.assertNotIn(rows[2],visible)
        views=page.findChildren(WindowOrderList);self.assertEqual(len(views),2)
        for view in views:
            view.model().moveRow(view.rootIndex(),0,view.rootIndex(),2);view.persist()
        order=manager.settings['window_order']['Codex'];self.assertEqual(len(set(order)),4)
        self.assertEqual([window_key(row) for row in visible_quota(quota,'Codex',{**manager.settings,'hidden_windows':{}})['windows']],
                         [window_key(rows[i]) for i in (1,0,3,2)])

    def test_source_glow_fields_and_ring_controls_follow_current_mode(self):
        manager=self.manager();screen=self.app.primaryScreen().name()
        manager.settings['placements'][screen]=dict(mode='notch',glow_style='dots',glow_effect='flow')
        window=SettingsWindow(manager);self.addCleanup(window.close)
        from PySide6.QtCore import QObject
        def names():return {child.objectName() for child in window.stack.widget(2).findChildren(QObject)}
        self.assertIn('grid_pitch',names());self.assertNotIn('glow_depth',names())
        self.assertNotIn('glow_outward',names());self.assertNotIn('logo_size',names())
        manager.settings['placements'][screen]=dict(mode='simple',show_rings=False)
        window.rebuild();self.assertNotIn('ring_width',names())
        manager.settings['placements'][screen]=dict(mode='logos',glow_style='blur',glow_effect='breathe')
        window.rebuild();self.assertIn('glow_depth',names());self.assertIn('glow_outward',names())

    def test_style_reset_and_revert_survive_restart_without_resetting_panel_layout(self):
        manager=self.manager();screen=self.app.primaryScreen().name()
        original=dict(mode='logos',size=40,glass=False,transparency=20,solid_transparency=20,panel_width=680)
        manager.settings['placements'][screen]=original.copy()
        window=SettingsWindow(manager);self.addCleanup(window.close);window.reset_style()
        self.assertEqual(manager.screen_settings(screen)['panel_width'],680)
        self.assertTrue(window.stack.widget(2).findChild(QPushButton,'revert_layout').isEnabled())
        manager.settings=load(json.loads(manager.config.read_text()));manager.change_screen_layout(screen,'revert')
        self.assertEqual(manager.settings['placements'][screen],original)

    def test_materials_keep_separate_transparency_and_migrate_legacy_settings(self):
        manager=self.manager();screen=self.app.primaryScreen().name()
        manager.settings=load(dict(placements={screen:dict(glass=True,transparency=73)}))
        manager.apply_screen_settings(dict(glass=False),screen);self.assertEqual(manager.screen_settings(screen)['transparency'],0)
        manager.apply_screen_settings(dict(transparency=25),screen)
        manager.apply_screen_settings(dict(glass=True),screen);self.assertEqual(manager.screen_settings(screen)['transparency'],73)
        manager.apply_screen_settings(dict(glass=False),screen);self.assertEqual(manager.screen_settings(screen)['transparency'],25)
        recovered=load(json.loads(manager.config.read_text()))['placements'][screen]
        self.assertEqual((recovered['glass_transparency'],recovered['solid_transparency']),(73,25))

    def test_shared_layout_preserves_style_and_revert_restores_custom_layout(self):
        manager=self.manager();screen=self.app.primaryScreen().name()
        manager.settings['placements'][screen]=dict(size=40,panel_width=680,panel_sessions=False)
        manager.change_screen_layout(screen,'shared');self.assertEqual(manager.screen_settings(screen)['size'],40)
        self.assertEqual(manager.screen_settings(screen)['panel_width'],540)
        manager.change_screen_layout(screen,'revert');self.assertEqual(manager.screen_settings(screen)['panel_width'],680)
        self.assertFalse(manager.screen_settings(screen)['panel_sessions'])

    def test_provider_reorder_persists_without_enabling_closed_clients(self):
        manager=self.manager();manager.windows={};manager.data={'Codex':dict(quota={},local={}), 'Cursor':dict(quota={},local={})}
        window=SettingsWindow(manager);self.addCleanup(window.close);page=window.agent_page
        first=page.list.takeItem(0);page.list.insertItem(1,first)
        with patch('settings_window.QMessageBox.warning',side_effect=lambda *args:(_ for _ in ()).throw(RuntimeError(args[-1]))):page.persist_order()
        saved=load(json.loads(manager.config.read_text()))
        self.assertEqual(saved['provider_order'][:2],['Cursor','Codex'])
        self.assertEqual(set(saved['enabled_clients']),set(manager.settings['enabled_clients']))

    def test_window_order_and_account_visibility_controls_persist(self):
        from agents_page import WindowOrderList
        manager=self.manager();manager.windows={};manager.data={'Codex':dict(quota=dict(account=dict(id='account',label='Personal',evidence='account'),windows=[dict(label='5h',used=10),dict(label='Weekly',used=30)]),local={})}
        window=SettingsWindow(manager);self.addCleanup(window.close);page=window.agent_page
        row=next(i for i in range(page.list.count()) if page.list.item(i).data(256)['vendor']=='Codex');page.select(row)
        choices=page.findChildren(WindowOrderList);view=choices[-1]
        # moveRows follows the same model operation as InternalMove drag, preserving controls.
        view.model().moveRow(view.rootIndex(),0,view.rootIndex(),2);view.persist()
        page.toggle_account('account',False)
        saved=load(json.loads(manager.config.read_text()))
        self.assertEqual(saved['window_order']['Codex'],['Weekly','5h']);self.assertEqual(saved['hidden_accounts'],['account'])
        page.toggle_account('account',True);self.assertFalse(manager.settings['hidden_accounts'])

    def test_agent_page_has_full_inventory_and_supported_provider_switches(self):
        manager=self.manager();window=SettingsWindow(manager);self.addCleanup(window.close)
        page=window.agent_page;self.assertEqual(page.list.count(),18)
        index=next(i for i in range(page.list.count()) if page.list.item(i).data(256)['vendor']=='Antigravity')
        page.list.setCurrentRow(index);self.app.processEvents()
        self.assertIsNotNone(page.findChild(QCheckBox,'agent_enabled_Antigravity'))
        index=next(i for i in range(page.list.count()) if page.list.item(i).data(256)['vendor']=='Claude')
        page.list.setCurrentRow(index);self.app.processEvents()
        self.assertIsNotNone(page.findChild(QCheckBox,'agent_enabled_Claude'))

    def test_live_status_switch_preserves_collection_and_history(self):
        manager=self.manager();window=SettingsWindow(manager);self.addCleanup(window.close)
        page=window.agent_page;before=set(manager.settings['enabled_clients'])
        page.toggle_live_status('Codex',False)
        self.assertEqual(set(manager.settings['enabled_clients']),before)
        self.assertIn('Codex',manager.settings['disabled_live_status_sources'])
        page.toggle_live_status('Codex',True)
        self.assertNotIn('Codex',manager.settings['disabled_live_status_sources'])

if __name__=='__main__':unittest.main()
