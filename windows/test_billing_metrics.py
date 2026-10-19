import json,tempfile,unittest,math
from pathlib import Path
from decimal import Decimal
from unittest.mock import patch
from billing_metrics import period_metrics,money,figures,official_price,runs_out,spend,DURATIONS
from quota_metrics import WindowMetrics
from usage_ledger import UsageLedger
from session_formats import Transcript


def event(key,at,**extra):
    return dict(id=key,at=at,session='one',model='deepseek-v4-flash',input=1000000,output=0,cache=0,**extra)


class BillingMetrics(unittest.TestCase):
    def test_compiled_original_swift_balance_spend_contract(self):
        contract=json.loads((Path(__file__).parent/'assets/upstream-balance-contract.json').read_text(encoding='utf-8'))
        self.assertEqual(len(contract['cases']),72)
        for index,case in enumerate(contract['cases']):
            with self.subTest(index=index):
                end=math.ceil(case['now']/900)*900
                result=spend(case['costs'],case['currency'],end-DURATIONS[case['period']],end,case['now'])
                if case['cost'] is None:self.assertIsNone(result);continue
                self.assertEqual(Decimal(result['cost']),Decimal(case['cost']))
                self.assertEqual(result['span'],case['span']);self.assertAlmostEqual(float(result['per_day']),float(case['perDay']),places=12)
                predicted=runs_out('8.5',result['cost'],result['span'],case['now']-600)
                if case['runsOut'] is None:self.assertIsNone(predicted)
                else:self.assertAlmostEqual(predicted,case['runsOut'],places=3)

    def test_original_week_spend_and_missing_currency_semantics(self):
        now=1790001000
        events=[event(str(index),now-hour*3600) for index,hour in enumerate((200,100,2,1))]
        amounts=[Decimal('9'),Decimal('1.5'),Decimal('.25'),Decimal('.25')]
        price=lambda model,row,region,at:dict(currency='CNY',amount=amounts[int(row['id'])])
        value=period_metrics(events,'CNY','week',now,price=price)
        self.assertEqual(Decimal(value['cost']),2);self.assertEqual(value['span'],7*86400)
        self.assertAlmostEqual(float(value['per_day']),2/7,places=12)
        self.assertIsNone(period_metrics(events,'USD','week',now,price=price)['cost'])
        self.assertEqual(period_metrics([],'CNY','week',now)['cost'],'0')
        self.assertIsNone(period_metrics(None,'CNY','week',now))
        self.assertEqual(sum(Decimal(row['amount']) for row in value['columns']),2)

    def test_source_estimate_and_short_money_keep_small_values_and_rounding(self):
        self.assertEqual(money('.00001234','CNY',estimated=True),'¥0.000012')
        self.assertEqual(money('.0000001','USD',estimated=True),'<$0.000001')
        self.assertEqual(money('.009','USD',short=True),'$0.01')
        self.assertEqual(money('.004','USD',short=True),'<$0.01')
        self.assertEqual(money('-2','USD'),'-$2.00')

    def test_source_run_out_uses_read_time_and_failure_removes_level(self):
        now=1790001000
        account=dict(at=now-600,is_available=True,periods={'CNY':{'week':dict(cost='2',per_day='1',span=2*86400,tokens=10,tokens_per_hour=2)}})
        balance=dict(currency='CNY',balance=0)
        self.assertEqual(figures(account,balance,'burn','week',now)[1][1],'已耗尽')
        failed={**account,'error_code':'unavailable'}
        self.assertEqual(figures(failed,balance,'burn','week',now)[1][1],'—')
        self.assertEqual(figures(failed,balance,'quota','week',now)[0],('账户余额','¥0.00','text'))

    def test_worker_only_prices_observed_official_provider_and_keeps_foreign_accounts_out(self):
        now=1790001000
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'ledger.sqlite';ledger=UsageLedger(path)
            ledger.record('DeepSeek',[event('official',now-3600,billing_provider='deepseek-official',requested_at=now-3700),event('foreign',now-3000,account='other',billing_provider='deepseek-official')])
            reader=WindowMetrics(path);quota=dict(at=now,wallets=[dict(currency='CNY',balance=10),dict(currency='USD',balance=2)])
            result=reader('DeepSeek',quota,{},now)['api_billing'][0]
            self.assertIsNotNone(result['periods']['CNY']['day']['cost']);self.assertEqual(result['periods']['CNY']['day']['tokens'],1000000)
            self.assertIsNotNone(result['periods']['USD']['day']['cost'])
            ledger.record('DeepSeek',[event('unverified',now-2000)])
            result=reader('DeepSeek',quota,{},now+30)['api_billing'][0]
            self.assertIsNone(result['periods']['CNY']['day']['cost'])
            with patch('usage_ledger.time.time',return_value=now):self.assertEqual(ledger.report('DeepSeek')['event_count'],3)

    def test_parser_retains_only_provider_marker_and_request_start_for_peak_prices(self):
        parser=Transcript('DeepSeek','s');parser.feed(dict(type='session',version=4,id='s',createdAt=1000000),0)
        parser.feed(dict(type='request/context',seq=1,time=1000000,data=dict(model='deepseek-v4-flash',provider='deepseek-official')),1)
        parser.feed(dict(type='step/start',seq=2,time=1001000,data={}),2)
        parser.feed(dict(type='assistant/message',seq=3,time=1002000,data=dict(turn=1,step=1,usage=dict(inputTokens=1,outputTokens=1))),3)
        row=next(iter(parser.events.values()));self.assertEqual(row['billing_provider'],'deepseek-official');self.assertEqual(row['requested_at'],1001)
        with patch('billing_metrics.summed_cost',return_value={'currency':'CNY','amount':Decimal(1)}) as price:
            official_price(row['model'],row,'china',900);self.assertEqual(price.call_args.args[-1],1001)
        row['billing_provider']='https://custom.invalid/secret';self.assertIsNone(official_price(row['model'],row,'china',900))

    def test_unavailable_official_account_retains_a_negative_balance(self):
        from upstream_runtime import balance
        reply=dict(is_available=False,balance_infos=[dict(currency='CNY',total_balance='-1',granted_balance='0',topped_up_balance='0')])
        with tempfile.TemporaryDirectory() as folder,patch('upstream_runtime.run',return_value=json.dumps(reply)),patch('upstream_runtime.Path.home',return_value=Path(folder)):
            value=balance(Path(folder));self.assertFalse(value['is_available']);self.assertEqual(value['wallets'][0]['balance'],-1)


if __name__=='__main__':unittest.main()
