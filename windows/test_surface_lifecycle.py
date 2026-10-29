"""Regression cases for stale detached surfaces and interrupted side morphs."""
import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import unittest
from unittest.mock import patch
from PySide6.QtCore import QRect
from PySide6.QtGui import QImage,QPainter,QPainterPath,QColor
from PySide6.QtWidgets import QApplication,QWidget
from material import PanelFrost
from preferences import load
from views import SimpleMeterView


class SurfaceLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])

    def meter(self,mode,edge):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load(dict(mode=mode,edge=edge)),lambda _:None,preview=True)
        meter.set_data(dict(quota=dict(windows=[dict(label='Weekly',used=42)]),local=dict(sessions=[])))
        meter.place(150,150);meter.show()
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
        return meter

    def test_every_mode_and_edge_cancels_detached_surfaces_when_hidden(self):
        for mode in ('simple','logos','notch'):
            for edge in ('top','bottom','left','right'):
                with self.subTest(mode=mode,edge=edge):
                    meter=self.meter(mode,edge)
                    meter.open_panel();meter.panel.animation.jump(.6)
                    meter.hide()
                    self.assertFalse(meter.panel.isVisible())
                    self.assertFalse(meter.peek.isVisible())
                    self.assertFalse(meter.panel.animation.running)
                    self.assertEqual(meter.panel.progress,0.)
                    self.assertFalse(meter.glow.timer.isActive())
                    meter.show();meter.open_panel();meter.panel.animation.jump(1.)
                    self.assertTrue(meter.panel.isVisible())

    def test_changing_edge_cancels_old_origin_and_can_open_from_new_anchor(self):
        meter=self.meter('simple','left');meter.open_panel();meter.panel.animation.jump(.4)
        meter.settings['edge']='right';meter.refresh_size()
        self.assertFalse(meter.panel.isVisible());self.assertFalse(meter.panel.animation.running)
        meter.place(600,180);meter.open_panel();meter.panel.animation.jump(1.)
        self.assertEqual(meter.panel.source_rect,meter.geometry())
        self.assertLess(meter.panel.x(),meter.x())

    def test_morph_returns_to_source_and_does_not_keep_fixed_size_constraints(self):
        for mode in ('simple','logos','notch'):
            for edge in ('top','bottom','left','right'):
                with self.subTest(mode=mode,edge=edge):
                    meter=self.meter(mode,edge);meter.open_panel()
                    origin=QRect(meter.panel.source_rect)
                    for fraction in (.2,.8,.35,1.,.6,.1):
                        meter.panel.animation.jump(fraction)
                        self.assertGreater(meter.panel.width(),0)
                        self.assertGreater(meter.panel.height(),0)
                    meter.panel.animation.jump(0.)
                    self.assertFalse(meter.panel.isVisible())
                    self.assertEqual(meter.panel.pos(),origin.topLeft())
                    self.assertIsNone(meter.panel.frost.image)

    def test_frost_and_tint_share_the_same_clip_and_global_coordinates(self):
        widget=QWidget();widget.move(20,30);widget.resize(80,60)
        self.addCleanup(widget.close)
        frost=PanelFrost();frost.image=QImage(120,120,QImage.Format.Format_ARGB32_Premultiplied)
        frost.image.fill(QColor('#80aacc'))
        from PySide6.QtCore import QPoint,QRectF
        frost.origin=QPoint(0,0)
        output=QImage(80,60,QImage.Format.Format_ARGB32_Premultiplied);output.fill(0)
        path=QPainterPath();path.addRoundedRect(QRectF(0,0,80,60),18,18)
        p=QPainter(output);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        self.assertTrue(frost.paint(p,widget,path));p.end()
        self.assertEqual(output.pixelColor(0,0).alpha(),0)
        self.assertEqual(output.pixelColor(40,30).name(),'#80aacc')
        frost.clear();self.assertIsNone(frost.image)

    def test_fractional_dpi_cache_extent_and_negative_monitor_origin(self):
        from PySide6.QtCore import QPoint
        frost=PanelFrost();frost.origin=QPoint(-100,20)
        frost.image=QImage(300,120,QImage.Format.Format_ARGB32_Premultiplied)
        frost.image.setDevicePixelRatio(1.5)
        self.assertTrue(frost.covers(QRect(-90,30,100,50)))
        self.assertFalse(frost.covers(QRect(80,30,100,50)))
        self.assertFalse(frost.covers(QRect(-90,90,100,50)))

    def test_label_reflow_inside_cached_strip_does_not_dismiss_open_details(self):
        from PySide6.QtCore import QPoint
        meter=self.meter('simple','top');meter.open_panel();meter.panel.animation.jump(1.)
        meter.frost.origin=QPoint(0,100)
        meter.frost.image=QImage(1000,150,QImage.Format.Format_ARGB32_Premultiplied)
        meter.preview=False
        meter.place(155,150)
        self.assertTrue(meter.panel.isVisible())
        self.assertEqual(meter.panel.progress,1.)
        meter.preview=True

    def test_dynamic_queue_does_not_clip_its_first_and_last_logos_to_a_capsule(self):
        for edge in ('top','bottom','left','right'):
            meter=self.meter('logos',edge)
            self.assertTrue(meter.mask().isEmpty())
            meter.settings['mode']='simple';meter.refresh_size()
            self.assertFalse(meter.mask().isEmpty())
            meter.settings['mode']='logos';meter.refresh_size()
            self.assertTrue(meter.mask().isEmpty())


if __name__=='__main__':unittest.main()
