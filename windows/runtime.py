"""Running-client visibility and polling, independent of the presentation."""
import os
import threading
import time
from pathlib import Path

from providers import CodexLocal, PROBE_PIDS, codex_quota, cursor_quota, cursor_sessions
from quota_state import failure_code,notice
from agent_catalog import COMMANDS,SUPPORTED


def classify_clients(processes, visible_pids):
    """An installed database, background app-server or our own probe is not an open app."""
    found = set()
    for process in processes:
        if process.get('pid') in PROBE_PIDS:
            continue
        name = (process.get('name') or '').lower()
        exe = (process.get('exe') or '').lower().replace('\\', '/')
        args = [str(x).lower() for x in (process.get('cmdline') or [])]
        visible = process.get('pid') in visible_pids
        if name == 'cursor.exe' and visible:
            found.add('Cursor')
        elif name in ('chatgpt.exe', 'codex.exe') and visible and ('openai.codex' in exe or '/openai/codex/' in exe):
            found.add('Codex')
        elif name in ('codex.exe', 'codex') and not any(x in args for x in ('app-server', 'mcp-server', 'exec-server', 'daemon')):
            found.add('Codex')
        else:
            # Electron desktop clients require a visible window. Node CLIs must
            # match an executable/package segment, not arbitrary prompt text.
            desktop={'codebuddy.exe':'CodeBuddy','workbuddy.exe':'WorkBuddy','antigravity.exe':'Antigravity','opencode.exe':'OpenCode','claude.exe':'Claude'}
            if visible and name in desktop:found.add(desktop[name]);continue
            if name=='claude.exe' and any(marker in exe for marker in ('/.local/bin/','/claude-code/')):found.add('Claude');continue
            if any(x in args for x in ('app-server','mcp-server','daemon','gateway','serve','server')):continue
            for vendor,commands in COMMANDS.items():
                if vendor in ('Codex','Cursor') or vendor not in SUPPORTED:continue
                if name in tuple(command+'.exe' for command in commands)+tuple(commands) and name not in desktop:found.add(vendor)
                if name in ('node.exe','node','bun.exe','bun'):
                    script=next((arg.replace('\\','/') for arg in args[1:] if arg.endswith(('.js','.mjs','.cjs'))),'')
                    markers={'Claude':'@anthropic-ai/claude-code/','CodeBuddy':'@tencent-ai/codebuddy-code/','WorkBuddy':'@tencent-ai/workbuddy/','OpenClaw':'/openclaw/','Pi':'@mariozechner/pi-coding-agent/','Qwen':'@qwen-code/qwen-code/','Kimi':'/kimi-cli/','OpenCode':'/opencode-ai/'}
                    if markers.get(vendor,'\0') in script:found.add(vendor)
    if found & {'Claude','Pi','OpenCode','WorkBuddy'}:
        try:
            from open_plan_quota import discover
            if any(c.group=='GLM' and (c.clients & found or 'GLM' in c.clients) for c in discover()):found.add('GLM')
        except Exception:pass
    return found


def running_clients():
    import psutil
    visible = set()
    if os.name == 'nt':
        import ctypes
        from ctypes import wintypes
        user = ctypes.WinDLL('user32', use_last_error=True)
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        user.IsWindowVisible.argtypes = [wintypes.HWND]
        user.GetWindowTextLengthW.argtypes = [wintypes.HWND]
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]

        @callback_type
        def visit(handle, _):
            if user.IsWindowVisible(handle) and user.GetWindowTextLengthW(handle):
                pid = wintypes.DWORD()
                user.GetWindowThreadProcessId(handle, ctypes.byref(pid))
                visible.add(pid.value)
            return True

        user.EnumWindows(visit, 0)
    rows = []
    for process in psutil.process_iter(['pid', 'name', 'exe', 'cmdline']):
        try:
            rows.append(process.info)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return classify_clients(rows, visible)


class Monitor:
    """Never reads an inactive client's records or launches its quota engine."""
    def __init__(self, emit, presence=running_clients, local=None, quota=None):
        self.emit, self.presence = emit, presence
        if local is None:
            from provider_registry import defaults
            local,default_quota=defaults()
        else:default_quota={}
        self.readers = local
        self.quota_readers = quota if quota is not None else default_quota
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.open = set()
        self.enabled = set(self.readers)
        self.epochs = {name:0 for name in self.readers}
        self.quotas, self.last_query, self.busy = {}, {}, set()
        self.failures,self.retry_after={},{}

    def poll_once(self):
        opened = self.presence() & self.enabled & self.readers.keys()
        with self.lock:
            for client in self.open ^ opened:
                self.epochs[client] = self.epochs.get(client,0)+1
                self.quotas.pop(client, None)
                self.last_query.pop(client, None)
                self.failures.pop(client,None);self.retry_after.pop(client,None)
            self.open = opened
        snapshot = {}
        for client in self.readers:
            if client not in opened:
                continue
            try:
                local = self.readers[client]()
            except Exception:
                local = dict(sessions=[], notice='Local records unavailable')
            with self.lock:
                reading = self.quotas.get(client, dict(windows=[], notice='正在读取额度…'))
                epoch = self.epochs[client]
                key = (client, epoch)
                delay=self.retry_after.get(client,180)
                needs = client in self.quota_readers and time.monotonic() - self.last_query.get(client, -1000) > delay and key not in self.busy
                if needs:
                    self.busy.add(key)
                    self.last_query[client] = time.monotonic()
            snapshot[client] = dict(local=local, quota=reading)
            if needs:
                threading.Thread(target=self.query, args=(client, epoch), daemon=True).start()
        self.emit(snapshot)
        return snapshot

    def query(self, client, epoch):
        data=None;code=None
        try:
            # Closing after scheduling must not start the engine either.
            if self.stop.is_set() or client not in self.enabled or client not in self.presence():
                return
            data = self.quota_readers[client]()
            accounts=data.get('accounts') or ([data['account']] if data.get('account') else [])
            if accounts:
                try:
                    from providers import DATA
                    from usage_ledger import UsageLedger
                    UsageLedger(DATA/'usage-ledger.sqlite').record(client,[],accounts)
                except Exception:pass  # Disk pressure must not erase a valid live reading.
        except Exception as error:
            code=failure_code(error)
        finally:
            with self.lock:
                self.busy.discard((client, epoch))
                if client in self.open and self.epochs[client] == epoch and not self.stop.is_set() and (data is not None or code):
                    if code:
                        self.last_query[client]=time.monotonic()
                        count=self.failures.get(client,0)+1;self.failures[client]=count
                        self.retry_after[client]=120 if code=='auth' else min(180,15*2**min(count-1,4))
                        previous=self.quotas.get(client,{})
                        data={**previous,'windows':previous.get('windows',[]),'stale':bool(previous.get('windows')),
                              'notice':notice(code,client),'error_code':code,'failed_at':time.time(),
                              'retry_seconds':self.retry_after[client]}
                    else:
                        self.failures.pop(client,None);self.retry_after.pop(client,None)
                        data={**data,'stale':False}
                    self.quotas[client]=data

    def run(self):
        while not self.stop.is_set():
            try:
                self.poll_once()
            except Exception:
                pass
            self.stop.wait(2)
