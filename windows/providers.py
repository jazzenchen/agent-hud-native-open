"""Small Windows adapters. Upstream Swift providers remain authoritative.

No conversations are submitted; credentials stay in memory. SQLite is read-only.
"""
from __future__ import annotations

import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import threading
import time
import urllib.request
from datetime import datetime
from quota_state import QuotaError

HOME = Path.home()
DATA = Path(os.environ.get('LOCALAPPDATA', HOME / '.local/share')) / 'AgentHUDOpen'
CODEX = Path(os.environ.get('CODEX_HOME', HOME / '.codex'))
CURSOR_DB = Path(os.environ.get('APPDATA', HOME / 'AppData/Roaming')) / 'Cursor/User/globalStorage/state.vscdb'
HIDDEN = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
PROBE_PIDS = set()


@contextmanager
def read_db(path):
    # mode=ro includes committed WAL records. Never use immutable on a live DB.
    conn = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)
    try:
        yield conn
    finally:
        conn.close()


def tail_records(path, size=1024 * 1024):
    with open(path, 'rb') as f:
        length = f.seek(0, 2)
        start = max(0, length - size)
        f.seek(start)
        if start:
            f.readline()
        lines = f.read().splitlines()
    records = []
    for line in lines:
        try:
            records.append(json.loads(line))
        except (ValueError, UnicodeError):
            pass  # An in-flight partial line is read again on the next pass.
    return records


def parse_codex(records):
    state, tokens, observed = 'unknown', None, None
    breakdown = None
    for row in records:
        payload = row.get('payload') or {}
        if row.get('type') != 'event_msg':
            continue
        kind = payload.get('type')
        if kind == 'task_started':
            state = 'running'
        elif kind in ('task_complete', 'task_completed'):
            state = 'error' if payload.get('error') else 'done'
        elif kind == 'turn_aborted':
            state = 'stopped'
        elif kind == 'token_count':
            total = (payload.get('info') or {}).get('total_token_usage')
            if total:
                tokens = total.get('total_tokens')
                breakdown = dict(input=max(0, total.get('input_tokens', 0) - total.get('cached_input_tokens', 0)),
                                 cache=total.get('cached_input_tokens', 0),
                                 output=max(0, total.get('output_tokens', 0) - total.get('reasoning_output_tokens', 0)),
                                 reasoning=total.get('reasoning_output_tokens', 0))
        observed = row.get('timestamp', observed)
    return dict(state=state, tokens=tokens, observed=observed, breakdown=breakdown)


class CodexLocal:
    def __init__(self, home=CODEX):
        self.home, self.cache = home, {}

    def sessions(self):
        db = self.home / 'state_5.sqlite'
        if not db.exists():
            return dict(connected=False, sessions=[], notice='No Codex session database found')
        with read_db(db) as conn:
            rows = conn.execute('SELECT id,title,cwd,rollout_path,updated_at FROM threads '
                                'WHERE archived=0 ORDER BY updated_at DESC LIMIT 12').fetchall()
        result = []
        for sid, title, cwd, rollout, updated in rows:
            path = Path(rollout)
            try:
                stat = path.stat()
                stamp = (stat.st_mtime_ns, stat.st_size)
                if self.cache.get(sid, (None,))[0] != stamp:
                    self.cache[sid] = (stamp, parse_codex(tail_records(path)))
                item = dict(self.cache[sid][1])
                age = time.time() - stat.st_mtime
                # An old running marker is not proof that an agent is still alive.
                if item['state'] == 'running' and age > 1800:
                    item['state'] = 'unknown'
                item.update(id=sid, title=(title or Path(cwd).name or sid).splitlines()[0][:65],
                            updated=stat.st_mtime, cwd=cwd)
                result.append(item)
            except OSError:
                continue
        result.sort(key=lambda x: (x['state'] != 'running', -x['updated']))
        active={row[0] for row in rows}
        self.cache={key:value for key,value in self.cache.items() if key in active}
        return dict(connected=True, sessions=result, notice='Local session records · refreshed every 3s')


def codex_executable():
    import shutil
    found = shutil.which('codex.exe')
    if found:
        return found
    root = Path(os.environ.get('LOCALAPPDATA', HOME / 'AppData/Local')) / 'OpenAI/Codex/bin'
    candidates = list(root.glob('*/codex.exe'))
    if candidates:
        return str(max(candidates, key=lambda p: p.stat().st_mtime))
    return None


