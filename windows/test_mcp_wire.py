import io,json,os,queue,struct,subprocess,sys,threading,time,unittest,uuid
from pathlib import Path
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
from mcp_protocol import Server,LineBuffer,VERSION_KEY,CAPABILITIES_KEY,parse,serve,validate_reply
from mcp_channel import call,REQUEST_LIMIT

ROOT=Path(__file__).parent


def read_line(stream,timeout=10):
    result=queue.Queue()
    thread=threading.Thread(target=lambda:result.put(stream.readline()),daemon=True);thread.start()
    return result.get(timeout=timeout)


class MCPWire(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication
        cls.app=QApplication.instance() or QApplication([])
    def child(self,script,*args):
        process=subprocess.Popen([sys.executable,'-u','-c',script,*args],cwd=ROOT,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        def cleanup():
            if process.poll() is None:process.terminate()
            process.communicate(timeout=5)
        self.addCleanup(cleanup);return process
    def app_channel(self,mode='echo'):
        name='agent-hud-mcp-test-'+uuid.uuid4().hex
        script="""import sys,time
from PySide6.QtCore import QCoreApplication
from mcp_channel import AppChannel
app=QCoreApplication([])
def handler(request):
    if sys.argv[2]=='off':raise SystemExit(9)
    if sys.argv[2]=='hang':time.sleep(1)
    return {'ok':True,'result':{'echo':request,'blob':'x'*(2*1024*1024) if sys.argv[2]=='large' else ''}}
server=AppChannel(handler,name=sys.argv[1],enabled=lambda:sys.argv[2]!='off')
print('ready' if server.listening else 'failed',flush=True)
app.exec()
"""
        process=self.child(script,name,mode);self.assertEqual(read_line(process.stdout).strip(),b'ready')
        return name
    def test_real_named_pipe_preserves_requests_and_large_replies_drain_before_close(self):
        for mode in ('echo','large'):
            with self.subTest(mode=mode):
                name=self.app_channel(mode);request=dict(tool='get_hud',arguments={'screen':'测试🎮'})
                reply=call(request,name=name,timeout=5)
                self.assertTrue(reply.get('ok'));self.assertEqual(reply['result']['echo'],request)
                self.assertEqual(len(reply['result']['blob']),2*1024*1024 if mode=='large' else 0)
    def test_disabled_app_does_not_execute_the_handler_and_missing_app_is_not_started(self):
        self.assertEqual(call({'tool':'get_hud'},name=self.app_channel('off'),timeout=1),{'state':'off'})
        self.assertEqual(call({'tool':'get_hud'},name='missing-'+uuid.uuid4().hex,timeout=.1),{'state':'notRunning'})
    def test_unresponsive_app_does_not_hold_stdio_past_the_call_deadline(self):
        name=self.app_channel('hang');started=time.monotonic();reply=call({'tool':'get_hud'},name=name,timeout=.1)
        self.assertEqual(reply,{'state':'unanswered'});self.assertLess(time.monotonic()-started,.6)
    def test_request_and_reply_bounds_and_images_are_checked(self):
        self.assertFalse(call({'tool':'get_hud','arguments':{'large':'x'*REQUEST_LIMIT}},name='never-connect')['ok'])
        for value in (None,{},dict(ok=True,result=[],images=[]),dict(ok=True,result={},images=[dict(mimeType='image/png',data='invalid!!')])):
            self.assertIsNone(validate_reply(value))
        self.assertIsNotNone(validate_reply(dict(ok=True,result={},images=[dict(mimeType='image/png',data='AQID')])))
    def test_interactive_stdio_answers_before_eof_and_keeps_stdout_json_only(self):
        script="from mcp import main;main()"
        process=self.child(script)
        process.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize"}\n');process.stdin.flush()
        reply=json.loads(read_line(process.stdout));self.assertEqual(reply['id'],1);self.assertIn('protocolVersion',reply['result'])
        self.assertIsNone(process.poll())
        process.stdin.write(b'{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n');process.stdin.flush()
        tools=json.loads(read_line(process.stdout))['result']['tools'];self.assertEqual(len(tools),5)
    def test_fragmented_utf8_lines_overlong_line_and_unterminated_tail(self):
        buffer=LineBuffer(12);self.assertEqual(buffer.take(b'one\r'),[])
        self.assertEqual(buffer.take(b'\ntwo\npar'),[b'one',b'two'])
        self.assertEqual(buffer.take(b'tial\n'+b'x'*100),[b'partial']);self.assertEqual(len(buffer.pending),12)
        self.assertEqual(buffer.take(b'\nok\r\n'),[b'x'*12,b'ok']);self.assertIsNone(buffer.rest())
        buffer.take('🎮'.encode());self.assertEqual(buffer.rest(),'🎮'.encode())
    def test_source_json_numbers_and_duplicate_keys_keep_the_original_meaning(self):
        self.assertEqual(parse('{"id":1.000,"id":2,"exponent":1e0}'),{'id':1,'exponent':1})
        self.assertIs(type(parse('1e0')),int);self.assertIs(type(parse('1.5')),float)
        for text in ('NaN','1e999','"\\ud800"','{"x":1,"x":"\\ud800"}'):
            with self.assertRaises((ValueError,UnicodeError)):parse(text)
    def test_batch_subscriptions_are_acknowledged_ahead_of_the_response_array(self):
        server=Server('wire-test',lambda _:dict(ok=True,result={}))
        request=dict(jsonrpc='2.0',id='s',method='subscriptions/listen',params={'_meta':{VERSION_KEY:'2026-07-28',CAPABILITIES_KEY:{}}})
        answers=[json.loads(value) for value in server.lines(json.dumps([request,dict(jsonrpc='2.0',id=2,method='ping')]))]
        self.assertEqual(answers[0]['method'],'notifications/subscriptions/acknowledged')
        self.assertEqual([value['id'] for value in answers[1]],['s',2])
    def test_notifications_and_stray_responses_do_not_execute_tools_or_write_responses(self):
        calls=[];server=Server('wire-test',lambda request:calls.append(request))
        output=io.BytesIO()
        serve(io.BytesIO(b'{"jsonrpc":"2.0","method":"tools/call","params":{"name":"get_hud"}}\n{"jsonrpc":"2.0","id":1,"result":{}}\n'),output,server)
        self.assertEqual(output.getvalue(),b'');self.assertEqual(calls,[])

    def test_compiled_original_server_wire_contract(self):
        contract=json.loads((ROOT/'assets/upstream-mcp-wire-contract.json').read_text(encoding='utf-8'))
        def normalized(value):
            if isinstance(value,list):return [normalized(item) for item in value]
            if isinstance(value,dict):
                result={key:normalized(item) for key,item in value.items()}
                if isinstance(result.get('instructions'),str):result['instructions']=result['instructions'].replace("at the Mac's notch","in the Windows HUD")
                if result.get('type')=='text':
                    try:result['text']=normalized(json.loads(result['text']))
                    except (ValueError,TypeError):pass
                return result
            return value
        for index,case in enumerate(contract['cases']):
            with self.subTest(index=index,state=case['state']):
                calls=[]
                def callback(request):
                    calls.append(request);state=case['state']
                    if state in ('off','notRunning','unanswered'):return {'state':state}
                    if state=='failure':return dict(ok=False,error='Fixture failure.')
                    if state=='image':return dict(ok=True,result={'fixture':True},images=[dict(mimeType='image/png',data='AQID')])
                    return dict(ok=True,result={'echo':request})
                actual=Server('wire-test',callback).lines(case['input'])
                self.assertEqual(normalized([json.loads(item) for item in actual]),normalized([json.loads(item) for item in case['answers']]))
                self.assertEqual(len(calls),case['calls'])


if __name__=='__main__':unittest.main()
