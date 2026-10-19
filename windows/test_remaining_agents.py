"""Source-format fixtures; no client startup, credentials or live quota requests."""
import json,sqlite3,tempfile,time,unittest
from pathlib import Path
from unittest.mock import Mock,patch
from session_formats import Transcript
from four_formats import FileTranscript,otel_count
from antigravity_proto import fields,turn,step
from remaining_quota import copilot_quota,copilot_parse,grok_parse,antigravity_parse
from usage_ledger import UsageLedger
from local_sources import LocalSource
from runtime import classify_clients
from agent_catalog import SUPPORTED,VENDORS
from preferences import load


def vi(n):
    result=bytearray()
    while n>127:result.append((n&127)|128);n>>=7
    result.append(n);return bytes(result)
def f(n,v):
    return vi(n*8)+vi(v) if isinstance(v,int) else vi(n*8+2)+vi(len(v))+v


class RemainingAgents(unittest.TestCase):
    def setUp(self):self.at=int(time.time())
    def test_all_adapters_registered_and_legacy_disabled_choices_preserved(self):
        from provider_registry import LOCAL_VENDORS,defaults
        self.assertEqual(SUPPORTED,set(VENDORS))
        for vendor in ('DeepSeek','Grok','Antigravity','GitHub Copilot'):self.assertIn(vendor,LOCAL_VENDORS)
        local,quota=defaults()
        self.assertEqual(set(local),SUPPORTED);self.assertTrue(set(LOCAL_VENDORS)<=set(quota))
        settings=load(dict(adapter_schema=1,enabled_clients=['Codex']))
        self.assertNotIn('Cursor',settings['enabled_clients']);self.assertIn('DeepSeek',settings['enabled_clients'])
        self.assertFalse(settings['read_copilot_quota'])
    def test_presence_only_matches_cli_package_or_visible_desktop(self):
        rows=[dict(pid=1,name='node.exe',exe='C:/node.exe',cmdline=['node','C:/npm/node_modules/@deepseek-ai/dsh/cli.js']),
              dict(pid=2,name='node.exe',cmdline=['node','C:/npm/node_modules/@github/copilot/cli.js']),
              dict(pid=3,name='agy.exe',cmdline=['agy']),dict(pid=4,name='antigravity.exe',cmdline=[]),
              dict(pid=5,name='node.exe',cmdline=['node','other.js','@xai/grok/'])]
        self.assertEqual(classify_clients(rows,set()),{'DeepSeek','GitHub Copilot','Antigravity'})
        self.assertEqual(classify_clients(rows[3:4],{4}),{'Antigravity'})
    def test_local_reader_to_ledger_pipeline_for_each_remaining_agent(self):
        with tempfile.TemporaryDirectory() as folder:
            home=Path(folder);ledger=UsageLedger(home/'ledger.db')
            fixtures={
                'DeepSeek':('.dsh/sessions/s/session.v4.jsonl',[dict(type='session',version=4,id='s',createdAt=self.at),dict(type='assistant/message',seq=1,time=self.at,data=dict(turn=1,step=1,usage=dict(inputTokens=10,outputTokens=5)))]),
                'Grok':('.grok/logs/unified.jsonl',[dict(msg='shell.turn.inference_done',sid='s',ts=self.at,ctx=dict(prompt_tokens=10,completion_tokens=5))]),
                'GitHub Copilot':('.copilot/session-state/s/events.jsonl',[dict(type='session.start',timestamp=self.at,data={}),dict(type='session.shutdown',timestamp=self.at,data=dict(modelMetrics={'m':dict(usage=dict(inputTokens=10,outputTokens=5))}))])}
            for vendor,(relative,rows) in fixtures.items():
                path=home/relative;path.parent.mkdir(parents=True);path.write_text(''.join(json.dumps(row)+'\n' for row in rows))
            path=home/'.gemini/antigravity-cli/conversations/s.db';path.parent.mkdir(parents=True)
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE gen_metadata(idx INTEGER,data BLOB)')
                db.execute('INSERT INTO gen_metadata VALUES(?,?)',(1,f(1,f(4,f(2,10)+f(3,5))+f(9,f(4,f(1,self.at))))))
            db.close()
            for vendor in (*fixtures,'Antigravity'):
                reader=LocalSource(vendor,home=home,env={},ledger=ledger)
                for _ in range(2):
                    result=reader.sessions();self.assertTrue(result['connected'],vendor)
                    self.assertEqual(result['stats']['totals']['total'],15,vendor)
                    self.assertEqual(result['stats']['event_count'],1,vendor)
                self.assertEqual(reader.errors,0,vendor)

    def test_deepseek_seed_stream_correction_retry_and_ledger_restart(self):
        p=Transcript('DeepSeek','s')
        p.feed(dict(type='session',version=4,id='s',createdAt=self.at,seedLength=10),0)
        def row(seq,out):return dict(type='assistant/chunk',seq=seq,time=self.at,data=dict(turn=1,step=1,usage=dict(inputTokens=10,outputTokens=out,cacheReadTokens=20,cacheWriteTokens=2)))
        p.feed(row(5,99),1);self.assertFalse(p.events)
        p.feed(row(10,8),2);p.feed(row(11,4),3)
        self.assertEqual(len(p.events),1);self.assertEqual(p.summary()['tokens'],36)
        with tempfile.TemporaryDirectory() as folder:
            ledger=UsageLedger(Path(folder)/'ledger.db');ledger.record('DeepSeek',p.events.values())
            p.feed(row(12,2),4);ledger.record('DeepSeek',p.events.values())
            self.assertEqual(UsageLedger(ledger.path).report('DeepSeek')['totals']['total'],34)
        p.feed(dict(type='llm/retry-started',seq=13,time=self.at,data={}),5);p.feed(row(14,1),6)
        self.assertEqual(len(p.events),2)
    def test_deepseek_discovery_prefers_latest_generation(self):
        with tempfile.TemporaryDirectory() as folder:
            home=Path(folder);session=home/'.dsh/sessions/s';session.mkdir(parents=True)
            for name in ('session.jsonl','session.v3.jsonl','session.v4.jsonl'):(session/name).write_text('{}\n')
            reader=LocalSource('DeepSeek',home=home,env={},ledger=UsageLedger(home/'ledger.db'));reader.scan()
            self.assertEqual([p.name for p in reader.files],['session.v4.jsonl'])
    def test_grok_legacy_cache_is_subset_and_event_deduplicates(self):
        p=Transcript('Grok','s');row=dict(method='session/update',params=dict(sessionId='s',_meta=dict(agentTimestampMs=self.at*1000,eventId='e'),update=dict(sessionUpdate='turn_completed',stop_reason='end_turn',usage=dict(inputTokens=100,outputTokens=5,cachedReadTokens=80))))
        p.feed(row,1);p.feed(row,2)
        self.assertEqual(len(p.events),1);event=next(iter(p.events.values()));self.assertEqual((event['input'],event['cache']), (20,80))
    def test_grok_unified_sessions_and_priority_do_not_double_count(self):
        p=FileTranscript('Grok','file')
        for sid in ('a','b'):
            p.feed(dict(sid=sid,pid=3,msg='model changed',ctx=dict(model='grok-4')),0)
            p.feed(dict(sid=sid,pid=3,msg='shell.turn.inference_done',ts=self.at,event_id='one',ctx=dict(prompt_tokens=100,completion_tokens=5,cached_prompt_tokens=80)),1)
        self.assertEqual(len(p.summaries()),2)
        with tempfile.TemporaryDirectory() as folder:
            ledger=UsageLedger(Path(folder)/'ledger.db');events=list(p.events.values())
            ledger.record('Grok',[dict(events[0],id='legacy',priority=1)]);ledger.record('Grok',events)
            self.assertEqual(ledger.report('Grok')['totals']['total'],210)
            self.assertEqual(ledger.report('Grok')['event_count'],2)
    def test_custom_copilot_exporter_only_reads_the_named_file(self):
        with tempfile.TemporaryDirectory() as folder:
            home=Path(folder);exporter=home/'custom'/'trace.jsonl';exporter.parent.mkdir()
            exporter.write_text('{}\n');(exporter.parent/'unrelated.jsonl').write_text('{}\n')
            reader=LocalSource('GitHub Copilot',home=home,env={'COPILOT_OTEL_FILE_EXPORTER_PATH':str(exporter)},ledger=UsageLedger(home/'ledger.db'));reader.scan()
            self.assertEqual(reader.files,[exporter])

    def test_copilot_shutdown_delta_and_baseline(self):
        p=Transcript('GitHub Copilot','s')
        def shutdown(n):return dict(type='session.shutdown',id=str(n),timestamp=self.at,data=dict(modelMetrics={'model':dict(usage=dict(inputTokens=n,outputTokens=5,cacheReadTokens=2))}))
        p.feed(shutdown(20),0);self.assertFalse(p.events)
        p.feed(shutdown(30),1);p.feed(shutdown(30),2)
        self.assertEqual(len(p.events),1);self.assertEqual(p.summary()['tokens'],10)
    def test_copilot_otel_late_trace_context_and_invalid_numbers(self):
        p=FileTranscript('GitHub Copilot','file')
        row=dict(name='chat model',traceId='t',spanId='p',startTime=[self.at,0],attributes={'gen_ai.usage.input_tokens':'100','gen_ai.usage.output_tokens':5,'gen_ai.usage.cache_read.input_tokens':80})
        p.feed(row,0);self.assertFalse(p.events)
        p.feed(dict(traceId='t',attributes={'gen_ai.conversation.id':'s','gen_ai.response.model':'model'}),1)
        event=next(iter(p.events.values()));self.assertEqual((event['input'],event['output'],event['cache']),(20,5,80))
        for value in (True,1.5,-1,'1.5','NaN'):
            with self.assertRaises(ValueError):otel_count(value)
    def test_copilot_quota_requires_consent_without_reading_credentials(self):
        http=Mock()
        with patch('remaining_quota.windows_credential',side_effect=AssertionError('credential access')):
            self.assertTrue(copilot_quota(False,http)['not_provided'])
        http.assert_not_called()
        result=copilot_parse(dict(quota_snapshots=dict(premium_models=dict(percent_remaining=70,entitlement=100,remaining=70))))
        self.assertEqual(result['windows'][0]['used'],30)
    def test_grok_wallet_does_not_become_quota_percentage(self):
        result=grok_parse(dict(config=dict(creditUsagePercent=25,prepaidBalance=dict(val='1234'),onDemandCap=dict(val='1000'),onDemandUsed=dict(val='200'))))
        self.assertEqual(result['wallets'][0]['balance'],12.34);self.assertEqual([r['used'] for r in result['windows']],[25,20])
    def test_antigravity_proto_usage_time_and_unknown_fields(self):
        raw=f(1,f(4,f(2,100)+f(3,20)+f(4,5)+f(5,30))+f(9,f(4,f(1,self.at)))+f(19,b'model'))+f(100,b'unknown')
        data=turn(raw);self.assertEqual(data['usage']['input'],100);self.assertEqual(data['at'],self.at);self.assertEqual(data['model'],'model')
        for invalid in (b'\x80',b'\x0a\x05x',b'\x0f'):
            with self.assertRaises(ValueError):list(fields(invalid))
        self.assertEqual(step(f(1,f(1,self.at))+f(12,b'execution'))['at'],self.at)
    def test_antigravity_legacy_and_cli_use_original_pool_semantics(self):
        from remaining_quota import antigravity_legacy,antigravity_cli_parse
        configs=[dict(modelOrAlias=dict(model='gemini-'+str(n)),quotaInfo=dict(remainingFraction=f)) for n,f in enumerate((.8,.4))]
        result=antigravity_legacy(dict(userStatus=dict(cascadeModelConfigData=dict(clientModelConfigs=configs))))
        self.assertEqual(len(result['windows']),1);self.assertEqual(result['windows'][0]['used'],60)
        root=dict(status='SUCCESS',command=dict(name='usage',data=dict(groups=[dict(name='Gemini Models',buckets=[dict(id='one',name='Weekly',remaining_fraction=.4)])])))
        self.assertEqual(antigravity_cli_parse(root)['windows'][0]['used'],60)
    def test_original_zstd_helper_decodes_multiple_frames(self):
        from upstream_runtime import run,decompress
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'session.v4.jsonl.zstd'
            path.write_bytes(run("const z=require('node:zlib'); process.stdout.write(Buffer.concat(['one\\n','two\\n'].map(x=>z.zstdCompressSync(Buffer.from(x)))));",[]))
            self.assertEqual(decompress(path),b'one\n' + b'two\n')
    def test_antigravity_merged_timestamps_follow_protobuf_singular_merge(self):
        data=turn(f(1,f(9,f(4,f(1,self.at))+f(4,f(2,500000000)))))
        self.assertEqual(data['at'],self.at+.5)

    def test_antigravity_quota_bucket_validation_and_account(self):
        root=dict(groups=[dict(displayName='Models',buckets=[dict(bucketId='one',remainingFraction=.7),dict(bucketId='off',disabled=True)])])
        result=antigravity_parse(root,dict(userStatus=dict(email='a@example.test',teamId='t')))
        self.assertAlmostEqual(result['windows'][0]['used'],30);self.assertEqual(result['account']['evidence'],'account')
        root['groups'][0]['buckets'].append(dict(bucketId='one',remainingFraction=.5))
        with self.assertRaises(ValueError):antigravity_parse(root)

if __name__=='__main__':unittest.main()
