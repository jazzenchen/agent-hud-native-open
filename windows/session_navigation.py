"""Exact supported Windows destinations; unsupported clients retain View usage."""
import os,re,shutil,subprocess
from pathlib import Path

SESSION=re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')


def claude_executable():
    for candidate in (shutil.which('claude.exe'),Path.home()/'.local/bin/claude.exe'):
        if candidate and Path(candidate).is_file():return str(candidate)
    return None


def codex_handler():
    if os.name!='nt':return False
    import winreg
    for root in (winreg.HKEY_CURRENT_USER,winreg.HKEY_CLASSES_ROOT):
        path=r'Software\Classes\codex' if root==winreg.HKEY_CURRENT_USER else 'codex'
        try:
            with winreg.OpenKey(root,path):return True
        except OSError:pass
    return False


def can_navigate(event):
    sid=event.get('session','')
    if not isinstance(sid,str) or SESSION.fullmatch(sid) is None:return False
    return bool(codex_handler()) if event.get('vendor')=='Codex' else bool(claude_executable()) if event.get('vendor')=='Claude' else False


def navigate(event):
    if not can_navigate(event):return False
    if event['vendor']=='Codex':
        from PySide6.QtCore import QUrl
        from PySide6.QtGui import QDesktopServices
        return QDesktopServices.openUrl(QUrl('codex://threads/'+event['session']))
    executable=claude_executable();sid=event['session'];cwd=event.get('cwd')
    if not isinstance(cwd,str) or not Path(cwd).is_dir() or cwd.startswith(('\\\\','//')):cwd=None
    terminal=shutil.which('wt.exe')
    try:
        if terminal:
            subprocess.Popen([terminal,'new-tab',*(['-d',cwd] if cwd else []),'--',executable,'--resume',sid])
        else:subprocess.Popen([executable,'--resume',sid],cwd=cwd,creationflags=getattr(subprocess,'CREATE_NEW_CONSOLE',0))
        return True
    except OSError:return False
