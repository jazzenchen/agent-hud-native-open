"""Reversible Claude-style permission/stop hooks, preserving every foreign hook."""
from copy import deepcopy
from datetime import datetime
import json,os,shutil,subprocess,sys
from pathlib import Path

SCRIPT=Path(__file__).with_name('attention_hook.py').resolve()


def hook_python(executable=None):
    executable=Path(sys.executable if executable is None else executable)
    if executable.name.casefold()=='pythonw.exe':
        candidate=executable.with_name('python.exe')
        if not candidate.is_file():raise FileNotFoundError('Console Python is required for client callbacks')
        return str(candidate)
    return str(executable)


def owns(command):
    if not isinstance(command,str):return False
    try:
        if os.name=='nt':
            import ctypes
            from ctypes import wintypes
            shell=ctypes.WinDLL('shell32',use_last_error=True);kernel=ctypes.WinDLL('kernel32',use_last_error=True)
            shell.CommandLineToArgvW.argtypes=[wintypes.LPCWSTR,ctypes.POINTER(ctypes.c_int)]
            shell.CommandLineToArgvW.restype=ctypes.POINTER(wintypes.LPWSTR)
            kernel.LocalFree.argtypes=[ctypes.c_void_p];kernel.LocalFree.restype=ctypes.c_void_p
            count=ctypes.c_int();pointer=shell.CommandLineToArgvW(command,ctypes.byref(count))
            if not pointer:return False
            try:arguments=[pointer[i] for i in range(count.value)]
            finally:kernel.LocalFree(pointer)
        else:
            import shlex
            arguments=shlex.split(command)
        if len(arguments)<4 or Path(arguments[0]).name.casefold() not in ('python','python.exe','pythonw.exe'):return False
        if arguments[2] not in ('permission','completion'):return False
        if arguments[3] not in ('claude','codex','workbuddy','codebuddy','qwen','zcode','devin'):return False
        path=arguments[1].replace('\\','/').casefold()
        return path==str(SCRIPT).replace('\\','/').casefold() or path.endswith('/agent-hud-open/windows/attention_hook.py')
    except (ValueError,OSError):return False


def merge(configuration,source,remove=False):
    if not isinstance(configuration,dict):raise ValueError('Unrecognized client settings')
    result=deepcopy(configuration);hooks=result.setdefault('hooks',{})
    if not isinstance(hooks,dict):raise ValueError('Unrecognized hooks layout')
    if source=='zcode':
        hooks=hooks.setdefault('events',{})
        if not isinstance(hooks,dict):raise ValueError('Unrecognized ZCode events layout')
    # Codex completions come from its authoritative turn records, not a guessed
    # stop callback. Cursor uses its separate upstream event/schema.
    events={'PermissionRequest':'permission'}
    if source in ('claude','workbuddy','codebuddy','qwen','devin'):events['Stop']='completion'
    for event,kind in events.items():
        groups=hooks.get(event,[])
        if not isinstance(groups,list):raise ValueError('Unrecognized hook event layout')
        retained=[]
        for group in groups:
            if not isinstance(group,dict) or not isinstance(group.get('hooks'),list):raise ValueError('Unrecognized hook group')
            if any(not isinstance(handler,dict) for handler in group['hooks']):raise ValueError('Unrecognized hook handler')
            handlers=[handler for handler in group['hooks'] if not owns(handler.get('command'))]
            if handlers:retained.append({**group,'hooks':handlers})
        if not remove:
            timeout=86400 if kind=='permission' else 10 if source=='devin' else 5
            if source=='qwen':timeout*=1000
            handler=dict(type='command',command=subprocess.list2cmdline([hook_python(),str(SCRIPT),kind,source]),timeout=timeout)
            group=dict(hooks=[handler])
            if kind=='permission' and source!='zcode':group['matcher']=''
            retained.append(group)
        if retained:hooks[event]=retained
        else:hooks.pop(event,None)
    return result


def locations(home=None,environment=None):
    home=Path.home() if home is None else Path(home)
    env=os.environ if environment is None else environment
    buddy=Path(env.get('CODEBUDDY_CONFIG_DIR') or home/'.codebuddy')
    if buddy.resolve()==(home/'.workbuddy').resolve():buddy=home/'.codebuddy'
    return dict(claude=Path(env.get('CLAUDE_CONFIG_DIR') or home/'.claude')/'settings.json',
                codex=Path(env.get('CODEX_HOME') or home/'.codex')/'hooks.json',
                workbuddy=home/'.workbuddy/settings.json',codebuddy=buddy/'settings.json',
                qwen=Path(env.get('QWEN_HOME') or home/'.qwen')/'settings.json',zcode=home/'.zcode/cli/config.json',
                devin=home/'.config/devin/config.json')


def configure_all(remove=False,home=None,environment=None):
    plans=[]
    for source,path in locations(home,environment).items():
        # A config root alone is enough for Codex/Claude; WorkBuddy and CodeBuddy
        # keep desktop/CLI session homes under projects, as upstream detects.
        if source=='devin':
            base=Path.home() if home is None else Path(home)
            if not (base/'.local/share/devin/cli/sessions.db').exists():continue
        elif not path.parent.exists():continue
        if source in ('workbuddy','codebuddy') and not (path.parent/'projects').exists():continue
        before=path.read_bytes() if path.exists() else None
        configuration=json.loads(before.decode('utf-8-sig')) if before is not None else {}
        if remove and before is None:continue
        updated=merge(configuration,source,remove)
        if updated==configuration:continue
        after=(json.dumps(updated,indent=2,ensure_ascii=False)+'\n').encode()
        plans.append((path,before,after))
    written=[]
    try:
        for path,before,after in plans:
            path.parent.mkdir(parents=True,exist_ok=True)
            if before is not None:shutil.copy2(path,path.with_name(path.name+'.agent-hud-backup-'+datetime.now().strftime('%Y%m%d-%H%M%S-%f')))
            temporary=path.with_name(path.name+'.agent-hud.tmp');temporary.write_bytes(after);temporary.replace(path)
            written.append((path,before))
    except OSError:
        for path,before in reversed(written):
            if before is None:path.unlink(missing_ok=True)
            else:
                temporary=path.with_name(path.name+'.agent-hud-restore.tmp');temporary.write_bytes(before);temporary.replace(path)
        raise
    return [str(path) for path,_,_ in plans]


if __name__=='__main__':configure_all(remove='--remove' in sys.argv)
