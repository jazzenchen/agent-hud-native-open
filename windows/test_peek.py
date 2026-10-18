import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import unittest
from unittest.mock import patch
from PySide6.QtCore import Qt,QPoint
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from source_design import DESIGN
from views import SimpleMeterView
from preferences import load

DATA=dict(quota=dict(windows=[dict(label='5-hour',used=17),dict(label='Weekly',used=42)]),local=dict(sessions=[]))

class PeekAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def meter(self):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load(dict(glass=False)),lambda _:None,preview=True)
        meter.place(200,100);meter.set_data(DATA);meter.show()
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.glow.close(),meter.panel.close(),meter.close()))
        return meter
    def test_hover_stays_a_single_source_sized_line_and_click_opens_details(self):
        meter=self.meter()
        with patch('motion.animations_enabled',return_value=False):meter.hover()
        self.assertTrue(meter.peek.isVisible());self.assertFalse(meter.panel.isVisible())
        self.assertEqual(meter.peek.height(),DESIGN['peek_height']);self.assertLess(meter.peek.width(),250)
        self.assertEqual(meter.peek.rows,[('5h','17%',17),('Weekly','42%',42)])
        with patch('motion.animations_enabled',return_value=False):
            QTest.mouseClick(meter.peek,Qt.MouseButton.LeftButton,pos=QPoint(meter.peek.width()//2,12))
        self.assertTrue(meter.panel.pinned);self.assertTrue(meter.panel.isVisible());self.assertFalse(meter.peek.isVisible())
    def test_hover_line_has_light_and_dark_surfaces_without_global_palette_leaks(self):
        meter=self.meter();samples=[]
        for scheme in ('light','dark','light'):
            meter.settings['hud_appearance']=scheme
            with patch('motion.animations_enabled',return_value=False):meter.hover()
            self.app.processEvents();samples.append(meter.peek.grab().toImage().pixelColor(8,meter.peek.height()//2).lightness())
        self.assertGreater(samples[0],230);self.assertLess(samples[1],30);self.assertEqual(samples[0],samples[2])
    def test_leaving_both_windows_hides_the_compact_line(self):
        meter=self.meter()
        with patch('motion.animations_enabled',return_value=False):
            meter.hover();meter.maybe_close()
        self.assertFalse(meter.peek.isVisible());self.assertFalse(meter.panel.isVisible())

    def test_dynamic_mode_uses_the_source_compact_bubble(self):
        meter=self.meter();meter.settings['mode']='logos';meter.refresh_size()
        with patch('motion.animations_enabled',return_value=False):meter.hover()
        self.assertFalse(meter.peek.line);self.assertEqual((meter.peek.width(),meter.peek.height()),(196,74))
        self.assertFalse(meter.panel.isVisible())

if __name__=='__main__':unittest.main()
