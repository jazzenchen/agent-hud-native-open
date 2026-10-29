import json,tempfile,time,unittest
from pathlib import Path
from open_plan_quota import service,discover,parse,fetch,Credential


class PlanQuotaCases(unittest.TestCase):
    def test_endpoint_override_prevents_proxy_key_leak(self):
        for base in ('http://api.kimi.com/coding/v1','https://proxy.example/coding/v1','https://api.kimi.com/coding/v1?key=x','https://user@api.kimi.com/coding/v1','https://api.kimi.com:444/coding/v1','https://api.kimi.com/v1'):
            self.assertIsNone(service('kimi-for-coding',base))
        self.assertEqual(service('kimi-for-coding','https://api.kimi.ai/coding/v1'),'kimiGlobal')
    def test_expired_oauth_and_custom_config_do_not_fall_back_to_official(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);root=home/'.local/share/opencode';root.mkdir(parents=True)
            (root/'auth.json').write_text(json.dumps({'kimi-for-coding':{'type':'api','key':'PRIVATE'}}))
            config=home/'.config/opencode';config.mkdir(parents=True)
            (config/'opencode.json').write_text(json.dumps({'provider':{'kimi-for-coding':{'options':{'baseURL':'https://proxy.example/v1'}}}}))
            creds=discover(home,dict(KIMI_CODE_API_KEY='PRIVATE',KIMI_CODE_BASE_URL='https://proxy.example/v1'))
            self.assertEqual(creds,[])
            (config/'opencode.json').write_text('invalid jsonc')
            self.assertEqual(discover(home,{}),[])
    def test_go_percent_is_already_percent_and_kimi_ratio_is_fraction(self):
        self.assertEqual(parse({'usage':{'rolling':{'percent':.5}}},'go')['windows'][0]['used'],.5)
        self.assertEqual(parse({'usages':{'limit_5h':{'used_ratio':.5}}},'kimi')['windows'][0]['used'],50)
        with self.assertRaises(ValueError):parse({'usage':{'rolling':{'percent':float('nan')}}},'go')
    def test_glm_credits_remaining_and_tokens_remain_distinct(self):
        limits=[dict(type=kind,unit=3,number=5,percentage=10,usage=100,remaining=60,currentValue=30) for kind in ('TOKENS_LIMIT','CREDIT_LIMIT')]
        data=parse(dict(success=True,code=200,data=dict(limits=limits)),'glmChina')
        self.assertEqual([w['used'] for w in data['windows']],[40,40]);self.assertEqual(len({w['label'] for w in data['windows']}),2)
    def test_two_keys_merge_only_when_provider_me_confirms_account(self):
        creds=[Credential('kimi','PRIVATE_A',{'Kimi'}),Credential('kimi','PRIVATE_B',{'Kimi'})]
        def http(url,token):
            return dict(user_id='same',region='cn') if url.endswith('/me') else dict(usages=dict(limit_5h=dict(used_ratio=.1)))
        data=fetch('Kimi',creds,http);self.assertEqual(len(data['windows']),1);self.assertEqual(len(data['accounts']),1);self.assertEqual(data['account']['evidence'],'account')
        def unidentified(url,token):
            if url.endswith('/me'):raise TimeoutError()
            return dict(usages=dict(limit_5h=dict(used_ratio=.1)))
        data=fetch('Kimi',creds,unidentified);self.assertEqual(len(data['accounts']),2);self.assertIsNone(data['account']);self.assertNotIn('PRIVATE',repr(data));self.assertNotIn('PRIVATE',repr(creds))
    def test_workbuddy_plan_is_not_sent_to_kimi_or_untrusted_url(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);(home/'.workbuddy').mkdir()
            (home/'.workbuddy/models.json').write_text(json.dumps([dict(vendor='GLM Coding Plan',url='https://open.bigmodel.cn/api/coding/paas/v4',apiKey='PRIVATE'),dict(vendor='GLM Coding Plan',url='https://api.kimi.com/coding/v1',apiKey='PRIVATE_KIMI')]))
            creds=discover(home,{});self.assertEqual(len(creds),1);self.assertEqual(creds[0].group,'WorkBuddy')


if __name__=='__main__':unittest.main()