def parse_codex_quota(result):
    import math
    buckets=result.get('rateLimitsByLimitId')
    if not isinstance(buckets,dict):
        bucket=result.get('rateLimits') or {}
        buckets={bucket.get('limitId') or 'codex':bucket}
    windows=[]
    for key,bucket in buckets.items():
        if not isinstance(bucket,dict):continue
        for slot in ('primary','secondary'):
            value=bucket.get(slot)
            if not isinstance(value,dict) or value.get('usedPercent') is None:continue
            try:used=float(value['usedPercent'])
            except (ValueError,TypeError):continue
            if not math.isfinite(used) or used<0:continue
            minutes=value.get('windowDurationMins')
            label='Weekly' if minutes==10080 else '5-hour' if minutes==300 else f'{minutes or "?"} min'
            duration=float(minutes)*60 if isinstance(minutes,(int,float)) and not isinstance(minutes,bool) and math.isfinite(minutes) and minutes>0 else None
            windows.append(dict(label=label if key=='codex' else f'{key} · {label}',used=used,reset=value.get('resetsAt'),duration=duration))
    account=result.get('account') or {}
    email=str(account.get('email') or '').strip()
    workspace=str(result.get('accountId') or '').strip()
    identity=None
    if email or workspace:
        from session_formats import digest
        identity=dict(id=digest('Codex',email.lower(),workspace),label=email or 'ChatGPT 工作区',evidence='account')
    plan=next((b.get('planType') for b in buckets.values() if isinstance(b,dict) and b.get('planType')),account.get('planType'))
    credits=result.get('rateLimitResetCredits')
    if not isinstance(credits,dict) or not isinstance(credits.get('availableCount'),int) or isinstance(credits['availableCount'],bool) or credits['availableCount']<0:credits=None
    return dict(windows=windows,account=identity,plan=plan,reset_credits=credits,notice='Live account limits' if windows else 'Account reports no quota percentage',at=time.time())


def codex_quota(executable=None, timeout=25):
    executable = executable or codex_executable()
    if not executable:
        raise RuntimeError('Codex engine not found; local sessions remain available')
    proc = subprocess.Popen([executable, 'app-server'], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            creationflags=HIDDEN, text=True, encoding='utf-8')
    PROBE_PIDS.add(proc.pid)
    messages = queue.Queue()

    def read():
        for line in proc.stdout:
            try:
                messages.put(json.loads(line))
            except ValueError:
                pass
        messages.put(None)

    threading.Thread(target=read, daemon=True).start()

    def send(data):
        proc.stdin.write(json.dumps(data) + '\n')
        proc.stdin.flush()

    try:
        send(dict(id=1, method='initialize', params=dict(clientInfo=dict(
            name='agent_hud_windows', title='Agent HUD Windows', version='0.1.0'))))
        deadline = time.monotonic() + timeout
        limits=None;account=None;account_done=False
        while time.monotonic() < deadline:
            try:
                message = messages.get(timeout=max(.1, deadline - time.monotonic()))
            except queue.Empty:
                break
            if message is None and limits is not None:break
            if message is None:
                raise RuntimeError('Codex quota engine exited')
            if message.get('error') and message.get('id')==3:
                account_done=True
                if limits is not None:break
                continue
            if message.get('error'):
                error=message['error'];detail=str(error.get('message','')).lower() if isinstance(error,dict) else ''
                code='auth' if any(word in detail for word in ('auth','sign in','login','401','403')) else 'throttled' if '429' in detail else 'network'
                raise QuotaError(code)
            if message.get('id') == 1:
                send(dict(method='initialized'))
                send(dict(id=2, method='account/rateLimits/read'))
                send(dict(id=3, method='account/read',params={}))
            elif message.get('id') == 2:
                limits=message.get('result') or {}
                if account_done:break
                deadline=min(deadline,time.monotonic()+2)
            elif message.get('id') == 3:
                account=(message.get('result') or {}).get('account');account_done=True
                if limits is not None:break
        if limits is not None:return parse_codex_quota({**limits,'account':account})
        raise RuntimeError('Codex quota query timed out')
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        proc.stdin.close()
        proc.stdout.close()
        PROBE_PIDS.discard(proc.pid)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def cursor_request(token, user, endpoint, body=None):
    # Exact provider host; no redirects carrying account credentials.
    request = urllib.request.Request('https://cursor.com/api/' + endpoint,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Cookie': f'WorkosCursorSessionToken={user}%3A%3A{token}',
                 'Origin': 'https://cursor.com', 'Content-Type': 'application/json'})
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=15) as response:
        return json.load(response)


