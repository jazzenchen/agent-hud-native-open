import gzip,json,tempfile,time,unittest
from pathlib import Path
from unittest.mock import Mock,patch
from PySide6.QtCore import QRectF,Qt
from PySide6.QtGui import QImage,QPainter,QColor
from PySide6.QtWidgets import QApplication
from bot_player import BotLibrary,BotPlayer,activity
from usage_display import visible_quota


class Bots(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def test_real_activity_takes_priority_over_hover_without_inventing_limit_events(self):
        now=10000
        def data(state,at=9999):return dict(local=dict(sessions=[dict(state=state,updated=at)]),quota=dict(windows=[dict(used=100)]))
        self.assertEqual(activity(data('running'),True,now),'working')
        self.assertEqual(activity(data('question'),True,now),'question')
        self.assertEqual(activity(data('done'),True,now),'opened')
        self.assertEqual(activity(data('done'),False,now),'idle')
        self.assertEqual(activity(data('running',100),False,now),'asleep')
        self.assertEqual(activity(data('unknown',None),False,now),'asleep')
    def test_missing_or_bad_asset_pack_falls_back_without_starting_a_client(self):
        with tempfile.TemporaryDirectory() as folder:
            lib=BotLibrary(folder);self.assertFalse(lib.ready)
            (Path(folder)/'manifest.json.gz').write_bytes(gzip.compress(b'{bad'))
            self.assertFalse(BotLibrary(folder).ready)
    def test_original_atlas_frame_and_pose_render_and_load_lazily(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);image=QImage(4,4,QImage.Format.Format_ARGB32);image.fill(QColor('#18a34a'));image.save(str(root/'atlas.png'))
            frame=dict(image=0,pose=[0,0,0,1,1,0],opacity=1,rest=False)
            (root/'one.gz').write_bytes(gzip.compress(json.dumps(dict(fps=24,frames=[frame]*192)).encode()))
            manifest=dict(version=1,markSide=4,margin=0,images={'0':dict(page='atlas.png',rect=[0,0,4,4])},clips=[dict(vendor='ChatGPT',state='working',light=False,file='one.gz')])
            (root/'manifest.json.gz').write_bytes(gzip.compress(json.dumps(manifest).encode()))
            lib=BotLibrary(root);self.assertTrue(lib.ready);self.assertFalse(lib.loaded)
            self.assertEqual(len(lib.clip('Codex',False,'working')['frames']),192)
            target=QImage(20,20,QImage.Format.Format_ARGB32);target.fill(Qt.GlobalColor.transparent);p=QPainter(target)
            player=BotPlayer(Mock())
            with patch('bot_player.library',return_value=lib):self.assertTrue(player.draw_frame(p,QRectF(4,4,12,12),frame))
            p.end();self.assertEqual(target.pixelColor(10,10).name(),'#18a34a')
    def test_codex_tool_lifecycle_drives_original_motion_without_retaining_payloads(self):
        from session_formats import Transcript
        from provider_registry import merge_codex_metadata
        p=Transcript('Codex','s')
        p.feed(dict(type='event_msg',timestamp=10000,payload=dict(type='task_started')),0)
        p.feed(dict(type='response_item',timestamp=10001,payload=dict(type='function_call',name='apply_patch',call_id='one',arguments='private contents')),1)
        self.assertEqual(p.summary()['activity'],'edit')
        self.assertEqual(activity(dict(local=dict(sessions=[p.summary()])),False,10002),'edit')
        self.assertNotIn('private contents',repr(p.__dict__))
        row=merge_codex_metadata(p.summary(),dict(state='unknown',updated=10002),now=10003)
        self.assertEqual(row['state'],'running');self.assertEqual(row['activity'],'edit')
        p.feed(dict(type='response_item',timestamp=10004,payload=dict(type='function_call_output',call_id='one',output='private result')),2)
        self.assertEqual(p.summary()['activity'],'thinking')
        p.feed(dict(type='event_msg',timestamp=10005,payload=dict(type='task_complete')),3)
        self.assertIsNone(p.summary()['activity'])
        stale=merge_codex_metadata(dict(state='running',activity='command'),dict(state='unknown',updated=10002),now=14000)
        self.assertEqual(stale['state'],'unknown');self.assertIsNone(stale['activity'])

    def test_shipped_source_pack_is_complete_and_bounded(self):
        from bot_player import ASSETS
        from agent_catalog import VENDORS
        if not (ASSETS/'manifest.json.gz').exists():self.skipTest('Original reference export not packed yet')
        lib=BotLibrary();self.assertTrue(lib.ready)
        for vendor in VENDORS:
            for light in (False,True):
                for state in ('working','asking','opened','idle','failed'):
                    clip=lib.clip(vendor,light,state);self.assertIsNotNone(clip,(vendor,light,state))
                    frame=clip['frames'][min(36,len(clip['frames'])-1)];self.assertFalse(lib.image(frame['image']).isNull())
        self.assertLessEqual(len(lib.cache),192);self.assertLessEqual(len(lib.pages),4);self.assertLessEqual(len(lib.loaded),8)

    def test_hidden_accounts_and_window_order_only_change_presentation(self):
        quota=dict(windows=[dict(label='Weekly',account='a'),dict(label='5h',account='b')],wallets=[dict(balance=3,account='a')])
        settings=dict(window_order={'Kimi':['5h','Weekly']},hidden_accounts=['a'])
        visible=visible_quota(quota,'Kimi',settings)
        self.assertEqual([r['label'] for r in visible['windows']],['5h']);self.assertFalse(visible['wallets'])
        self.assertEqual(len(quota['windows']),2);self.assertEqual(len(quota['wallets']),1)
        # A saved legacy order cannot move one account's window into another's slot.
        self.assertEqual([r['label'] for r in visible_quota(quota,'Kimi',dict(window_order=settings['window_order']))['windows']],['Weekly','5h'])

if __name__=='__main__':unittest.main()
