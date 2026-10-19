import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import unittest
from unittest.mock import patch
from PySide6.QtCore import Qt,QPoint
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest,QSignalSpy
from motion import SpringState,SpringDriver,motion_clock
from settings_controls import Switch
from views import SimpleMeterView
from preferences import load

class MotionAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])

    def test_solver_is_independent_of_frame_partition(self):
        for damping in (1.,.92):
            a=SpringState(target=1,frequency=4,damping=damping)
            b=SpringState(target=1,frequency=4,damping=damping)
            for _ in range(12):a.advance(.01)
            for _ in range(4):b.advance(.03)
            self.assertAlmostEqual(a.position,b.position,places=10);self.assertAlmostEqual(a.velocity,b.velocity,places=10)

    def test_retarget_keeps_position_and_velocity_and_reduced_motion_is_immediate(self):
        driver=SpringDriver();self.addCleanup(driver.stop)
        with patch('motion.animations_enabled',return_value=True):
            driver.retarget(1);driver.state.advance(.08)
            before=(driver.state.position,driver.state.velocity);driver.retarget(0)
            self.assertEqual((driver.state.position,driver.state.velocity),before)
            self.assertGreater(before[1],0)
        with patch('motion.animations_enabled',return_value=False):
            driver.retarget(1);self.assertEqual((driver.state.position,driver.state.velocity),(1,0));self.assertFalse(driver.running)
        self.assertNotIn(driver,motion_clock().active)

    def test_panel_rapid_reversal_remains_continuous_and_settles(self):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load({}),lambda _:None,preview=True)
        self.addCleanup(lambda:(meter.hide_all(),meter.glow.close(),meter.panel.close(),meter.close()))
        meter.place(100,100);meter.panel.pinned=True
        with patch('motion.animations_enabled',return_value=True):
            meter.panel.open();QTest.qWait(80)
            self.assertTrue(0<meter.panel.progress<1)
            current=(meter.panel.animation.state.position,meter.panel.animation.state.velocity)
            meter.panel.collapse()
            self.assertEqual((meter.panel.animation.state.position,meter.panel.animation.state.velocity),current)
            QTest.qWait(20);meter.panel.open();QTest.qWait(600)
            self.assertAlmostEqual(meter.panel.progress,1,places=3)
            self.assertFalse(meter.panel.animation.running)

    def test_new_spring_does_not_inherit_elapsed_time_from_existing_animation(self):
        first,second=SpringDriver(),SpringDriver();self.addCleanup(first.stop);self.addCleanup(second.stop)
        clock=motion_clock()
        with patch('motion.animations_enabled',return_value=True),patch('motion.time.monotonic') as now:
            now.return_value=100.;first.retarget(1.)
            now.return_value=101.;second.retarget(1.)
            now.return_value=101.016;clock.frame()
            self.assertTrue(0<second.state.position<.1)
            self.assertTrue(first.state.settled)

    def test_switch_cancel_and_keyboard_activate_once(self):
        switch=Switch();switch.show();self.addCleanup(switch.close);self.app.processEvents()
        spy=QSignalSpy(switch.toggled)
        QTest.mousePress(switch,Qt.MouseButton.LeftButton,pos=QPoint(10,10))
        QTest.mouseRelease(switch,Qt.MouseButton.LeftButton,pos=QPoint(-8,-8))
        self.assertFalse(switch.isChecked());self.assertEqual(spy.count(),0)
        QTest.keyClick(switch,Qt.Key.Key_Space)
        self.assertTrue(switch.isChecked());self.assertEqual(spy.count(),1)

    def test_source_curve_duration_and_interruption(self):
        from motion import CurveState,source_curve
        self.assertAlmostEqual(source_curve(.5)[0],.946079,places=4)
        state=CurveState(0.,.4);state.retarget(1.);state.advance(.1)
        before,velocity=state.position,state.velocity;state.retarget(0.)
        self.assertEqual(state.position,before);self.assertEqual(state.velocity,velocity)
        state.advance(.000001);self.assertAlmostEqual(state.velocity,velocity,places=2)
        state.advance(.4);self.assertTrue(state.settled);self.assertEqual(state.position,0.)

    def test_reduced_motion_stops_continuous_glow(self):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load(dict(mode='logos')),lambda _:None,preview=True)
        self.addCleanup(lambda:(meter.hide_all(),meter.glow.close(),meter.panel.close(),meter.close()))
        meter.show()
        with patch('glow_view.animations_enabled',return_value=False):
            meter.glow.sync();self.assertFalse(meter.glow.timer.isActive())
            self.assertFalse(meter.glow.grab().isNull())

if __name__=='__main__':unittest.main()
