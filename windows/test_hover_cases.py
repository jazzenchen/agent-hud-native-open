import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import unittest
from unittest.mock import patch
from PySide6.QtCore import Qt,QPoint
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from simple_geometry import simple_geometry
from preferences import load
from views import SimpleMeterView
from source_design import DESIGN

DATA=dict(quota=dict(windows=[dict(label='Weekly',used=42)]),local=dict(sessions=[]))

class HoverCases(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])

    def meter(self,**settings):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load(settings),lambda _:None,preview=True)
        meter.set_group_data({'Codex':DATA,'Cursor':DATA});meter.place(200,100);meter.show()
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
        return meter

    def test_source_ringless_dimensions_and_numberless_gap(self):
        ringless=simple_geometry(22,'top',False,True,.45,[16])
        self.assertEqual((ringless['logo'],ringless['mark'],ringless['width'],ringless['height']),(15,15,56,23))
        marks=simple_geometry(22,'top',True,False,.45,[16,24])
        self.assertEqual((marks['width'],marks['height']),(61,30))

    def test_side_dock_aligns_numbers_in_one_column_and_uses_source_insets(self):
        layout=simple_geometry(22,'right',True,True,.45,[16,24])
        self.assertEqual((layout['width'],layout['height']),(66,68))
        self.assertEqual(layout['cells'][0][2],layout['cells'][1][2])
        self.assertEqual(layout['cells'][0][1],7)

    def test_separation_selects_peek_and_shared_setting_opens_all_providers(self):
        meter=self.meter(separates_agents=True)
        with patch('motion.animations_enabled',return_value=False):meter.hover()
        self.assertTrue(meter.peek.isVisible());self.assertFalse(meter.panel.isVisible())
        meter.select_at(meter.cells[1][1].center());self.assertEqual(meter.client,'Cursor')
        self.assertEqual(meter.peek.rows[0][0],'Weekly')
        meter.peek.dismiss(immediate=True);meter.settings['separates_agents']=False
        with patch('motion.animations_enabled',return_value=False):meter.hover()
        self.assertFalse(meter.peek.isVisible());self.assertTrue(meter.panel.isVisible())
        self.assertEqual([client for client,_ in meter.panel.providers()],['Codex','Cursor'])
        self.assertEqual(meter.panel.width(),540);self.assertEqual(meter.panel.corner,DESIGN['full_corner'])

    def test_hiding_cancels_hover_so_inactive_agents_cannot_reappear(self):
        meter=self.meter(hover_delay=20);meter.enter_timer.start();meter.hide_all();QTest.qWait(50)
        self.assertFalse(meter.peek.isVisible());self.assertFalse(meter.panel.isVisible())
        self.assertFalse(meter.enter_timer.isActive())

    def test_large_dynamic_peek_scales_rows_and_text_with_the_dock(self):
        meter=self.meter(mode='logos',logo_size=52)
        with patch('motion.animations_enabled',return_value=False):meter.hover()
        self.assertEqual((meter.peek.row_height,meter.peek.font_size,meter.peek.title_size),(36,24,26))
        self.assertEqual(meter.peek.corner,14)

    def test_mode_switch_dismisses_incompatible_hover_and_pinned_content_stays_scoped(self):
        meter=self.meter()
        with patch('motion.animations_enabled',return_value=False):meter.hover()
        meter.settings['mode']='notch';meter.refresh_size();self.assertFalse(meter.peek.isVisible())
        meter.panel.pinned=True;before=meter.client;meter.select_at(meter.cells[-1][1].center())
        self.assertEqual(meter.client,before)

    def test_long_panel_content_is_clamped_and_scrollable(self):
        meter=self.meter(session_limit=10)
        data=dict(quota=dict(windows=[dict(label='Window '+str(i),used=10) for i in range(20)]),local=dict(sessions=[dict(id=str(i),title='Session',state='done',tokens=1) for i in range(20)]))
        meter.set_data(data)
        self.assertGreater(meter.panel.natural_height(),meter.panel.layout_height())
        self.assertLessEqual(meter.panel.layout_height(),meter.screen.availableGeometry().height()-12)

if __name__=='__main__':unittest.main()
