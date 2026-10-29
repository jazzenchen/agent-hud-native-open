import tempfile,unittest
from pathlib import Path
from quota_insights import pace,outlook,QuotaHistory
from quota_events import QuotaEvents


class QuotaInsights(unittest.TestCase):
    def test_source_sampling_does_not_advance_without_provider_observations(self):
        samples=[(0,100),(300,99)]
        first=pace(samples,18000,18000,300);later=pace(samples,18000,18000,800)
        self.assertEqual(first,later);self.assertEqual(first['elapsed'],300);self.assertEqual(first['required'],900)
        result=pace([(0,100),(900,90),(1800,80)],18000,18000,1800)
        self.assertEqual(result['rate'],40)
        reset=pace([(0,100),(900,80),(1800,100)],18000,18000,1800)
        self.assertIsNone(reset['rate']);self.assertTrue(reset['after_reset']);self.assertEqual(reset['elapsed'],0)
        self.assertEqual(pace([(0,100),(900,90)],604800,604800,900)['required'],3600)

    def test_outlook_uses_real_pace_and_known_cycle_only(self):
        row=dict(used=50,reset=20000,duration=18000,insights=dict(rate=40))
        self.assertTrue(outlook(row,10000)['before_reset']);self.assertEqual(outlook(row,10000)['interval'],4500)
        self.assertEqual(outlook({**row,'duration':None},10000)['state'],'no_estimate')
        self.assertEqual(outlook({**row,'insights':dict(rate=0)},10000)['state'],'no_usage')
        self.assertEqual(outlook({**row,'used':100},10000)['state'],'exhausted')

    def test_history_is_account_scoped_persistent_and_never_invalidates_unknown_readings(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'quota.sqlite'
            def reading(at,used,account='a'):return dict(at=at,account=dict(id=account),windows=[dict(label='5h',used=used,reset=18000,duration=18000)])
            history=QuotaHistory(path)
            history.decorate('Codex',reading(1000,10),now=1000)
            result=QuotaHistory(path).decorate('Codex',reading(1900,20),now=1900)
            self.assertEqual(result['windows'][0]['insights']['rate'],40)
            other=history.decorate('Codex',reading(1900,20,'b'),now=1900)
            self.assertIsNone(other['windows'][0]['insights']['rate'])
            stale={**reading(1900,20),'stale':True}
            self.assertIs(history.decorate('Codex',stale,now=1900),stale)


class QuotaEventCases(unittest.TestCase):
    def reading(self,used,at,**extra):
        quota=dict(at=at,account=dict(id='a'),windows=[dict(label='5h',used=used,reset=20000,duration=18000)])
        quota.update(extra);return dict(Codex=dict(quota=quota))
    def test_initial_read_is_silent_then_warning_exhaustion_and_reset_are_distinct(self):
        tracker=QuotaEvents();self.assertFalse(tracker.update(self.reading(80,10000),now=10000))
        warning=tracker.update(self.reading(90,10001),now=10001);self.assertEqual(warning[0]['event'],'exhaustion')
        self.assertFalse(tracker.update(self.reading(95,10002),now=10002))
        self.assertEqual(tracker.update(self.reading(100,10003),now=10003)[0]['summary'],'已耗尽')
        self.assertEqual(tracker.update(self.reading(0,10004),now=10004)[0]['event'],'reset')
    def test_failed_future_old_unknown_and_returning_accounts_do_not_create_fake_resets(self):
        tracker=QuotaEvents();tracker.update(self.reading(90,10000),now=10000)
        self.assertFalse(tracker.update(self.reading(0,10001,stale=True),now=10001))
        self.assertFalse(tracker.update(self.reading(0,11000),now=10001))
        self.assertFalse(tracker.update(self.reading(0,9999),now=10001))
        tracker.update(self.reading(None,10002),now=10002)
        self.assertFalse(tracker.update(self.reading(0,10003),now=10003))
        tracker.update({},now=10004)
        self.assertFalse(tracker.update(self.reading(0,10005),now=10005))
    def test_forecast_warns_once_per_cycle_and_actual_exhaustion_is_a_new_event(self):
        tracker=QuotaEvents();tracker.update(self.reading(40,10000),now=10000)
        sample=self.reading(50,10001);sample['Codex']['quota']['windows'][0]['insights']=dict(rate=40)
        self.assertEqual(tracker.update(sample,now=10001)[0]['time_to_exhaust'],4500)
        tracker.update(self.reading(55,10002),now=10002)
        sample=self.reading(60,10003);sample['Codex']['quota']['windows'][0]['insights']=dict(rate=40)
        self.assertFalse(tracker.update(sample,now=10003))
        # The source tracks the critical crossing separately, but does not
        # repeat island news while the prior forecast already made it at risk.
        self.assertFalse(tracker.update(self.reading(90,10004),now=10004))
        self.assertEqual(tracker.update(self.reading(100,10005),now=10005)[0]['summary'],'已耗尽')
    def test_reset_credit_first_baseline_and_count_only_readings_keep_prior_ids(self):
        tracker=QuotaEvents()
        def snapshot(at,count,listed=None):
            return self.reading(10,at,reset_credits=dict(availableCount=count,credits=listed))
        self.assertFalse(tracker.update(snapshot(10000,1,[dict(id='old')]),now=10000))
        self.assertFalse(tracker.update(snapshot(10001,1),now=10001))
        result=tracker.update(snapshot(10002,2,[dict(id='old'),dict(id='new',expiresAt=20000)]),now=10002)
        self.assertEqual(result[0]['kind'],'reset_credits');self.assertEqual(result[0]['added'],1)
        self.assertEqual(result[0]['new_credits'][0]['id'],'new')
        self.assertFalse(tracker.update(snapshot(10003,0,[]),now=10003))


if __name__=='__main__':unittest.main()
