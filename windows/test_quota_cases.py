import errno
import threading
import unittest
import urllib.error
from unittest.mock import patch
from runtime import Monitor
from providers import parse_codex_quota
from quota_state import failure_code,quota_notice


class QuotaCases(unittest.TestCase):
    def monitor(self,reader):
        monitor=Monitor(lambda _:None,presence=lambda:{'Codex'},local={'Codex':lambda:dict(sessions=[])},quota={'Codex':reader})
        monitor.open={'Codex'}
        self.addCleanup(monitor.stop.set)
        return monitor

    def test_network_failure_keeps_last_success_marks_stale_and_recovery_clears_error(self):
        reader=unittest.mock.Mock(side_effect=TimeoutError())
        monitor=self.monitor(reader);previous=dict(windows=[dict(label='Weekly',used=49)],at=100.)
        monitor.quotas['Codex']=previous
        monitor.query('Codex',0)
        data=monitor.quotas['Codex']
        self.assertEqual(data['windows'],previous['windows']);self.assertEqual(data['at'],100.)
        self.assertTrue(data['stale']);self.assertEqual(data['error_code'],'timeout');self.assertEqual(data['retry_seconds'],15)
        self.assertIn('上次读数',quota_notice(data))
        reader.side_effect=None;reader.return_value=dict(windows=[dict(label='Weekly',used=51)],at=200.)
        monitor.query('Codex',0);data=monitor.quotas['Codex']
        self.assertFalse(data['stale']);self.assertNotIn('error_code',data);self.assertEqual(data['windows'][0]['used'],51)
        self.assertNotIn('Codex',monitor.failures)

    def test_first_failure_does_not_fabricate_zero_and_private_text_is_not_stored(self):
        def fail():raise ValueError('PRIVATE_ACCOUNT_TOKEN')
        monitor=self.monitor(fail);monitor.query('Codex',0)
        self.assertEqual(monitor.quotas['Codex']['windows'],[])
        self.assertNotIn('PRIVATE',str(monitor.quotas));self.assertNotIn('0%',quota_notice(monitor.quotas['Codex']))

    def test_retries_back_off_instead_of_waiting_three_minutes_after_first_failure(self):
        def fail():raise TimeoutError()
        monitor=self.monitor(fail)
        for expected in (15,30,60,120,180,180):
            monitor.query('Codex',0);self.assertEqual(monitor.retry_after['Codex'],expected)

    def test_failure_categories_are_specific_and_safe(self):
        cases=[(OSError(errno.ENOSPC,'private path'),'disk_full'),
               (urllib.error.URLError('private proxy'),'network'),
               (urllib.error.HTTPError('private-url',401,'token',None,None),'auth'),
               (urllib.error.HTTPError('private-url',429,'token',None,None),'throttled'),
               (RuntimeError('Cursor login expired'),'auth')]
        for error,expected in cases:
            with self.subTest(expected=expected):self.assertEqual(failure_code(error),expected)

    def test_authoritative_empty_multibucket_and_zero_is_real_but_null_is_not(self):
        snapshot=dict(rateLimitsByLimitId={},rateLimits=dict(primary=dict(usedPercent=0,windowDurationMins=300),secondary=dict(usedPercent=None)))
        data=parse_codex_quota(snapshot)
        self.assertEqual(data['windows'],[])  # CodexRateLimits.buckets: present empty map is authoritative.
        del snapshot['rateLimitsByLimitId']
        self.assertEqual(parse_codex_quota(snapshot)['windows'],[dict(label='5-hour',used=0.,reset=None)])
        snapshot['rateLimitsByLimitId']={'bad':None,'codex':dict(primary=dict(usedPercent=float('nan')))}
        self.assertEqual(parse_codex_quota(snapshot)['windows'],[])

    def test_closed_client_failure_cannot_resurrect_cached_usage(self):
        def fail():raise TimeoutError()
        monitor=self.monitor(fail);monitor.epochs['Codex']=1
        monitor.query('Codex',0)
        self.assertEqual(monitor.quotas,{});self.assertEqual(monitor.failures,{})

    def test_no_percentage_is_distinct_from_loading_or_failure(self):
        self.assertIn('正在读取',quota_notice({}))
        self.assertIn('未提供',quota_notice(dict(windows=[],at=100.)))


if __name__=='__main__':unittest.main()
