import json
from pathlib import Path
import tempfile
import unittest
import os
import subprocess
import sys
import sqlite3
from cursor_hook import record
from install_hooks import configure
from providers import parse_codex, parse_cursor_quota, tail_records, read_db


class AdapterTests(unittest.TestCase):
    def event(self, kind, **kwargs):
        return dict(type='event_msg', payload=dict(type=kind, **kwargs))

    def test_explicit_codex_lifecycle(self):
        records = [self.event('task_started'), self.event('agent_message')]
        self.assertEqual(parse_codex(records)['state'], 'running')
        records.append(self.event('task_complete'))
        self.assertEqual(parse_codex(records)['state'], 'done')
        self.assertEqual(parse_codex([self.event('turn_aborted')])['state'], 'stopped')
        self.assertEqual(parse_codex([self.event('task_complete', error='limit')])['state'], 'error')

    def test_cumulative_tokens_are_not_summed(self):
        rows = [self.event('token_count', info={'total_token_usage': {'total_tokens': n}}) for n in (10, 25, 25)]
        self.assertEqual(parse_codex(rows)['tokens'], 25)

    def test_partial_line(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'rollout.jsonl'
            path.write_text(json.dumps(self.event('task_started')) + '\n{"type":', encoding='utf-8')
            self.assertEqual(len(tail_records(path)), 1)
            with path.open('a') as stream:
                stream.write('"event_msg","payload":{"type":"task_complete"}}\n')
            self.assertEqual(parse_codex(tail_records(path))['state'], 'done')

    def test_unavailable_quota_is_not_zero(self):
        self.assertEqual(parse_cursor_quota({'membershipType': 'pro'})['windows'], [])
        with self.assertRaises(ValueError):
            parse_cursor_quota({'error': 'bad response'})
        data = {'individualUsage': {'plan': {'used': 20, 'limit': 50}}}
        self.assertEqual(parse_cursor_quota(data)['windows'][0]['used'], 40)

    def test_observer_does_not_store_prompt(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            payload = dict(conversation_id='../../chat', prompt='PRIVATE', workspace_roots=['C:/project'])
            record('beforeSubmitPrompt', payload, directory)
            path = next(directory.glob('*.json'))
            self.assertNotIn('PRIVATE', path.read_text())
            self.assertEqual(json.loads(path.read_text())['state'], 'running')
            record('stop', {**payload, 'status': 'error'}, directory)
            self.assertEqual(json.loads(path.read_text())['state'], 'error')
            self.assertEqual(len(list(directory.glob('*.json'))), 1)

    def test_hook_install_is_idempotent_and_reversible(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'hooks.json'
            existing = {'version': 1, 'hooks': {'stop': [{'command': 'my-existing-hook'}]}}
            path.write_text(json.dumps(existing))
            configure(path)
            configure(path)
            hooks = json.loads(path.read_text())['hooks']
            self.assertEqual(len(hooks['stop']), 2)
            self.assertEqual(len(hooks['beforeSubmitPrompt']), 1)
            configure(path, remove=True)
            self.assertEqual(json.loads(path.read_text()), existing)
            self.assertTrue(list(path.parent.glob('hooks.json.agent-hud-backup-*')))

    def test_observer_process_fails_open_on_invalid_input(self):
        with tempfile.TemporaryDirectory() as folder:
            env = {**os.environ, 'LOCALAPPDATA': folder}
            process = subprocess.run([sys.executable, str(Path(__file__).with_name('cursor_hook.py')), 'beforeSubmitPrompt'],
                                     input='{bad json', text=True, capture_output=True, env=env, timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(json.loads(process.stdout), {'continue': True})
            self.assertFalse(list(Path(folder).rglob('*.json')))

    def test_readonly_sqlite_sees_committed_wal(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'client.sqlite'
            writer = sqlite3.connect(path)
            try:
                writer.execute('PRAGMA journal_mode=WAL')
                writer.execute('CREATE TABLE events (id INTEGER)')
                writer.execute('INSERT INTO events VALUES (1)')
                writer.commit()
                with read_db(path) as reader:
                    self.assertEqual(reader.execute('SELECT id FROM events').fetchone(), (1,))
                    with self.assertRaises(sqlite3.OperationalError):
                        reader.execute('INSERT INTO events VALUES (2)')
            finally:
                writer.close()


if __name__ == '__main__':
    unittest.main()
