import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import unittest
from PySide6.QtWidgets import QApplication

from application import DEFAULTS
from source_design import DESIGN
from views import SimpleMeterView, tightest


class ViewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])

    def test_upstream_source_contract_and_requested_defaults(self):
        self.assertEqual(DESIGN['width'],540)
        self.assertEqual(DESIGN['agent_width'],440)
        self.assertEqual(DESIGN['colors']['ok'],'#3ddc84')
        self.assertEqual(DESIGN['simple_size'],22)
        self.assertEqual(DESIGN['animation_ms'],400)
        self.assertEqual((DEFAULTS['mode'],DEFAULTS['glass'],DEFAULTS['separates_agents']),('simple',True,True))

    def test_meter_uses_tightest_window_and_upstream_geometry(self):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),dict(DEFAULTS),lambda _:None,preview=True)
        data=dict(quota=dict(windows=[dict(used=10,label='5-hour'),dict(used=76,label='Weekly')]),local=dict(sessions=[]))
        meter.set_data(data)
        self.assertEqual(meter.label,'76%')
        self.assertEqual(meter.height(),30) # 22 + twice round(22*.18)
        self.assertEqual(meter.mark_size,22)
        self.assertEqual(tightest(data),76)
        meter.panel.progress=1.;meter.panel.animate(1.)
        self.assertEqual(meter.panel.width(),440)
        meter.show();self.app.processEvents()
        self.assertFalse(meter.grab().isNull())
        meter.hide_all();meter.panel.close();meter.close()

    def test_agent_panels_do_not_mix_clients(self):
        a=SimpleMeterView('Codex',self.app.primaryScreen(),dict(DEFAULTS),lambda _:None,preview=True)
        b=SimpleMeterView('Cursor',self.app.primaryScreen(),dict(DEFAULTS),lambda _:None,preview=True)
        a.set_data(dict(quota=dict(windows=[dict(used=21,label='Weekly')]),local=dict(sessions=[])))
        b.set_data(dict(quota=dict(windows=[]),local=dict(sessions=[])))
        self.assertEqual(a.label,'21%');self.assertEqual(b.label,'–')
        self.assertIsNot(a.panel,b.panel)
        for meter in (a,b):meter.hide_all();meter.panel.close();meter.close()


if __name__=='__main__':unittest.main()
