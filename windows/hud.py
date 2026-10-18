"""Agent HUD Open: deliberately small Windows companion (Codex + Cursor)."""
import argparse
from datetime import datetime
import json
import logging
import os
from pathlib import Path
import queue
import threading
import time
import tkinter as tk
from tkinter import ttk

from providers import DATA, CodexLocal, codex_quota, cursor_quota, cursor_sessions

BG, CARD, TEXT, MUTED, ACCENT = '#10151f', '#1b2331', '#edf3fc', '#9dabc0', '#8cafff'
LABELS = {'running': 'Working', 'done': 'Completed', 'stopped': 'Stopped',
          'error': 'Error', 'unknown': 'Last seen'}


def compact(number):
    if number is None:
        return ''
    return f'{number / 1e6:.2f}M' if number >= 1e6 else (f'{number / 1000:.1f}K' if number >= 1000 else str(number))


class HUD:
    def __init__(self):
        DATA.mkdir(parents=True, exist_ok=True)
        self.root = tk.Tk()
        self.root.title('Agent HUD Open · Windows')
        self.root.configure(bg=BG)
        self.root.attributes('-topmost', True)
        self.root.geometry(f'460x570+{self.root.winfo_screenwidth()-490}+65')
        self.root.minsize(410, 270)
        self.results, self.stop = queue.Queue(), threading.Event()
        self.local, self.quota = {}, {}
        self.closed, self.expanded = False, True
        header = tk.Frame(self.root, bg=BG)
        header.pack(fill='x', padx=20, pady=(17, 10))
        tk.Label(header, text='AGENT HUD', font=('Segoe UI', 15, 'bold'), fg=TEXT, bg=BG).pack(side='left')
        tk.Label(header, text='WINDOWS', font=('Segoe UI', 8), fg=ACCENT, bg=BG).pack(side='left', padx=10)
        self.top = tk.BooleanVar(value=True)
        tk.Checkbutton(header, text='Pin', variable=self.top, command=lambda: self.root.attributes('-topmost', self.top.get()),
                       fg=MUTED, bg=BG, selectcolor=CARD, activebackground=BG, activeforeground=TEXT).pack(side='right')
        controls = tk.Frame(self.root, bg=BG)
        controls.pack(fill='x', padx=20, pady=(0, 10))
        self.status = tk.Label(controls, text='Connecting to local clients…', font=('Segoe UI', 9), fg=MUTED, bg=BG)
        self.status.pack(side='left')
        tk.Button(controls, text='Compact', command=self.toggle, bg=CARD, fg=TEXT, relief='flat').pack(side='right')
        self.body = tk.Frame(self.root, bg=BG)
        self.body.pack(fill='both', expand=True, padx=15)
        self.cards = {}
        for client, color in [('Codex', '#8db2ff'), ('Cursor', '#b7efb5')]:
            card = tk.Frame(self.body, bg=CARD, padx=14, pady=12)
            card.pack(fill='x', pady=(0, 10))
            title = tk.Frame(card, bg=CARD)
            title.pack(fill='x')
            tk.Label(title, text=client, font=('Segoe UI', 13, 'bold'), bg=CARD, fg=color).pack(side='left')
            badge = tk.Label(title, text='Connecting', bg=CARD, fg=MUTED, font=('Segoe UI', 9))
            badge.pack(side='right')
            quota = tk.Label(card, text='Reading quota…', bg=CARD, fg=MUTED, font=('Segoe UI', 9), anchor='w', justify='left', wraplength=390)
            quota.pack(fill='x', pady=(9, 3))
            bar = tk.Canvas(card, height=4, bg='#303c50', highlightthickness=0)
            bar.pack(fill='x', pady=(0, 6))
            sessions = tk.Label(card, text='Reading sessions…', bg=CARD, fg=TEXT, font=('Segoe UI', 9), anchor='nw', justify='left', wraplength=390)
            sessions.pack(fill='x')
            self.cards[client] = (badge, quota, bar, sessions, color)
        footer = tk.Frame(self.root, bg=BG)
        footer.pack(fill='x', padx=20, pady=(4, 13))
        tk.Label(footer, text='Local activity · account metadata only', fg=MUTED, bg=BG, font=('Segoe UI', 8)).pack(side='left')
        tk.Button(footer, text='Files', command=lambda: os.startfile(Path(__file__).parent), bg=CARD, fg=TEXT, relief='flat').pack(side='right')
        self.root.protocol('WM_DELETE_WINDOW', self.close)
        threading.Thread(target=self.poll_local, daemon=True).start()
        for client, reader in [('Codex', codex_quota), ('Cursor', cursor_quota)]:
            threading.Thread(target=self.poll_quota, args=(client, reader), daemon=True).start()
        self.root.after(250, self.update)

    def toggle(self):
        self.expanded = not self.expanded
        self.root.geometry('460x570' if self.expanded else '460x310')
        self.render()

    def poll_local(self):
        codex = CodexLocal()
        while not self.stop.is_set():
            for client, reader in [('Codex', codex.sessions), ('Cursor', cursor_sessions)]:
                try:
                    self.results.put(('local', client, reader()))
                except Exception:
                    self.results.put(('local', client, dict(connected=False, sessions=[], notice='Local records unavailable; retrying')))
            self.stop.wait(3)

    def poll_quota(self, client, reader):
        while not self.stop.is_set():
            try:
                self.results.put(('quota', client, reader()))
            except Exception as error:
                # Error classes, not HTTP bodies or auth-bearing URLs, go to logs.
                logging.warning('%s quota: %s', client, type(error).__name__)
                notice = str(error) if isinstance(error, RuntimeError) else 'Account query failed; retrying in 3 minutes'
                self.results.put(('quota', client, dict(windows=[], notice=notice, at=time.time())))
            self.stop.wait(180)

    def render(self):
        working = 0
        for client, (badge, quota, bar, sessions, color) in self.cards.items():
            local = self.local.get(client, {})
            items = local.get('sessions', [])
            active = sum(row['state'] == 'running' for row in items)
            working += active
            badge.configure(text=f'{active} working' if active else ('Connected' if local.get('connected') else 'Not connected'),
                            fg=color if active else MUTED)
            reading = self.quota.get(client, {})
            windows = reading.get('windows') or []
            lines = []
            for window in windows[:3]:
                remaining = max(0, min(100, 100 - float(window['used'])))
                reset = window.get('reset')
                suffix = ''
                if reset:
                    try:
                        when = datetime.fromtimestamp(reset) if isinstance(reset, (int, float)) else datetime.fromisoformat(reset.replace('Z', '+00:00')).astimezone()
                        suffix = ' · resets ' + when.strftime('%m/%d %H:%M')
                    except (ValueError, OSError):
                        pass
                lines.append(f'{window["label"]}  {remaining:.0f}% remaining{suffix}')
            quota.configure(text='\n'.join(lines) or reading.get('notice', 'Reading quota…'))
            bar.delete('all')
            if windows:
                ratio = max(0, min(1, (100-float(windows[0]['used'])) / 100))
                bar.create_rectangle(0, 0, max(1, bar.winfo_width()) * ratio, 4, fill=color, outline='')
            text = []
            if self.expanded:
                for row in items[:3]:
                    status = LABELS.get(row['state'], 'Last seen')
                    count = compact(row.get('tokens'))
                    text.append(f'{"●" if row["state"] == "running" else "·"} {row["title"][:48]}\n   {status}' + (f' · session {count} tokens' if count else ''))
            sessions.configure(text='\n\n'.join(text) if text else (local.get('notice', 'Waiting for local records') if self.expanded else ''))
        self.status.configure(text=f'{working} active · {time.strftime("%H:%M:%S")}')

    def update(self):
        while not self.results.empty():
            kind, client, data = self.results.get_nowait()
            (self.local if kind == 'local' else self.quota)[client] = data
        self.render()
        self.root.after(1000, self.update)

    def close(self):
        self.stop.set()
        self.root.destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', action='store_true', help='Read local connection status without opening a window')
    args = parser.parse_args()
    if args.probe:
        result = {}
        for name, reader in [('Codex', CodexLocal().sessions), ('Cursor', cursor_sessions)]:
            try:
                data = reader()
                result[name] = dict(connected=data['connected'], sessions=len(data['sessions']),
                                    working=sum(x['state'] == 'running' for x in data['sessions']))
            except Exception as error:
                result[name] = dict(error=type(error).__name__)
        print(json.dumps(result))
        return
    DATA.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=DATA / 'hud.log', level=logging.WARNING)
    # One window per Windows logon session; the OS releases the mutex on exit.
    if os.name == 'nt':
        import ctypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
        kernel.CreateMutexW.restype = ctypes.c_void_p
        mutex = kernel.CreateMutexW(None, False, 'Local\\AgentHUDOpenWindows')
        if ctypes.get_last_error() == 183:
            return
    HUD().root.mainloop()


if __name__ == '__main__':
    main()
