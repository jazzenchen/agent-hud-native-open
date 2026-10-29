import io,json,sqlite3,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
from usage_ledger import UsageLedger
from session_formats import Transcript,tencent_tokens
from local_sources import LocalSource
from cursor_usage import parse_events,reconcile
from providers import codex_quota,parse_cursor_quota
from runtime import Monitor,classify_clients
from preferences import load
from usage_display import hourly,account_label


class UsageCases(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.home=Path(self.temp.name);self.ledger=UsageLedger(self.home/'ledger.db');self.at=time.time()
    def event(self,**fields):
        return dict(dict(id='one',session='s',model='m',at=self.at,input=10,output=6,cache=8,cache_write=3,reasoning=2),**fields)
    def test_restart_dedup_subsets_and_coherent_request_correction(self):
        for _ in range(3):self.ledger.record('Claude',[self.event()])
        report=self.ledger.report('Claude');self.assertEqual(report['event_count'],1)
        self.assertEqual(report['totals']['total'],24);self.assertEqual(report['totals']['fresh_input'],7);self.assertEqual(report['totals']['visible_output'],4)
        # Same total, corrected cache split must replace one observation, not MAX each column.
        self.ledger.record('Claude',[self.event(input=8,cache=10)])
        self.assertEqual(self.ledger.report('Claude')['totals']['total'],24)
    def test_account_history_cannot_attribute_anonymous_past_requests(self):
        self.ledger.record('Codex',[self.event()],[dict(id='a',label='A',evidence='account')])
        self.assertEqual(self.ledger.report('Codex',account='a')['event_count'],0)
        self.assertEqual(self.ledger.report('Codex')['accounts'][0]['label'],'A')
        self.assertEqual(account_label({}),'账户身份未确认')
    def test_cursor_accounts_do_not_merge_or_recount_on_refresh(self):
        rows=[dict(timestamp=int(self.at*1000),model='m',conversationId='s',tokenUsage=dict(inputTokens=10,outputTokens=5,cacheReadTokens=20,cacheWriteTokens=3))]
        for account in ('a','b','a'):
            parsers=parse_events(rows,account);self.ledger.record('Cursor',[e for p in parsers for e in p.events.values()])
        self.assertEqual(self.ledger.report('Cursor')['event_count'],2)
        self.assertEqual(self.ledger.report('Cursor',account='a')['totals']['total'],38)
    def test_cursor_overlap_reconciliation_does_not_drop_equal_distinct_requests(self):
        self.assertEqual(reconcile([[1,2,3],[3,4]],4),[1,2,3,4])
        self.assertEqual(reconcile([[1,1],[1]],3),[1,1,1])
        with self.assertRaises(ValueError):reconcile([[1,2],[4]],2)
    def test_cursor_all_source_pools_and_reset_timestamp(self):
        data=parse_cursor_quota(dict(membershipType='pro',billingCycleEnd='2030-01-01T00:00:00Z',individualUsage=dict(plan=dict(totalPercentUsed=0,autoPercentUsed=20,apiPercentUsed=30),overall=dict(used=1,limit=2),onDemand=dict(used=2,limit=4)),teamUsage=dict(pooled=dict(used=3,limit=6))))
        self.assertEqual(len(data['windows']),6);self.assertEqual(data['windows'][0]['used'],0)
        self.assertIsInstance(data['windows'][0]['reset'],float)
    def test_codex_fork_reads_inherited_baseline_without_counting_parent(self):
        p=Transcript('Codex','file')
        p.feed(dict(type='session_meta',timestamp=self.at,payload=dict(id='child',timestamp=self.at,subagent_history_start_ordinal=5)),1)
        def usage(n,ordinal):return dict(type='event_msg',timestamp=self.at+ordinal,ordinal=ordinal,payload=dict(type='token_count',info=dict(total_token_usage=dict(input_tokens=n,cached_input_tokens=n//2,output_tokens=10,reasoning_output_tokens=3))))
        p.feed(usage(100,5),2);p.feed(usage(140,6),3);p.feed(usage(140,6),4)
        self.assertEqual(len(p.events),1);self.assertEqual(p.summary()['tokens'],40)
    def test_claude_streaming_snapshots_deduplicate_by_response_id(self):
        p=Transcript('Claude','s')
        for out in (1,4,2):p.feed(dict(type='assistant',timestamp=self.at,message=dict(id='request',model='sonnet',usage=dict(input_tokens=10,cache_creation_input_tokens=3,cache_read_input_tokens=20,output_tokens=out))),out)
        self.assertEqual(len(p.events),1);self.assertEqual(p.summary()['tokens'],37)
    def test_tencent_source_fixture_and_user_title_precedence(self):
        # TencentBuddyProviderTests' nested cache fixture is inclusive.
        self.assertEqual(tencent_tokens(dict(inputTokens=100,outputTokens=10,totalTokens=110,inputTokensDetails=[dict(cached_tokens=60)]))['input'],40)
        p=Transcript('WorkBuddy','s')
        for kind,key,name in [('custom-title','customTitle','My parser'),('ai-title','aiTitle','Later title')]:p.feed(dict(type=kind,**{key:name}),1)
        self.assertEqual(p.title,'My parser')
    def test_incremental_local_reader_partial_line_restart_and_no_prompt_storage(self):
        root=self.home/'.codebuddy/projects/repo';root.mkdir(parents=True);path=root/'s.jsonl'
        row=dict(type='message',role='assistant',status='completed',timestamp=self.at,id='request',providerData=dict(model='glm',usage=dict(inputTokens=100,outputTokens=10,totalTokens=110)),message=dict(content='PRIVATE_PROMPT'))
        path.write_text(json.dumps(row),encoding='utf-8');source=LocalSource('CodeBuddy',self.home,{},self.ledger)
        self.assertEqual(source.sessions()['stats']['event_count'],0)
        with path.open('a',encoding='utf-8') as f:f.write('\n')
        self.assertEqual(source.sessions()['stats']['event_count'],1)
        self.assertEqual(LocalSource('CodeBuddy',self.home,{},self.ledger).sessions()['stats']['event_count'],1)
        self.assertNotIn(b'PRIVATE_PROMPT',(self.home/'ledger.db').read_bytes())
    def test_opencode_single_json_without_newline_is_read(self):
        root=self.home/'.local/share/opencode/storage/message/s';root.mkdir(parents=True)
        (root/'m.json').write_text(json.dumps(dict(id='m',sessionID='s',role='assistant',modelID='m',time=dict(created=int(self.at*1000)),tokens=dict(input=10,output=5,reasoning=3,cache=dict(read=20,write=2)))))
        report=LocalSource('OpenCode',self.home,{},self.ledger).sessions()['stats']
        self.assertEqual(report['totals']['total'],40);self.assertEqual(report['totals']['visible_output'],5)
    def test_zcode_old_inclusive_schema_matches_upstream(self):
        root=self.home/'.zcode/cli/db';root.mkdir(parents=True)
        with sqlite3.connect(root/'db.sqlite') as db:
            db.execute('CREATE TABLE model_usage(id,session_id,model_id,started_at,completed_at,input_tokens,output_tokens,reasoning_tokens,cache_read_input_tokens,cache_creation_input_tokens)')
            db.execute('INSERT INTO model_usage VALUES(1,"s","m",?,NULL,100,20,5,60,4)',(self.at*1000,))
        db.close()
        data=LocalSource('ZCode',self.home,{},self.ledger).sessions()['stats'];self.assertEqual(data['totals']['total'],120);self.assertEqual(data['totals']['visible_output'],15)
    def test_hourly_uses_actual_event_time_not_session_mtime(self):
        self.ledger.record('Claude',[self.event(at=self.at-7200)])
        bins=hourly([self.ledger.report('Claude')],now=self.at)
        self.assertEqual(bins[-1]['total'],0);self.assertEqual(bins[-3]['total'],24)
        self.assertEqual(sum(bins[-3][key] for key in ('fresh_input','cache','cache_write','visible_output','reasoning')),24)
    def test_new_provider_monitor_is_not_hardcoded_and_closed_app_is_not_read(self):
        opened={'WorkBuddy'};calls=[]
        m=Monitor(lambda _:None,presence=lambda:opened,local={'WorkBuddy':lambda:calls.append(1) or dict(sessions=[])},quota={})
        self.assertEqual(set(m.poll_once()),{'WorkBuddy'});opened.clear();self.assertEqual(m.poll_once(),{});self.assertEqual(calls,[1]);m.stop.set()
        self.assertEqual(classify_clients([dict(pid=1,name='WorkBuddy.exe',exe='',cmdline=[])],set()),set())
        self.assertEqual(classify_clients([dict(pid=1,name='WorkBuddy.exe',exe='',cmdline=[])],{1}),{'WorkBuddy'})
    def test_schema_migration_keeps_disabled_old_client_and_new_disable_persists(self):
        settings=load(dict(enabled_clients=['Codex']));self.assertNotIn('Cursor',settings['enabled_clients']);self.assertIn('WorkBuddy',settings['enabled_clients'])
        settings['enabled_clients'].remove('WorkBuddy');self.assertNotIn('WorkBuddy',load(settings)['enabled_clients'])
    def test_codex_same_engine_account_reply_and_optional_account_method(self):
        class Buffer(io.StringIO):
            def close(self):pass
        class Process:
            pid=-999
            def __init__(self,error=False):
                self.stdin=Buffer();self.stdout=Buffer('\n'.join(map(json.dumps,[dict(id=1,result={}),dict(id=2,result=dict(accountId='workspace',rateLimits=dict(primary=dict(usedPercent=10)))),dict(id=3,**(dict(error=dict(message='unsupported')) if error else dict(result=dict(account=dict(type='chatgpt',email='a@example.com',planType='pro')))))]))+'\n')
            def poll(self):return 0
        for error in (False,True):
            proc=Process(error)
            with patch('providers.subprocess.Popen',return_value=proc):result=codex_quota('fixture-engine')
            self.assertEqual(result['windows'][0]['used'],10);self.assertIn('account/read',proc.stdin.getvalue())
            if not error:self.assertEqual(result['account']['label'],'a@example.com')

    def test_statistics_window_refreshes_models_without_copying_session_tab(self):
        from PySide6.QtWidgets import QApplication,QTableWidget,QTabWidget
        from application import UsageWindow
        app=QApplication.instance() or QApplication([])
        self.ledger.record('Codex',[self.event()]);stats=self.ledger.report('Codex')
        data=dict(local=dict(stats=stats,sessions=[dict(id='s',title='Session',state='done',tokens=24)]))
        window=UsageWindow('Codex',data,True);self.addCleanup(window.close);window.show();app.processEvents()
        self.assertEqual(window.findChild(QTabWidget).count(),2)
        models=window.findChild(QTableWidget,'tokenModels');sessions=window.findChild(QTableWidget,'usageSessions')
        self.assertEqual(models.columnCount(),7);self.assertEqual(sessions.columnCount(),3)
        self.ledger.record('Codex',[self.event(id='two',model='other')]);data['local']['stats']=self.ledger.report('Codex');window.sync(data)
        self.assertEqual(models.rowCount(),2);self.assertEqual(sessions.rowCount(),1)


if __name__=='__main__':unittest.main()
