import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import json,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock
from PySide6.QtCore import Qt,QPointF,QEvent
from PySide6.QtGui import QMouseEvent
from PySide6.QtWidgets import QApplication,QCheckBox,QDoubleSpinBox
from application import Application
from views import SimpleMeterView
from preferences import load,validate
from placement import group_origin,nearest_placement
from settings_window import SettingsWindow
from glow_logic import gain,strength
from look_logic import dimming,stand_in

FIXTURE=dict(local=dict(sessions=[]),quota=dict(windows=[dict(label='Weekly',used=37)]))

class SettingsFixture:
    def __init__(self,app):self.app=app;self.settings=load({});self.data={}
    def screen_settings(self,name):return {**self.settings,**self.settings['placements'].get(name,{})}
    def apply_setting(self,key,value,screen=None):
        target=self.settings if screen is None else self.settings['placements'].setdefault(screen,{})
        target[key]=validate(key,value)
    def refresh_now(self):pass

class InteractionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])

    def meter(self,settings=None):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load(settings or {}),lambda _:None,preview=True)
        meter.set_data(FIXTURE);self.addCleanup(lambda:(meter.hide_all(),meter.glow.close(),meter.panel.close(),meter.close()))
        return meter

    def send(self,meter,kind,point,global_point,button,buttons):
        QApplication.sendEvent(meter,QMouseEvent(kind,QPointF(*point),QPointF(*global_point),button,buttons,Qt.KeyboardModifier.NoModifier))

    def test_drag_moves_window_and_does_not_pin_panel(self):
        meter=self.meter();meter.place(100,100);meter.show();self.app.processEvents()
        received=[];meter.placement_callback=lambda view,point:received.append(point)
        self.send(meter,QEvent.Type.MouseButtonPress,(8,8),(108,108),Qt.MouseButton.LeftButton,Qt.MouseButton.LeftButton)
        self.send(meter,QEvent.Type.MouseMove,(48,48),(148,148),Qt.MouseButton.NoButton,Qt.MouseButton.LeftButton)
        self.assertTrue(meter.dragging);self.assertEqual((meter.x(),meter.y()),(140,140))
        self.send(meter,QEvent.Type.MouseButtonRelease,(48,48),(148,148),Qt.MouseButton.LeftButton,Qt.MouseButton.NoButton)
        self.assertFalse(meter.dragging);self.assertFalse(meter.panel.pinned);self.assertEqual(len(received),1)

    def test_click_pins_but_does_not_reposition(self):
        meter=self.meter();callback=Mock();meter.placement_callback=callback
        for kind,buttons in ((QEvent.Type.MouseButtonPress,Qt.MouseButton.LeftButton),(QEvent.Type.MouseButtonRelease,Qt.MouseButton.NoButton)):
            self.send(meter,kind,(8,8),(108,108),Qt.MouseButton.LeftButton,buttons)
        self.assertTrue(meter.panel.pinned);callback.assert_not_called()

    def test_source_drag_geometry_round_trip_and_edge_ties(self):
        screen=(-1920,0,1920,1080);extent=(160,30)
        for edge in ('top','bottom','left','right'):
            x,y=group_origin(screen,extent,edge,.3,0)
            px,py=(x+extent[0]*.2,y) if edge in ('top','bottom') else (x,y+extent[1]*.2)
            if edge=='right':px+=extent[0]
            if edge=='bottom':py+=extent[1]
            result=nearest_placement(px,py,screen,extent,edge,.2)
            self.assertEqual(result['edge'],edge);self.assertAlmostEqual(result['offset'],.3)
        self.assertEqual(nearest_placement(0,0,(0,0,100,100),current_edge='left')['edge'],'left')

    def test_saved_per_screen_settings_survive_reload(self):
        manager=Application.__new__(Application);manager.settings=load({});manager.tray=Mock();manager.monitor=Mock();manager.windows={};manager.data={}
        manager.update=Mock();manager.menu=lambda:None;manager.refresh_themes=Mock()
        with tempfile.TemporaryDirectory() as folder:
            manager.config=Path(folder)/'settings.json'
            manager.apply_setting('edge','right','monitor-a');manager.apply_setting('offset',.76,'monitor-a')
            recovered=load(json.loads(manager.config.read_text()))
            self.assertEqual(recovered['placements']['monitor-a'],dict(edge='right',offset=.76))
            self.assertEqual(recovered['edge'],'top')

    def test_settings_controls_change_the_same_model_used_by_views(self):
        manager=SettingsFixture(self.app);window=SettingsWindow(manager);self.addCleanup(window.close)
        check=window.findChild(QCheckBox,'show_numbers');check.setChecked(False)
        spin=window.findChild(QDoubleSpinBox,'size');spin.setValue(36)
        cfg=manager.screen_settings(manager.app.primaryScreen().name())
        self.assertFalse(cfg['show_numbers']);self.assertEqual(cfg['size'],36)
        meter=self.meter(cfg);self.assertEqual(meter.mark_size,36)

    def test_mode_group_and_panel_switches_change_real_geometry(self):
        meter=self.meter();initial=meter.width()
        meter.set_group_data({'Codex':FIXTURE,'Cursor':FIXTURE});self.assertGreater(meter.width(),initial)
        self.assertEqual(len(meter.cells),2)
        full=meter.panel.layout_height();meter.settings['panel_tokens']=False
        self.assertLess(meter.panel.layout_height(),full)
        for mode in ('simple','logos','notch'):
            meter.settings['mode']=mode;meter.refresh_size();meter.show();self.app.processEvents()
            self.assertFalse(meter.grab().isNull())
        self.assertEqual((meter.width(),meter.height()),(216,24))

    def test_source_motion_reference_values(self):
        self.assertEqual(gain('breathe',0,3,0,0,10,200,.6),1)
        self.assertAlmostEqual(gain('breathe',1.5,3,0,0,10,200,.6),.4)
        self.assertAlmostEqual(strength(50,10,0,5),.05)
        self.assertEqual(strength(51,10,0,5),0)
        for effect in ('breathe','flow','scan','ripple','shimmer','boot'):
            self.assertTrue(0<=gain(effect,1,3,100,12,10,200,.6)<=1.2)

    def test_source_material_transparency_rules(self):
        self.assertEqual(dimming(100,True,'material'),0)
        self.assertEqual(dimming(100,True,'clear'),.4)
        self.assertEqual(dimming(50,True,'material'),.5)
        self.assertAlmostEqual(stand_in(100,True,'material'),.35)

    def test_all_glow_patterns_render_on_input_through_window(self):
        meter=self.meter({'mode':'logos'});meter.show();self.app.processEvents()
        for style in ('blur','dots','ascii','blocks','braille','binary'):
            meter.settings['glow_style']=style;meter.glow.sync();self.app.processEvents()
            self.assertTrue(meter.glow.windowFlags() & Qt.WindowType.WindowTransparentForInput)
            self.assertFalse(meter.glow.grab().isNull())

if __name__=='__main__':unittest.main()
