import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import json,struct,subprocess,sys,tempfile,time,unittest,uuid
from unittest.mock import patch,Mock
from pathlib import Path
from PySide6.QtWidgets import QApplication
from PySide6.QtNetwork import QLocalSocket
from PySide6.QtTest import QTest
from attention_protocol import permission,decision,completion,CompletionTracker,codex_user_reviewer,LIMIT
from attention_ipc import AttentionServer

PAYLOAD=dict(hook_event_name='PermissionRequest',session_id='test-session',tool_name='Bash',
             tool_input=dict(command='python -m unittest',description='Run the test suite'),cwd='C:\\demo')


class Attention(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])

    def test_actual_claude_and_workbuddy_answer_wire_and_unsupported_default(self):
        for source in ('claude','workbuddy','codebuddy'):
            request=permission(source,PAYLOAD)
            self.assertIsNotNone(request)
            for action,word in (('allow','allow'),('deny','deny')):
                self.assertEqual(json.loads(decision(request,action)),dict(hookSpecificOutput=dict(hookEventName='PermissionRequest',decision=dict(behavior=word))))
            self.assertEqual(decision(request,'leave'),b'')
            self.assertEqual(decision(request,'invented_action'),b'')
        self.assertIsNone(permission('cursor',PAYLOAD))
        self.assertIsNone(permission('claude',{**PAYLOAD,'session_id':''}))

    def test_buddy_completion_uses_latest_turn_identity_without_replaying_history(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'session.jsonl'
            record=dict(type='message',sessionId='s',role='assistant',status='completed',providerData=dict(messageId='stable',requestModelId='model'))
            path.write_text(json.dumps(record)+'\n')
            payload=dict(hook_event_name='Stop',session_id='s',transcript_path=str(path))
            first=completion('workbuddy',payload,now=10);second=completion('workbuddy',payload,now=12)
            self.assertEqual(first['turn'],second['turn']);self.assertEqual(first['model'],'model')
            with path.open('a') as stream:stream.write(json.dumps(dict(type='message',sessionId='s',role='user'))+'\n')
            self.assertEqual(completion('workbuddy',payload,now=15)['turn'],'stop-15000')
            # No assistant text is copied into a persisted local record.
            self.assertEqual(first['message'],'')

    def test_qwen_devin_and_zcode_follow_their_source_specific_hook_contracts(self):
        from attention_hooks import merge,configure_all
        foreign=dict(hooks=dict(events=dict(PermissionRequest=[dict(hooks=[dict(type='command',command='foreign')])])),other=True)
        zcode=merge(foreign,'zcode')
        group=zcode['hooks']['events']['PermissionRequest'][-1]
        self.assertNotIn('matcher',group);self.assertEqual(merge(zcode,'zcode',True),foreign)
        qwen=merge({},'qwen')['hooks']
        self.assertEqual(qwen['PermissionRequest'][0]['hooks'][0]['timeout'],86400000)
        self.assertEqual(qwen['Stop'][0]['hooks'][0]['timeout'],5000)
        for source in ('qwen','devin'):
            self.assertIsNotNone(permission(source,PAYLOAD))
            self.assertIsNone(permission(source,{**PAYLOAD,'tool_name':'ask_user_question'}))
            self.assertEqual(completion(source,dict(hook_event_name='Stop',session_id='s',prompt_id='p'))['turn'],'p')
        self.assertIsNone(permission('zcode',{**PAYLOAD,'tool_name':'ExitPlanMode'}))
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);(home/'.qwen').mkdir();(home/'.zcode/cli').mkdir(parents=True)
            (home/'.local/share/devin/cli').mkdir(parents=True);(home/'.local/share/devin/cli/sessions.db').touch()
            self.assertEqual(len(configure_all(home=home,environment={})),3)
            self.assertTrue((home/'.config/devin/config.json').exists())

    def test_callback_ownership_requires_an_actual_hook_not_a_quoted_path_mention(self):
        from attention_hooks import owns,SCRIPT,merge,locations
        real=subprocess.list2cmdline([sys.executable,str(SCRIPT),'permission','claude'])
        self.assertTrue(owns(real));self.assertFalse(owns('echo '+real))
        foreign=dict(hooks=dict(PermissionRequest=[dict(hooks=[dict(type='command',command='echo '+real)])]))
        self.assertEqual(merge(merge(foreign,'claude'),'claude',True),foreign)
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory)
            self.assertEqual(locations(home,{'CODEBUDDY_CONFIG_DIR':str(home/'.workbuddy')})['codebuddy'],home/'.codebuddy/settings.json')

    def test_codex_uses_exact_turn_reviewer_never_policy_or_old_context(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'rollout.jsonl'
            payload={**PAYLOAD,'turn_id':'turn','transcript_path':str(path),'permission_mode':'default'}
            self.assertFalse(codex_user_reviewer(payload));self.assertIsNone(permission('codex',payload))
            def write(contexts):path.write_text('\n'.join(json.dumps(dict(type='turn_context',payload=c)) for c in contexts))
            write([dict(turn_id='turn',approvals_reviewer='user')]);self.assertIsNotNone(permission('codex',payload))
            write([dict(turn_id='turn',approvals_reviewer='user'),dict(turn_id='turn',approvals_reviewer='guardian')])
            self.assertIsNone(permission('codex',payload))
            write([dict(turn_id='turn',approvals_reviewer='user'),dict(turn_id='turn')]);self.assertIsNone(permission('codex',payload))
            self.assertIsNone(permission('codex',{**payload,'turn_id':'other'}))

    def test_only_offered_claude_rule_can_be_returned_without_changing_scope(self):
        rule=dict(type='addRules',behavior='allow',rules=[dict(toolName='Bash',ruleContent='python -m unittest:*')],destination='session')
        payload={**PAYLOAD,'permission_suggestions':[rule,dict(type='setMode',mode='bypassPermissions')]}
        request=permission('claude',payload)
        value=json.loads(decision(request,'always',update=rule))
        self.assertEqual(value['hookSpecificOutput']['decision']['updatedPermissions'],[rule])
        self.assertEqual(decision(request,'always',update=dict(type='setMode',mode='bypassPermissions')),b'')
        self.assertEqual(decision(permission('workbuddy',payload),'always',update=rule),b'')

    def test_questions_and_plans_carry_original_input_and_explicit_answers(self):
        inputs=dict(questions=[dict(question='Which theme?',options=[dict(label='Dark'),dict(label='Light')],multiSelect=False)],extra='kept')
        request=permission('claude',{**PAYLOAD,'tool_name':'AskUserQuestion','tool_input':inputs})
        self.assertEqual(decision(request,'allow'),b'')
        answer=json.loads(decision(request,'answer',answers={'Which theme?':'Dark'}))['hookSpecificOutput']['decision']
        self.assertEqual(answer['updatedInput'],{**inputs,'answers':{'Which theme?':'Dark'}})
        self.assertIsNone(permission('workbuddy',{**PAYLOAD,'tool_name':'AskUserQuestion','tool_input':inputs}))
        request=permission('claude',{**PAYLOAD,'tool_name':'ExitPlanMode','tool_input':dict(plan='# Plan\nRun tests')})
        self.assertEqual(decision(request,'allow'),b'')
        answer=json.loads(decision(request,'approve_plan',accept_edits=False))['hookSpecificOutput']['decision']
        self.assertNotIn('updatedPermissions',answer)
        self.assertEqual(answer['updatedInput']['plan'],'# Plan\nRun tests')

    def test_completion_requires_success_and_history_does_not_raise_replies(self):
        row=dict(hook_event_name='stop',status='completed',conversation_id='s',generation_id='t')
        self.assertIsNotNone(completion('cursor',row))
        for state in ('aborted','error','cancelled','unknown'):
            self.assertIsNone(completion('cursor',{**row,'status':state}))
        tracker=CompletionTracker()
        def snapshot(state):return dict(Codex=dict(local=dict(sessions=[dict(id='s',state=state,updated=time.time(),title='Task')])))
        self.assertFalse(tracker.update(snapshot('done')))
        self.assertFalse(tracker.update(snapshot('running')))
        self.assertEqual(len(tracker.update(snapshot('done'))),1)
        self.assertFalse(tracker.update(snapshot('done')))
        self.assertFalse(tracker.update(snapshot('stopped')))

    def server(self):
        name='agent-hud-test-'+uuid.uuid4().hex;server=AttentionServer(name=name)
        self.addCleanup(server.close);self.assertTrue(server.listening)
        return name,server

    def spin(self,condition,timeout=3000):
        end=time.monotonic()+timeout/1000
        while not condition() and time.monotonic()<end:QTest.qWait(10)
        self.assertTrue(condition())

    def test_real_hook_process_waits_and_receives_clicked_decision(self):
        name,server=self.server()
        child=subprocess.Popen([sys.executable,str(Path(__file__).with_name('attention_hook.py')),'permission','claude','--pipe',name],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.addCleanup(child.stdout.close);self.addCleanup(child.stderr.close)
        self.addCleanup(lambda:child.kill() if child.poll() is None else None)
        child.stdin.write(json.dumps(PAYLOAD).encode());child.stdin.close()
        self.spin(lambda:bool(server.pending));self.assertIsNone(child.poll())
        request=next(iter(server.pending.values()));self.assertEqual(request['detail'],'python -m unittest')
        server.resolve(request['id'],'allow')
        self.spin(lambda:child.poll() is not None)
        self.assertEqual(json.loads(child.stdout.read())['hookSpecificOutput']['decision']['behavior'],'allow')
        self.assertFalse(server.pending)

    def test_cancelled_hook_withdraws_card_and_malformed_frame_cannot_wait(self):
        name,server=self.server();socket=QLocalSocket();socket.connectToServer(name)
        self.assertTrue(socket.waitForConnected(500))
        envelope=json.dumps(dict(kind='permission',source='claude',payload=PAYLOAD)).encode()
        socket.write(struct.pack('!I',len(envelope))+envelope);socket.flush()
        self.spin(lambda:bool(server.pending));socket.abort();self.spin(lambda:not server.pending)
        bad=QLocalSocket();bad.connectToServer(name);self.assertTrue(bad.waitForConnected(500))
        bad.write(struct.pack('!I',LIMIT+1));bad.flush()
        self.spin(lambda:bad.state()==QLocalSocket.LocalSocketState.UnconnectedState)
        self.assertFalse(server.pending)

    def meter(self):
        from views import SimpleMeterView
        from preferences import load
        meter=SimpleMeterView('Claude',self.app.primaryScreen(),load(dict(glass=False,edge='left')),lambda _:None,preview=True)
        meter.set_data(dict(local=dict(sessions=[]),quota=dict(windows=[])));meter.place(80,100);meter.show()
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
        return meter

    def action_point(self,meter,action):
        from PySide6.QtCore import QPointF
        meter.panel.grab()
        rect=next(rect for rect,entry in meter.panel.hits if isinstance(entry,tuple) and entry[2]==action)
        return (rect.center()+QPointF(18,14)).toPoint()

    def test_real_hook_to_real_card_requires_release_inside_the_actual_allow_button(self):
        from PySide6.QtCore import Qt,QPoint
        name,server=self.server();meter=self.meter()
        meter.attention_callback=server.resolve
        server.changed.connect(lambda:meter.set_attention(list(server.pending.values())))
        child=subprocess.Popen([sys.executable,str(Path(__file__).with_name('attention_hook.py')),'permission','claude','--pipe',name],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.addCleanup(child.stdout.close);self.addCleanup(child.stderr.close)
        self.addCleanup(lambda:child.kill() if child.poll() is None else None)
        child.stdin.write(json.dumps(PAYLOAD).encode());child.stdin.close()
        with patch('motion.animations_enabled',return_value=False):
            self.spin(lambda:bool(server.pending));meter.hover()
            self.assertTrue(meter.panel.isVisible());self.assertIsNone(child.poll())
            point=self.action_point(meter,'allow')
            QTest.mousePress(meter.panel,Qt.MouseButton.LeftButton,pos=point)
            self.assertIsNone(child.poll());self.assertTrue(server.pending)
            QTest.mouseRelease(meter.panel,Qt.MouseButton.LeftButton,pos=QPoint(0,0))
            self.assertTrue(server.pending)
            QTest.mouseClick(meter.panel,Qt.MouseButton.LeftButton,pos=point)
            self.spin(lambda:child.poll() is not None)
        self.assertEqual(json.loads(child.stdout.read())['hookSpecificOutput']['decision']['behavior'],'allow')
        self.assertFalse(server.pending);self.assertFalse(meter.attention_events)

    def test_reply_card_has_real_actions_and_keeps_a_failed_navigation_retryable(self):
        from PySide6.QtCore import Qt
        meter=self.meter();event=completion('claude',dict(hook_event_name='Stop',session_id=str(uuid.uuid4()),title='Build the dashboard',last_assistant_message='The dashboard is ready.'))
        meter.attention_callback=Mock();meter.attention_can_navigate=lambda _:True;meter.attention_navigate=lambda _:False
        with patch('motion.animations_enabled',return_value=False):
            meter.set_attention([event]);meter.hover()
            self.assertTrue(meter.panel.isVisible())
            QTest.mouseClick(meter.panel,Qt.MouseButton.LeftButton,pos=self.action_point(meter,'navigate'))
        self.assertIn(event['id'],meter.attention_navigation_failed)
        meter.attention_callback.assert_not_called()
        meter.attention_navigate=lambda _:True
        QTest.mouseClick(meter.panel,Qt.MouseButton.LeftButton,pos=self.action_point(meter,'navigate'))
        meter.attention_callback.assert_called_once_with(event['id'],'dismiss')

    def test_wait_deadline_returns_no_opinion_and_dismisses_the_pending_card(self):
        name='agent-hud-test-'+uuid.uuid4().hex
        server=AttentionServer(name=name,wait_minutes=lambda:.001)
        self.addCleanup(server.close)
        socket=QLocalSocket();socket.connectToServer(name);self.assertTrue(socket.waitForConnected(500))
        raw=json.dumps(dict(kind='permission',source='claude',payload=PAYLOAD)).encode()
        socket.write(struct.pack('!I',len(raw))+raw);socket.flush()
        self.spin(lambda:bool(server.pending));self.spin(lambda:not server.pending)
        self.assertFalse(bytes(socket.readAll()))

    def test_hook_installation_is_idempotent_reversible_and_preserves_foreign_settings(self):
        from attention_hooks import configure_all,merge
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);root=home/'.claude';root.mkdir();path=root/'settings.json'
            foreign=dict(permissions=dict(defaultMode='default'),hooks=dict(PermissionRequest=[dict(matcher='Read',hooks=[dict(type='command',command='other-hook',timeout=7)])]))
            path.write_text(json.dumps(foreign))
            configure_all(home=home,environment={});first=path.read_bytes()
            configure_all(home=home,environment={});self.assertEqual(path.read_bytes(),first)
            configure_all(remove=True,home=home,environment={})
            self.assertEqual(json.loads(path.read_bytes()),foreign)
            self.assertFalse((home/'.workbuddy').exists())
        with self.assertRaises(ValueError):merge(dict(hooks=dict(PermissionRequest='unknown')),'claude')

    def test_answer_in_client_settles_only_the_matching_future_transcript_call(self):
        from permission_transcript import PermissionTranscriptWatch
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'session.jsonl'
            def use(identifier,inputs=PAYLOAD['tool_input']):return dict(message=dict(content=[dict(type='tool_use',name='Bash',id=identifier,input=inputs)]))
            def result(identifier):return dict(message=dict(content=[dict(type='tool_result',tool_use_id=identifier,content='not retained')]))
            path.write_text('\n'.join(map(json.dumps,[use('old'),result('old'),use('new')]))+'\n')
            watch=PermissionTranscriptWatch({**PAYLOAD,'transcript_path':str(path)});self.addCleanup(watch.close)
            self.assertFalse(watch.poll())
            with path.open('a') as stream:stream.write(json.dumps(result('other'))+'\n')
            self.assertFalse(watch.poll())
            with path.open('a') as stream:stream.write(json.dumps(result('new'))+'\n')
            self.assertTrue(watch.poll());self.assertFalse(watch.calls)
            moved=path.with_suffix('.rotated');path.rename(moved)
            watch.close()

    def test_gui_launcher_installs_a_console_callback_instead_of_pythonw(self):
        from attention_hooks import hook_python
        with tempfile.TemporaryDirectory() as directory:
            python=Path(directory)/'python.exe';python.write_bytes(b'fixture')
            self.assertEqual(hook_python(str(Path(directory)/'pythonw.exe')),str(python))
            python.unlink()
            with self.assertRaises(FileNotFoundError):hook_python(str(Path(directory)/'pythonw.exe'))

    def test_disabled_live_status_does_not_accumulate_replies_to_replay_later(self):
        name='agent-hud-test-'+uuid.uuid4().hex
        enabled=False
        server=AttentionServer(name=name,completion_enabled=lambda _:enabled)
        self.addCleanup(server.close)
        event=completion('claude',dict(hook_event_name='Stop',session_id='s',turn_id='t'))
        server.add_completion(event);self.assertFalse(server.pending)
        enabled=True
        self.assertFalse(server.pending)

    def test_hook_with_unclosed_stdin_returns_to_client_within_source_deadline(self):
        child=subprocess.Popen([sys.executable,str(Path(__file__).with_name('attention_hook.py')),'permission','claude'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.addCleanup(child.stdin.close);self.addCleanup(child.stdout.close);self.addCleanup(child.stderr.close)
        self.addCleanup(lambda:child.kill() if child.poll() is None else None)
        child.stdin.write(b'{}');child.stdin.flush()
        child.wait(timeout=6.5)
        self.assertEqual(child.returncode,0);self.assertEqual(child.stdout.read(),b'')


if __name__=='__main__':unittest.main()
