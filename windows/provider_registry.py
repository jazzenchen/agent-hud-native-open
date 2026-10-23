"""Capabilities are explicit: discovery alone never enables a provider adapter."""
import os,json,queue,shutil,subprocess,threading,time
from pathlib import Path
from providers import DATA,HIDDEN,PROBE_PIDS,codex_quota,CodexLocal
from local_sources import LocalSource
from cursor_usage import CursorSource
from usage_ledger import UsageLedger
from session_formats import stamp,digest

LOCAL_VENDORS=('Claude','Codex','CodeBuddy','WorkBuddy','OpenClaw','Pi','Qwen','Kimi','OpenCode','Hermes','ZCode','Devin','DeepSeek','Antigravity','Grok','GitHub Copilot')
QUOTA_VENDORS={'Codex','Cursor','Claude','Kimi','OpenCode','GLM','WorkBuddy','DeepSeek','Antigravity','Grok','GitHub Copilot'}


def merge_codex_metadata(row,metadata,now=None):
    now=time.time() if now is None else now
    # A bounded tail can miss task_started in a long active turn. Its lack of a
    # marker must not erase stronger lifecycle evidence from the full reader.
    state=metadata.get('state')
    if state!='unknown' or row.get('state') not in ('running','done','stopped','error') or now-metadata.get('updated',0)>1800:
        if state is not None:row['state']=state
    row.update({key:metadata[key] for key in ('title','cwd','updated') if key in metadata})
    if row.get('state')!='running':row['activity']=None
    return row


def claude_quota(timeout=25):
    def profile_identity():
        try:
            profile=json.loads((Path.home()/'.claude.json').read_text(encoding='utf-8')).get('oauthAccount') or {}
            if profile.get('accountUuid'):
                return dict(id=digest('Claude',profile['accountUuid'],profile.get('organizationUuid') or ''),label=profile.get('emailAddress') or 'Claude 账户',evidence='profile')
        except (OSError,ValueError):pass
        return None
    before=profile_identity()
    engine=shutil.which('claude.exe') or shutil.which('claude')
    if not engine or Path(engine).suffix.lower() not in ('.exe',''):raise RuntimeError('Claude engine unavailable')
    directory=DATA/'engine';directory.mkdir(parents=True,exist_ok=True)
    proc=subprocess.Popen([engine,'-p','--input-format','stream-json','--output-format','stream-json','--verbose','--settings','{"disableAllHooks":true}'],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',creationflags=HIDDEN,cwd=directory)
    PROBE_PIDS.add(proc.pid);messages=queue.Queue()
    def read():
        for line in proc.stdout:
            try:messages.put(json.loads(line))
            except ValueError:pass
        messages.put(None)
    threading.Thread(target=read,daemon=True).start()
    try:
        proc.stdin.write(json.dumps(dict(type='control_request',request_id='agent-hud-usage',request=dict(subtype='get_usage',skip_behaviors=True)))+'\n');proc.stdin.flush()
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            try:row=messages.get(timeout=max(.1,deadline-time.monotonic()))
            except queue.Empty:break
            if row is None:break
            if row.get('type')!='control_response':continue
            envelope=row.get('response') or {}
            if envelope.get('subtype')=='error':raise ValueError('Claude usage control failed')
            payload=envelope.get('response') or {};limits=payload.get('rate_limits') or {};windows=[]
            if payload.get('rate_limits_available'):
                for slot,label in [('five_hour','5-hour'),('seven_day','Weekly'),('seven_day_sonnet','Sonnet Weekly'),('seven_day_opus','Opus Weekly')]:
                    value=limits.get(slot) or {};used=value.get('utilization')
                    if isinstance(used,(int,float)) and 0<=used<=100:windows.append(dict(label=label,used=used,reset=stamp(value.get('resets_at')),duration=18000 if slot=='five_hour' else 604800))
            # Original profile identity is scoped by UUID and organization, never by a cached email alone.
            after=profile_identity()
            if before!=after:raise ValueError('Claude account changed during read')
            account=after if payload.get('rate_limits_available') else None
            return dict(windows=windows,plan=payload.get('subscription_type'),account=account,at=time.time(),notice='订阅额度已读取' if windows else '当前登录方式未提供订阅额度')
        raise TimeoutError('Claude usage timeout')
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:proc.wait(timeout=3)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        proc.stdin.close();proc.stdout.close();PROBE_PIDS.discard(proc.pid)


def defaults(copilot_consent=lambda:False):
    ledger=UsageLedger(DATA/'usage-ledger.sqlite');sources={name:LocalSource(name,ledger=ledger) for name in LOCAL_VENDORS}
    cursor=CursorSource(ledger)
    local={name:source.sessions for name,source in sources.items()};local['Cursor']=cursor.sessions
    codex_titles=CodexLocal()
    def codex_sessions():
        result=sources['Codex'].sessions()
        try:
            recent={row['id']:row for row in codex_titles.sessions()['sessions']}
            for row in result['sessions']:
                if row['id'] in recent:
                    merge_codex_metadata(row,recent.pop(row['id']))
            result['sessions'].extend(recent.values())
            result['sessions'].sort(key=lambda row:(row.get('state')!='running',-row.get('updated',0)))
        except Exception:pass
        return result
    local['Codex']=codex_sessions
    def no_quota():return dict(windows=[],notice='原版此接入读取本地会话和 Token，未提供订阅额度接口',at=time.time(),not_provided=True)
    def pending_quota():return dict(windows=[],notice='本地 Token 已接入；此提供商的账户额度适配尚未完成',at=time.time(),not_provided=True)
    quota={name:no_quota if name in ('OpenClaw','Hermes','ZCode','CodeBuddy','WorkBuddy','Qwen') else pending_quota for name in LOCAL_VENDORS}
    quota.update(Codex=codex_quota,Cursor=cursor.quota,Claude=claude_quota)
    from open_plan_quota import fetch,discover
    quota.update(Kimi=lambda:fetch('Kimi'),GLM=lambda:fetch('GLM'))
    def go_quota():
        credentials=discover()
        return fetch('OpenCode',credentials) if any(c.group=='OpenCode' for c in credentials) else pending_quota()
    def work_quota():
        from workbuddy_quota import fetch as workbuddy_account
        official=workbuddy_account()
        credentials=discover()
        if any(c.group=='WorkBuddy' for c in credentials):
            try:
                external=fetch('WorkBuddy',credentials)
                official['windows']+=external.get('windows',[])
                official['accounts']+=external.get('accounts') or ([external['account']] if external.get('account') else [])
            except Exception:pass  # Third-party plan failure cannot erase the official account balance.
        return official
    quota.update(OpenCode=go_quota,WorkBuddy=work_quota)
    from remaining_quota import copilot_quota,grok_quota,antigravity_quota
    from upstream_runtime import balance
    quota.update({'DeepSeek':lambda:balance(Path(os.environ.get('DSH_HOME') or Path.home()/'.dsh').expanduser()),'Grok':grok_quota,'Antigravity':antigravity_quota,'GitHub Copilot':lambda:copilot_quota(enabled=copilot_consent())})
    local['GLM']=lambda:dict(sessions=[],notice='计划额度；Token 用量由实际调用的客户端记录')
    return local,quota