def parse_cursor_quota(data):
    import math
    from session_formats import stamp
    if not any(k in data for k in ('individualUsage', 'teamUsage', 'membershipType')):
        raise ValueError('Cursor returned an unsupported usage response')
    plan = (data.get('individualUsage') or {}).get('plan') or {}
    rows = []
    used = plan.get('totalPercentUsed')
    def ratio(value):
        if value.get('enabled') is not False and isinstance(value.get('limit'),(int,float)) and value['limit']>0 and isinstance(value.get('used'),(int,float)):
            return value['used']/value['limit']*100
    if used is None:used=ratio(plan)
    individual=data.get('individualUsage') or {};team=data.get('teamUsage') or {}
    pools=[('Included',used if plan.get('enabled') is not False else None),('First-party',plan.get('autoPercentUsed')),('Third-party',plan.get('apiPercentUsed')),
           ('Spend limit',ratio(individual.get('overall') or {})),('Pooled',ratio(team.get('pooled') or {})),('On-demand',ratio(individual.get('onDemand') or {}))]
    start=stamp(data.get('billingCycleStart'));end=stamp(data.get('billingCycleEnd'))
    duration=end-start if start is not None and end is not None and end>start else None
    for label,value in pools:
        if isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value) and value>=0:
            rows.append(dict(label=label,used=value,reset=end,duration=duration))
    return dict(windows=rows, plan=data.get('membershipType'), at=time.time(),
                notice='Live account limits' if rows else 'Plan reports no quota percentage')


def cursor_auth(db=CURSOR_DB):
    if not db.exists():
        raise RuntimeError('Cursor is not installed or has not been opened')
    with read_db(db) as conn:
        row = conn.execute("SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'").fetchone()
        email=conn.execute("SELECT value FROM ItemTable WHERE key='cursorAuth/cachedEmail'").fetchone()
    if not row:
        raise RuntimeError('Sign in to Cursor to read quota')
    token = row[0]
    if isinstance(token, bytes):
        token = token.decode()
    if not isinstance(token,str) or len(token.split('.'))!=3 or any(c in token for c in '\r\n\0'):raise QuotaError('auth')
    try:
        part = token.split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
        if claims.get('exp', 0) < time.time() + 60:
            raise RuntimeError('Cursor login expired · sign in again in Cursor')
        user = claims['sub'].split('|')[-1]
        if not user or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in user):
            raise ValueError()
    except (ValueError, KeyError, IndexError):
        raise RuntimeError('Cursor sign-in format unavailable') from None
    return token,user,email[0] if email else None


def cursor_quota(db=CURSOR_DB):
    from session_formats import digest
    token,user,email=cursor_auth(db)
    result=parse_cursor_quota(cursor_request(token,user,'usage-summary'))
    _,after_user,_=cursor_auth(db)
    if after_user!=user:raise QuotaError('auth')
    result['account']=dict(id=digest('Cursor',user),label=email or 'Cursor 账户',evidence='account')
    return result


def cursor_sessions(data=DATA, db=CURSOR_DB):
    result = []
    event_dir = data / 'cursor-events'
    for path in sorted(event_dir.glob('*.json'), key=lambda p: p.stat().st_mtime, reverse=True)[:12]:
        try:
            row = json.loads(path.read_text(encoding='utf-8'))
            if row.get('state') == 'running' and time.time() - row['updated'] > 1800:
                row['state'] = 'unknown'
            result.append(row)
        except (OSError, ValueError, KeyError):
            continue
    known = {row['id'] for row in result}
    if db.exists():
        try:
            with read_db(db) as conn:
                rows = conn.execute("SELECT substr(key,14),json_extract(value,'$.name'),"
                    "json_extract(value,'$.createdAt') FROM cursorDiskKV "
                    "WHERE key LIKE 'composerData:%' AND json_valid(value) "
                    "ORDER BY json_extract(value,'$.createdAt') DESC LIMIT 5").fetchall()
            for sid, name, created in rows:
                if sid not in known:
                    result.append(dict(id=sid, title=(name or 'Cursor chat ' + sid[:8])[:65],
                                       state='unknown', updated=(created or 0) / 1000, tokens=None))
        except sqlite3.Error:
            pass
    result.sort(key=lambda row: (row.get('state') != 'running', -row.get('updated', 0)))
    return dict(connected=db.exists(), sessions=result, notice='Activity via Cursor hooks · new turns only')
