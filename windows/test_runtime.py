import threading
import time
import unittest

from providers import PROBE_PIDS
from runtime import Monitor, classify_clients


class PresenceTests(unittest.TestCase):
    def test_closed_apps_and_our_probe_are_not_open_clients(self):
        processes=[dict(pid=1,name='Cursor.exe',exe='C:/Cursor/Cursor.exe',cmdline=[]),
                   dict(pid=2,name='codex.exe',exe='C:/OpenAI/Codex/codex.exe',cmdline=['codex.exe','app-server']),
                   dict(pid=3,name='ChatGPT.exe',exe='C:/ChatGPT/ChatGPT.exe',cmdline=[]),
                   dict(pid=4,name='codex.exe',exe='C:/codex.exe',cmdline=['codex.exe','exec-server','--remote'])]
        self.assertEqual(classify_clients(processes,set()),set())
        self.assertEqual(classify_clients(processes,{1}),{'Cursor'})
        PROBE_PIDS.add(2)
        try:self.assertEqual(classify_clients(processes,{2}),set())
        finally:PROBE_PIDS.discard(2)

    def test_actual_codex_desktop_and_cli(self):
        rows=[dict(pid=1,name='ChatGPT.exe',exe='C:/WindowsApps/OpenAI.Codex_1/app/ChatGPT.exe',cmdline=[]),
              dict(pid=2,name='codex.exe',exe='C:/codex.exe',cmdline=['codex.exe','exec','work'])]
        self.assertEqual(classify_clients(rows,{1}),{'Codex'})
        self.assertEqual(classify_clients(rows[1:],set()),{'Codex'})
        self.assertEqual(classify_clients(rows[:1],set()),set())

    def test_inactive_clients_are_not_read_or_queried(self):
        calls=[];opened=set()
        monitor=Monitor(lambda _:None,presence=lambda:opened.copy(),
                        local={c:lambda c=c:calls.append(c) or dict(sessions=[]) for c in ('Codex','Cursor')},
                        quota={c:lambda:dict(windows=[]) for c in ('Codex','Cursor')})
        self.assertEqual(monitor.poll_once(),{})
        self.assertEqual(calls,[])
        opened.add('Codex')
        self.assertEqual(set(monitor.poll_once()),{'Codex'})
        self.assertEqual(calls,['Codex'])
        opened.clear()
        self.assertEqual(monitor.poll_once(),{})
        self.assertNotIn('Cursor',calls)
        monitor.stop.set()

    def test_a_closed_clients_late_quota_cannot_reappear(self):
        opened={'Cursor'};started=threading.Event();release=threading.Event()
        def quota():
            started.set();release.wait(3);return dict(windows=[{'used':42}])
        monitor=Monitor(lambda _:None,presence=lambda:opened.copy(),
                        local={'Cursor':lambda:dict(sessions=[])},quota={'Cursor':quota})
        monitor.poll_once();self.assertTrue(started.wait(2))
        opened.clear();self.assertEqual(monitor.poll_once(),{})
        release.set()
        monitor.stop.set()
        deadline=time.monotonic()+2
        while monitor.busy and time.monotonic()<deadline:time.sleep(.01)
        self.assertFalse(monitor.busy)
        self.assertNotIn('Cursor',monitor.quotas)


if __name__=='__main__':unittest.main()
