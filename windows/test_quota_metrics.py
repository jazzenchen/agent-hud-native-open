import tempfile,unittest
import sqlite3
from pathlib import Path
from unittest.mock import patch
from PySide6.QtWidgets import QApplication
from PySide6.QtCore import QPointF,Qt
from PySide6.QtTest import QTest
from catalog_pricing import summed_cost,listing
from quota_metrics import reply_rate,summarize,WindowMetrics
from quota_metric_views import presentation
from usage_ledger import UsageLedger


def contract():
    rates=dict(input='2',cache_write='2.5',cache='.1',output='10')
    price=dict(currency='USD',rates=rates)
    return dict(vendorServices={'openai':'OpenAI'},models={'gpt-test':{'vendor':'OpenAI','prices':dict(international=price),
        'global':True,'peak_hours':False}})


def event(key,at,session='one',model='gpt-test',**extra):
    return {**dict(id=key,at=at,session=session,model=model,input=10,output=20,cache=30,cache_write=2,reasoning=5),**extra}


class QuotaMetrics(unittest.TestCase):
    def test_original_export_has_exact_aliases_and_keeps_bucket_cost_distinct_from_prompt_tiers(self):
        from catalog_pricing import catalog
        data=catalog();self.assertEqual(len(data['models']),130);self.assertEqual(data['checkedOn'],'2026-09-25')
        cost=summed_cost('gpt-6.1-sol',dict(input=100000,cache_write=100000,cache=100000,output=1000))
        self.assertEqual(str(cost['amount']),'0.27')
        # This is summed-bucket pricing, not the tier of a made-up large prompt.
        self.assertEqual(str(summed_cost('gpt-6.1-sol',dict(input=300000,output=0))['amount']),'0.6')
        value=summed_cost('claude-sonnet-5-5-20260901',dict(input=2000000,cache_write=1000000,cache=1000000,output=100000))
        self.assertEqual(str(value['amount']),'7.2')
        self.assertIsNone(summed_cost('codex-auto-review',dict(input=100000,output=1000)))
        from datetime import datetime,timezone
        model=next(name for name,row in data['models'].items() if row['peak_hours'])
        busy=datetime(2026,10,19,2,tzinfo=timezone.utc).timestamp()
        quiet=datetime(2026,10,18,2,tzinfo=timezone.utc).timestamp()
        self.assertEqual(summed_cost(model,dict(input=100),at=busy)['amount'],2*summed_cost(model,dict(input=100),at=quiet)['amount'])
    def test_reply_gaps_keep_other_models_in_log_but_never_borrow_another_session(self):
        events=[event('a',1000,model='other'),event('b',1060),event('c',1100,session='two'),
                event('d',1250),event('e',1250)]
        result=reply_rate(events,{'gpt-test'})
        self.assertEqual(result['calls'],1);self.assertEqual(result['tokens_out'],20)
        self.assertAlmostEqual(result['tokens_per_second'],1/3)
        self.assertIsNone(reply_rate(events,{'unseen'}))
    def test_summed_price_uses_base_rates_and_prices_inclusive_subsets_once(self):
        data=contract();counts=event('a',1000)
        self.assertEqual(str(summed_cost('gpt-test',counts,contract=data)['amount']),'0.000224')
        self.assertIsNotNone(listing('codex-model:GPT-TEST-20260101[1m]#openai',contract=data))
        self.assertIsNone(listing('gpt-test#OpenAI',contract=data))
        self.assertIsNone(listing('gateway/gpt-test',contract=data))
        self.assertIsNone(summed_cost('unknown',counts,contract=data))
        data['models']['gpt-test']['global']=False
        self.assertIsNone(summed_cost('gpt-test',counts,region='china',contract=data))
    def test_cycle_bucket_boundary_consumption_rate_and_currency_are_consistent(self):
        events=[event('a',900),event('b',960),event('c',1200)]
        result=summarize(events,0,3600,{'gpt-test'},contract=contract())
        self.assertEqual(result['consumed']['used'],180)
        self.assertEqual(result['tokens_per_hour'],120)
        self.assertEqual(result['cost']['amounts'],{'USD':'0.000672'})
        self.assertEqual(result['reply']['calls'],1)
        # Source bucket started before the cycle: do not invent a partial bucket.
        excluded=summarize(events,901,3600,{'gpt-test'},contract=contract())
        self.assertEqual(excluded['consumed']['used'],0)
    def test_read_only_window_query_obeys_account_and_priority_without_attributing_past(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'usage.sqlite';ledger=UsageLedger(path)
            ledger.record('Cursor',[event('anonymous',1000),event('a',1100,account='a'),event('b',1150,account='b'),
                                    event('low',1200,session='duplicate',account='a',priority=0),
                                    event('high',1200,session='duplicate',account='a',priority=1)])
            reader=WindowMetrics(path)
            rows=reader.events('Cursor','a',900,1500)
            self.assertEqual({row['id'] for row in rows},{'a','high'})
            quota=dict(at=1500,account=dict(id='a'),windows=[dict(label='Included',used=20,reset=1900,duration=1000)])
            result=reader('Cursor',quota,{},now=1500)['windows'][0]['metrics']
            self.assertEqual(result['consumed']['used'],180);self.assertEqual(result['scope'],'local')
            foreign={**quota,'account':dict(id='b'),'windows':[{**quota['windows'][0],'account_id':'a'}]}
            separate=reader('Cursor',foreign,{},now=1500)['windows'][0]['metrics']
            self.assertEqual(separate['consumed']['used'],120);self.assertEqual(separate['scope'],'account')
            self.assertIsNone(reader('Cursor',{**quota,'stale':True},{},now=1500)['windows'][0]['metrics']['consumed'])
            unknown={**quota,'account':dict(id='unseen')}
            local=reader('Cursor',unknown,{},now=1500)['windows'][0]['metrics']
            self.assertEqual(local['consumed']['used'],60);self.assertEqual(local['scope'],'local')
            self.assertEqual(ledger.report('Cursor',account='unseen')['event_count'],0)
            # Moving wall time must not defeat the 15-second query/derive cache.
            cached=WindowMetrics(path)
            with patch('quota_metrics.sqlite3.connect',wraps=sqlite3.connect) as connect:
                first=cached('Cursor',quota,{},now=1501)['windows'][0]['metrics']
                again=cached('Cursor',quota,{},now=1504)['windows'][0]['metrics']
                self.assertEqual(connect.call_count,1);self.assertEqual(first,again)
            with patch('usage_ledger.time.time',return_value=1500):self.assertEqual(ledger.report('Cursor')['event_count'],4)
    def test_reported_credit_pool_and_unknown_cycle_do_not_become_fake_token_counts(self):
        reader=WindowMetrics(Path('not-created-demo.sqlite'))
        quota=dict(at=1500,account=dict(id='a'),credit_balance=dict(used=125.5,total=1000),
            windows=[dict(id='workbuddy:credits',label='积分',used=12.55)])
        metrics=reader('WorkBuddy',quota,{},now=1500)['windows'][0]['metrics']
        self.assertEqual(metrics['consumed'],dict(used=125.5,capacity=1000.))
        self.assertIsNone(metrics['reply']);self.assertIsNone(metrics['cost'])
    def test_source_reply_horizon_prefers_recent_hour_then_last_observed_week_independent_of_cycle(self):
        from quota_metrics import recent_reply_rate
        now=10000;rows=[event('a',1000,output=20),event('b',1060,output=60),event('c',9000,output=10),event('d',9030,output=15)]
        self.assertEqual(recent_reply_rate(rows,None,now)['tokens_per_second'],.5)
        self.assertEqual(recent_reply_rate(rows[:2],None,now)['tokens_per_second'],1)
        self.assertIsNone(recent_reply_rate(rows[:2],None,now+8*86400))
    def test_row_forecast_and_stale_unknown_display_share_the_source_outlook(self):
        row=dict(used=80,reset=20000,duration=18000,insights=dict(rate=20))
        shown=presentation(row,'burn',now=15000)
        self.assertEqual(shown['value'],'20.0%/h');self.assertTrue(shown['warning']);self.assertEqual(shown['fraction'],1)
        self.assertEqual(presentation(row,'burn',fresh=False,now=15000)['value'],'—')
        self.assertEqual(presentation({**row,'used':None},'burn',now=15000)['value'],'—')
        from quota_metric_views import money,short
        self.assertEqual(money('.000001','USD'),'<$0.01')
        self.assertEqual(money('99.999','USD'),'$100')
        self.assertEqual(money('0','CNY'),'¥0.00')
        self.assertEqual(short(2400000),'2.4M');self.assertEqual(short(5040000000),'5.0B')


class MetricPicker(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def test_real_panel_picker_uses_release_and_preserves_each_vendor_selection(self):
        from views import SimpleMeterView
        from preferences import load
        meter=SimpleMeterView('Codex',self.app.primaryScreen(),load(dict(separates_agents=False)),lambda _:None,preview=True)
        self.addCleanup(lambda:(meter.hide_all(),meter.peek.close(),meter.panel.close(),meter.glow.close(),meter.close()))
        reading=dict(quota=dict(windows=[dict(label='5-hour',used=40)],at=10000),local=dict(sessions=[]))
        meter.set_group_data(dict(Codex=reading,Claude=reading));meter.open_panel();meter.panel.animation.jump(1.);meter.panel.grab()
        panel=meter.panel
        def point(metric,vendor='Codex'):
            rect=next(rect for rect,action in panel.hits if action==('metric',vendor,metric))
            return (rect.center()+QPointF(18,14)).toPoint()
        QTest.mousePress(panel,Qt.MouseButton.LeftButton,pos=point('burn'));self.assertNotIn('Codex',panel.metric_selection)
        QTest.mouseRelease(panel,Qt.MouseButton.LeftButton,pos=point('burn'));self.assertEqual(panel.metric_selection['Codex'],'burn')
        panel.grab();QTest.mouseClick(panel,Qt.MouseButton.LeftButton,pos=point('consumed','Claude'))
        self.assertEqual(panel.metric_selection,dict(Codex='burn',Claude='consumed'))
        meter.set_group_data(dict(Codex=reading,Claude=reading));self.assertEqual(panel.metric_selection['Codex'],'burn')
        panel.grab();QTest.mousePress(panel,Qt.MouseButton.LeftButton,pos=point('cost'))
        QTest.mouseRelease(panel,Qt.MouseButton.LeftButton,pos=point('quota'))
        self.assertEqual(panel.metric_selection['Codex'],'burn')


if __name__=='__main__':unittest.main()
