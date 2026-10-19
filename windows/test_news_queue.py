import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import time,unittest,uuid
from PySide6.QtCore import Qt,QPointF
from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest
from attention_ipc import AttentionServer
from attention_protocol import completion
from quota_events import QuotaEvents
from source_design import DESIGN
from preferences import load
from views import SimpleMeterView


class NewsQueue(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def server(self,**options):
        server=AttentionServer(name='agent-hud-news-test-'+uuid.uuid4().hex,**options);self.addCleanup(server.close);return server
    def event(self,used=90):
        tracker=QuotaEvents()
        def snapshot(value,at):return dict(Codex=dict(quota=dict(at=at,account=dict(id='a'),windows=[dict(label='5h',used=value,reset=20000,duration=18000)])))
        tracker.update(snapshot(80,10000),now=10000)
        return tracker.update(snapshot(used,10001),now=10001)[0]

    def test_unknown_quota_rows_can_be_painted_without_becoming_zero_or_crashing(self):
        from PySide6.QtGui import QImage,QPainter
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load({}),lambda _:None,preview=True)
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
        panel=meter.panel;target=QImage(440,300,QImage.Format.Format_ARGB32_Premultiplied)
        for used in (None,float('nan'),float('inf'),False):
            data=dict(quota=dict(windows=[dict(label='5-hour',used=used)]),local=dict(sessions=[]))
            meter.set_data(data);p=QPainter(target)
            try:self.assertEqual(panel.provider_block(p,404,data=data),71)
            finally:p.end()
            from views import tightest
            self.assertIsNone(tightest(data));meter.peek.refresh()
            self.assertEqual(meter.peek.rows[0][1],'–')

    def test_source_four_second_lifetime_starts_when_shown_and_resets_after_pointer_leaves(self):
        displayed=set();held=set();server=self.server(presentation=lambda:(displayed,held));event=self.event();key=event['id']
        self.assertEqual(DESIGN['alert_seconds'],4)
        server.add_news(event);server.news_timer.stop();server.presentation_tick(100)
        self.assertIn(key,server.pending)  # Queued, not yet shown.
        displayed.add(key);server.presentation_tick(110);server.presentation_tick(113.99);self.assertIn(key,server.pending)
        held.add(key);server.presentation_tick(114);server.presentation_tick(200)
        held.clear();server.presentation_tick(203.99);self.assertIn(key,server.pending)
        server.presentation_tick(204);self.assertNotIn(key,server.pending)

    def test_permission_never_expires_and_quota_news_is_dropped_while_approval_waits(self):
        displayed={'permission'};server=self.server(presentation=lambda:(displayed,set()))
        server.pending['permission']=dict(id='permission',kind='permission',vendor='Codex')
        server.presentation_tick(0);server.presentation_tick(999999)
        server.add_news(self.event());self.assertEqual(list(server.pending),['permission'])
        reply=completion('codex',dict(hook_event_name='Stop',session_id='s',turn_id='t'))
        server.add_completion(reply);self.assertEqual(len(server.pending),2)

    def test_quota_news_survives_hooks_off_but_hidden_and_departed_clients_do_not_replay(self):
        enabled=False;server=self.server(enabled=lambda:False,news_enabled=lambda _:enabled)
        server.add_news(self.event());self.assertFalse(server.pending)
        enabled=True;event=self.event();server.add_news(event);self.assertIn(event['id'],server.pending)
        server.disable();self.assertIn(event['id'],server.pending)
        server.observe({});self.assertFalse(server.pending)

    def test_actual_reply_expiry_timer_runs_and_sleeps_when_queue_drains(self):
        displayed=set();server=self.server(presentation=lambda:(displayed,set()))
        event=completion('codex',dict(hook_event_name='Stop',session_id='s',turn_id='t'))
        server.add_completion(event);displayed.add(event['id']);server.presentation_tick()
        self.assertTrue(server.news_timer.isActive())
        QTest.qWait(4250)
        self.assertFalse(server.pending);self.assertFalse(server.news_timer.isActive())

    def test_actual_qt_card_uses_release_action_and_source_width(self):
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load({}),lambda _:None,preview=True)
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
        meter.set_data(dict(quota=dict(windows=[]),local=dict(sessions=[])));meter.show()
        event=self.event();meter.set_attention([event]);meter.open_panel();meter.panel.animation.jump(1.);meter.panel.grab()
        self.assertEqual(meter.panel.content_width(),400)
        self.assertIn('即将耗尽',meter.peek.fallback)
        actions=[];usage=[];meter.attention_callback=lambda *args:actions.append(args);meter.usage_callback=lambda *args:usage.append(args)
        rect=next(rect for rect,action in meter.panel.hits if isinstance(action,tuple) and action[2]=='usage')
        point=(rect.center()+QPointF(18,14)).toPoint()
        QTest.mousePress(meter.panel,Qt.MouseButton.LeftButton,pos=point);self.assertFalse(actions);self.assertFalse(usage)
        QTest.mouseRelease(meter.panel,Qt.MouseButton.LeftButton,pos=point)
        self.assertEqual(actions,[(event['id'],'dismiss')]);self.assertEqual(usage[0][0],'Codex')

    def test_notch_reminder_ignores_saved_dock_edge(self):
        for edge in ('top','right','bottom','left'):
            meter=SimpleMeterView('Codex',self.app.primaryScreen(),load(dict(mode='notch',edge=edge)),lambda _:None,preview=True)
            self.addCleanup(lambda meter=meter:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
            meter.set_data(dict(quota=dict(windows=[]),local=dict(sessions=[])));meter.place(200,0);meter.show();meter.set_attention([self.event()]);meter.peek.animation.jump(1.)
            self.assertEqual(meter.peek.edge,'top');self.assertEqual(meter.peek.tuck,0)
            self.assertGreaterEqual(meter.peek.y(),meter.geometry().bottom())

    def test_reopening_cancels_old_leave_and_hiding_old_peek_does_not_close_replacement(self):
        from PySide6.QtCore import QEvent
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load({}),lambda _:None,preview=True)
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
        meter.set_data(dict(quota=dict(windows=[]),local=dict(sessions=[])));meter.show();meter.leave_timer.start()
        meter.open_panel();self.assertFalse(meter.leave_timer.isActive())
        meter.peek.leaveEvent(QEvent(QEvent.Type.Leave));self.assertFalse(meter.leave_timer.isActive())

    def test_application_visibility_choices_filter_news_without_disabling_quota_collection(self):
        from application import Application
        manager=Application.__new__(Application);manager.settings=load({})
        manager.data=dict(Codex=dict(quota=dict(account=dict(id='a'),windows=[dict(label='5h',used=90)])))
        event=self.event();self.assertTrue(manager.attention_news_enabled(event))
        manager.settings['disabled_live_status_sources']=['Codex']
        self.assertTrue(manager.attention_news_enabled(event))
        server=self.server(news_enabled=manager.attention_news_enabled);server.add_news(event)
        manager.settings['hidden_windows']={'Codex':['5h']}
        self.assertFalse(manager.attention_news_enabled(event));server.observe(manager.data);self.assertFalse(server.pending)
        manager.settings['hidden_windows']={};manager.settings['hidden_accounts']=['a']
        self.assertFalse(manager.attention_news_enabled(event))
        self.assertEqual(manager.data['Codex']['quota']['windows'][0]['used'],90)


if __name__=='__main__':unittest.main()
