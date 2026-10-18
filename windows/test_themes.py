"""Audit actual pixels and the persisted settings -> window/material path."""
import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import json,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock,patch
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication,QMenu,QScrollArea
from PySide6.QtTest import QTest
from application import Application,UsageWindow
from settings_window import SettingsWindow
from settings_controls import Segmented
from preferences import load
from theme import window_is_light,resolves_light
from views import SimpleMeterView,reset_label

DATA=dict(local=dict(sessions=[]),quota=dict(windows=[dict(label='Weekly',used=37)]))

class ThemeAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=QApplication.instance() or QApplication([]);cls.app.setStyle('Fusion')

    def manager(self):
        directory=Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(patch('application.DATA',directory))
        manager=Application.__new__(Application);manager.app=self.app
        manager.settings=load(dict(appearance='dark',hud_appearance='dark',glass=False))
        manager.config=directory/'settings.json';manager.windows={};manager.dialogs=[]
        manager.settings_window=None;manager.tray=Mock();manager.monitor=Mock();manager.data={'Codex':DATA}
        manager.tray_menu=manager.menu()
        screen=self.app.primaryScreen()
        meter=SimpleMeterView('Codex',screen,manager.screen_settings(screen.name()),lambda _:None,preview=True)
        manager.windows[(screen.name(),'Codex')]=meter
        manager.settings_window=SettingsWindow(manager)
        manager.update(manager.data)
        self.addCleanup(lambda:(meter.hide_all(),meter.glow.close(),meter.panel.close(),meter.close(),manager.settings_window.close()))
        return manager,meter

    def pixel(self,widget,x,y):
        widget.show();self.app.processEvents()
        if isinstance(widget,SettingsWindow):
            widget.transition.animation.stop();widget.transition.effect.setOpacity(1.)
        return widget.grab().toImage().pixelColor(x,y)

    def test_ui_click_changes_real_window_menu_statistics_and_saved_value(self):
        manager,meter=self.manager();settings=manager.settings_window
        settings.sidebar.setCurrentRow(0);settings.show();self.app.processEvents()
        dark=self.pixel(settings,500,12)
        choice=settings.findChild(Segmented,'appearance')
        QTest.mouseClick(choice.buttons[1],Qt.MouseButton.LeftButton);self.app.processEvents()
        light=self.pixel(settings,500,12)
        self.assertLess(dark.lightness(),70);self.assertGreater(light.lightness(),230)
        self.assertEqual(json.loads(manager.config.read_text())['appearance'],'light')
        self.assertTrue(manager.tray_menu.property('uiLight'))
        for action in manager.tray_menu.actions():
            if action.menu():self.assertTrue(action.menu().property('uiLight'))
        stats=UsageWindow('Codex',DATA);manager.dialogs.append(stats);self.addCleanup(stats.close)
        manager.refresh_themes();self.assertGreater(self.pixel(stats,5,5).lightness(),230)
        manager.apply_setting('appearance','dark')
        self.assertFalse(manager.tray_menu.property('uiLight'));self.assertLess(self.pixel(stats,5,5).lightness(),70)
        # General appearance is the window/menu scope; HUD has its own explicit control.
        self.assertFalse(meter.light())

    def test_display_theme_changes_existing_meter_and_open_panel_and_reloads(self):
        manager,meter=self.manager();meter.panel.progress=1;meter.panel.animate(1);meter.panel.show()
        before=self.pixel(meter,meter.width()-5,meter.height()//2)
        panel_before=self.pixel(meter.panel,meter.panel.width()-5,50)
        screen=meter.screen.name();manager.apply_setting('hud_appearance','light',screen)
        after=self.pixel(meter,meter.width()-5,meter.height()//2)
        panel_after=self.pixel(meter.panel,meter.panel.width()-5,50)
        self.assertLess(before.lightness(),40);self.assertGreater(after.lightness(),230)
        self.assertLess(panel_before.lightness(),40);self.assertGreater(panel_after.lightness(),230)
        recovered=load(json.loads(manager.config.read_text()))
        self.assertEqual(recovered['placements'][screen]['hud_appearance'],'light')
        manager.settings=recovered;manager.update(manager.data);self.assertTrue(meter.light())

    def test_material_is_reapplied_to_an_already_open_panel(self):
        manager,meter=self.manager();meter.preview=False;meter.settings['glass']=True
        meter.panel.show()
        with patch('views.frosted_backdrop',return_value=True) as native:
            meter.apply_material();native.reset_mock();meter.settings['hud_appearance']='light';meter.apply_material()
            calls=[call.args for call in native.call_args_list]
            self.assertEqual(len(calls),2)
            self.assertTrue(all(args[3] is True for args in calls))
            self.assertTrue(meter.native_glass);self.assertTrue(meter.panel.native_glass)
        meter.preview=True

    def test_per_monitor_override_and_system_following_have_explicit_resolution(self):
        settings=load(dict(appearance='dark',match_screen=True))
        self.assertTrue(window_is_light(settings,dict(hud_appearance='light'),False))
        self.assertFalse(window_is_light(settings,dict(hud_appearance='system'),False))
        self.assertTrue(resolves_light('system',True));self.assertFalse(resolves_light('system',False))

    def test_reset_label_is_a_countdown_not_a_calendar_date(self):
        self.assertEqual(reset_label(10000+7200+180,now=10000),'2时 3分')
        self.assertEqual(reset_label(9999,now=10000),'重置中')

    def test_live_menu_updates_provider_rows_and_dispatches_the_correct_client(self):
        manager,_=self.manager();menu=manager.tray_menu
        manager.data={};manager.populate_menu(menu)
        self.assertFalse(any(action.menu() for action in menu.actions()))
        manager.data={'Codex':DATA};manager.populate_menu(menu)
        agent=next(action.menu() for action in menu.actions() if action.menu())
        manager.show_usage=Mock();agent.actions()[-1].trigger()
        manager.show_usage.assert_called_once_with('Codex',DATA)

if __name__=='__main__':unittest.main()
