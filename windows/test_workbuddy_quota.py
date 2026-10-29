import json,tempfile,time,unittest
from pathlib import Path
from quota_state import QuotaError
from workbuddy_quota import fetch,parse,ENDPOINT

ACCOUNT=dict(uid='test-user',nickname='Sample account')
SUMMARY=dict(code=0,data=dict(SubscriptionPackageCode='proMon',SubscriptionPackageName='标准版',IsPaidUser=True,
    Packages=[dict(PackageCode='plan',CycleTotalCapacity='5000',CycleRemainCapacity='1000.25',CycleUsedCapacity='3999.75'),
              dict(PackageCode='addon',CycleTotalCapacity='10000',CycleRemainCapacity='7000',CycleUsedCapacity='3000')]))


class WorkBuddyQuota(unittest.TestCase):
    def fixture(self,directory):
        home=Path(directory);path=home/'AppData/Local/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info'
        path.parent.mkdir(parents=True)
        value=dict(account=ACCOUNT.copy(),auth=dict(accessToken='fixture-not-a-real-token',domain='www.workbuddy.cn',expiresAt=(time.time()+3600)*1000))
        path.write_text(json.dumps(value));return home,path,value

    def test_official_subscription_and_remaining_summary_are_separate_from_spent_credits(self):
        row=parse(SUMMARY,ACCOUNT,now=123)
        self.assertEqual(row['plan'],'标准版');self.assertEqual(row['credit_balance']['remaining'],8000.25)
        self.assertEqual(row['credit_balance']['total'],15000);self.assertEqual(row['credit_balance']['used'],6999.75)
        self.assertNotIn('fixture-not-a-real-token',json.dumps(row))
        self.assertEqual(row['windows'][0]['remaining'],8000.25)
        from usage_display import visible_quota
        hidden=visible_quota(row,'WorkBuddy',dict(hidden_accounts=[row['account']['id']]))
        self.assertIsNone(hidden['credit_balance']);self.assertFalse(hidden['windows'])
        self.assertEqual(row['credit_balance']['remaining'],8000.25)

    def test_fixed_official_gateway_required_headers_and_no_session_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            home,path,_=self.fixture(directory);before=path.read_bytes();calls=[]
            def request(url,headers,body):
                calls.append(url);self.assertEqual(url,ENDPOINT);self.assertEqual(body,{})
                self.assertEqual(headers['X-Product'],'SaaS');self.assertEqual(headers['X-User-Id'],'test-user')
                self.assertEqual(headers['X-Domain'],'www.workbuddy.cn');return SUMMARY
            self.assertEqual(fetch(home,request)['plan'],'标准版')
            self.assertEqual(calls,[ENDPOINT]);self.assertEqual(path.read_bytes(),before)
            path.with_suffix(path.suffix+'.logged-out').touch()
            with self.assertRaises(QuotaError):fetch(home,lambda *args:self.fail('Logged-out session must stay unused'))

    def test_account_switch_expired_credentials_and_corrupt_counts_cannot_show_false_balance(self):
        with tempfile.TemporaryDirectory() as directory:
            home,path,value=self.fixture(directory)
            def changed(*args):
                value['account']['uid']='different-user';path.write_text(json.dumps(value));return SUMMARY
            with self.assertRaises(QuotaError):fetch(home,changed)
            value['auth']['expiresAt']=0;path.write_text(json.dumps(value))
            with self.assertRaises(QuotaError):fetch(home,lambda *args:self.fail('Expired credentials must not be sent'))
            value['auth']['expiresAt']=(time.time()+3600)*1000;value['auth']['domain']='untrusted.example';path.write_text(json.dumps(value))
            with self.assertRaises(QuotaError):fetch(home,lambda *args:self.fail('Wrong identity scope'))
        for invalid in ('NaN',-1,True,None):
            response=json.loads(json.dumps(SUMMARY));response['data']['Packages'][0]['CycleRemainCapacity']=invalid
            with self.assertRaises(ValueError):parse(response,ACCOUNT)
        with self.assertRaises(QuotaError):parse(dict(code=10085,data={}),ACCOUNT)
        with self.assertRaises(ValueError):parse(dict(code=0,data={}),ACCOUNT)

    def test_enterprise_uses_its_own_account_scope_and_unlimited_is_not_zero_balance(self):
        from workbuddy_quota import ENTERPRISE_ENDPOINT,credit_text
        with tempfile.TemporaryDirectory() as directory:
            home,path,value=self.fixture(directory);value['account'].update(enterpriseId='team',type='exclusive');path.write_text(json.dumps(value))
            def request(url,headers,body):
                self.assertEqual(url,ENTERPRISE_ENDPOINT);self.assertEqual(headers['X-Enterprise-Id'],'team')
                self.assertEqual(headers['X-Tenant-Id'],'team');return dict(code=0,data=dict(limitNum=-1,credit=10))
            row=fetch(home,request);self.assertEqual(credit_text(row['credit_balance'],'remaining'),'不限额')
            self.assertFalse(row['windows']);self.assertNotEqual(row['account']['id'],parse(SUMMARY,ACCOUNT)['account']['id'])


if __name__=='__main__':unittest.main()
