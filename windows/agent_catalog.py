"""The upstream source inventory, with passive Windows install/process detection."""
import os,re,shutil
from pathlib import Path
from source_design import CORE


def vendors():
    additional=(CORE/'Providers/Kit/ProviderData.swift').read_text(encoding='utf-8').split('public var detail:')[0]
    opened=(CORE/'Providers/OpenAgents/OpenAgentSessions.swift').read_text(encoding='utf-8').split('public var detail:')[0]
    return list(dict.fromkeys(['Claude','Codex','DeepSeek']+re.findall(r'case \.\w+: "([^"]+)"',additional)+re.findall(r'case \.\w+: "([^"]+)"',opened)))


VENDORS=vendors()
SUPPORTED={'Codex','Cursor'}
HOMES={'Claude':['.claude/projects','.claude'], 'Codex':['.codex'], 'DeepSeek':['.deepseek'],
    'Antigravity':['.gemini/antigravity','AppData/Roaming/Antigravity'], 'Cursor':['AppData/Roaming/Cursor/User/globalStorage/state.vscdb'],
    'Grok':['.grok','AppData/Roaming/Grok Bot'],'GitHub Copilot':['.copilot/session-state','.copilot/config.json'],
    'OpenClaw':['.openclaw'],'Hermes':['.hermes/state.db'],'ZCode':['.zcode'],
    'CodeBuddy':['.codebuddy/projects','.codebuddycn/projects','.codebuddy','.codebuddycn'],
    'WorkBuddy':['.workbuddy/projects','.workbuddy'],'Qwen':['.qwen'],'Devin':['.local/share/devin/cli/sessions.db'],
    'OpenCode':['.local/share/opencode','AppData/Roaming/opencode','.config/opencode'],
    'Kimi':['.kimi-code/sessions','.kimi/sessions'],'GLM':['.glm'],'Pi':['.pi/agent/sessions']}
COMMANDS={'Claude':['claude'],'Codex':['codex'],'Cursor':['cursor'],'Antigravity':['antigravity'],
    'Grok':['grok'],'GitHub Copilot':['copilot'],'OpenClaw':['openclaw'],'Hermes':['hermes'],
    'ZCode':['zcode'],'CodeBuddy':['codebuddy'],'WorkBuddy':['workbuddy'],'Qwen':['qwen'],
    'Devin':['devin'],'OpenCode':['opencode'],'Kimi':['kimi'],'Pi':['pi']}


def detect_sources(active=(),home=None,process_names=None,which=shutil.which):
    home=Path.home() if home is None else Path(home)
    if process_names is None:
        import psutil
        process_names=set()
        for proc in psutil.process_iter(['name']):
            try:process_names.add((proc.info.get('name') or '').lower())
            except (psutil.NoSuchProcess,psutil.AccessDenied):pass
    rows=[]
    for vendor in VENDORS:
        commands=COMMANDS.get(vendor,[])
        running=vendor in active or vendor not in SUPPORTED and any(name+'.exe' in process_names for name in commands)
        installed=running or any((home/path).exists() for path in HOMES.get(vendor,[])) or any(which(name) for name in commands)
        # Installation never claims sign-in, quota support, or a running app.
        rows.append(dict(vendor=vendor,installed=bool(installed),running=running,supported=vendor in SUPPORTED))
    return sorted(rows,key=lambda row:(not row['running'],not row['installed']))
