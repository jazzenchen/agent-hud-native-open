"""Read-only Windows ports of the original LocalSessionLayout/OpenAgentParser.

Only counters, model/session metadata and explicit titles leave this reader.
Readers run for live, enabled clients, without launching a client or model turn.
"""
import io,json,os,re,sqlite3,time
from pathlib import Path
from session_formats import Transcript,count,stamp,tencent_tokens,digest
from providers import read_db,DATA,CODEX
from usage_ledger import UsageLedger


def roots(vendor,home=None,env=None):
    home=Path.home() if home is None else Path(home);env=os.environ if env is None else env
    base=lambda key,default:Path(env.get(key) or home/default).expanduser()
    paths={
        'Claude':[base('CLAUDE_CONFIG_DIR','.claude')/'projects'], 'Codex':[base('CODEX_HOME','.codex')/'sessions'],
        'CodeBuddy':[home/'.codebuddy/projects',home/'.codebuddycn/projects'], 'WorkBuddy':[home/'.workbuddy/projects'],
        'OpenClaw':[base('OPENCLAW_STATE_DIR','.openclaw')/'agents',home/'.clawdbot/agents'],
        'Pi':[base('PI_CODING_AGENT_DIR','.pi/agent')/'sessions'], 'Qwen':[base('QWEN_HOME','.qwen')/'projects'],
        'Kimi':[base('KIMI_CODE_HOME','.kimi-code')/'sessions',home/'.kimi/sessions'],
        'OpenCode':[base('XDG_DATA_HOME','.local/share')/'opencode'],
        'Hermes':[base('HERMES_HOME','.hermes')], 'ZCode':[home/'.zcode/cli/db'],
        'Grok':[base('GROK_HOME','.grok')/'sessions',base('GROK_HOME','.grok')/'logs'],
        'GitHub Copilot':[base('COPILOT_HOME','.copilot')/'session-state',base('COPILOT_HOME','.copilot')/'otel'],
        'Antigravity':[base('GEMINI_CLI_HOME','.gemini')/'antigravity-cli/conversations',base('GEMINI_CLI_HOME','.gemini')/'antigravity',base('GEMINI_CLI_HOME','.gemini')/'antigravity/conversations'],
        'Devin':[home/'.local/share/devin/cli'], 'DeepSeek':[base('DSH_HOME','.dsh')/'sessions'], 'GLM':[]}
    result=paths.get(vendor,[])
    if vendor=='GitHub Copilot' and env.get('COPILOT_OTEL_FILE_EXPORTER_PATH'):
        folder=Path(env['COPILOT_OTEL_FILE_EXPORTER_PATH']).expanduser().parent
        if folder not in result:result.append(folder)
    return result


def accepts(vendor,path,exporter=None):
    name=path.name
    if vendor=='OpenClaw':return (path.parent.name=='sessions' and (name.endswith('.jsonl') or '.jsonl.reset.' in name or '.jsonl.deleted.' in name)) and not name.endswith(('.zst','.tmp')) or name=='openclaw-agent.sqlite'
    if vendor=='OpenCode':return name=='opencode.db' or path.suffix=='.json' and 'message' in path.parts
    if vendor=='Hermes':return name=='state.db'
    if vendor=='ZCode':return name=='db.sqlite'
    if vendor=='Devin':return name=='sessions.db'
    if vendor=='Antigravity':return path.suffix=='.db' and name!='conversation_summaries.db'
    if vendor=='GitHub Copilot':
        log=name=='events.jsonl' and path.parent.parent.name=='session-state'
        return log or path.suffix=='.jsonl' and 'session-state' not in path.parts and ('otel' in path.parts or exporter and path.absolute()==Path(exporter).expanduser().absolute())
    if vendor=='Grok':return name in ('updates.jsonl','unified.jsonl')
    if vendor=='DeepSeek':return re.fullmatch(r'session(?:\.v[1-9][0-9]*)?\.jsonl(?:\.zstd)?',name) is not None
    return path.suffix=='.jsonl' or vendor=='Kimi' and name.endswith('.json')


class LocalSource:
    def __init__(self,vendor,home=None,env=None,ledger=None):
        self.vendor=vendor;self.paths=roots(vendor,home,env);self.files=[];self.cache={};self.last_scan=0.;self.ledger=ledger or UsageLedger(DATA/'usage-ledger.sqlite')
        self.exporter=(os.environ if env is None else env).get('COPILOT_OTEL_FILE_EXPORTER_PATH')
        self.last_report=None;self.history_report=None;self.report_at=0.;self.errors=0
    def scan(self):
        found=[];cutoff=time.time()-31*86400
        for root in self.paths:
            if not root.exists():continue
            for base,dirs,files in os.walk(root,followlinks=False):
                dirs[:]=[d for d in dirs if d not in ('node_modules','.git','cache','blobs','attachments','logs') and len(Path(base).relative_to(root).parts)<9]
                for name in files:
                    path=Path(base)/name
                    try:
                        if accepts(self.vendor,path,self.exporter) and path.stat().st_mtime>=cutoff:found.append(path)
                    except OSError:pass
                if len(found)>20000:break
        if self.vendor=='DeepSeek':
            # The source keeps older format generations beside the current log.
            selected={}
            for path in found:
                match=re.search(r'\.v(\d+)\.jsonl',path.name);rank=(int(match[1]) if match else 0,path.name.endswith('.zstd'))
                if path.parent not in selected or rank>selected[path.parent][0]:selected[path.parent]=(rank,path)
            found=[row[1] for row in selected.values()]
        self.files=sorted(set(found),key=lambda path:path.stat().st_mtime,reverse=True)[:20000];self.last_scan=time.monotonic()
    def sessions(self):
        if time.monotonic()-self.last_scan>30:self.scan()
        changed=[];incomplete=False;started=time.monotonic();processed=0
        for path in self.files:
            if processed>=8 or time.monotonic()-started>1.5:incomplete=True;break
            try:
                stat=path.stat();wal=Path(str(path)+'-wal');revision=(stat.st_mtime_ns,stat.st_size,wal.stat().st_mtime_ns if wal.exists() else 0)
                old=self.cache.get(str(path))
                if old and old['revision']==revision and old['offset']>=stat.st_size:continue
                processed+=1
                if path.suffix in ('.db','.sqlite'):
                    parsers=self.database(path);changed.extend(event for parser in parsers for event in parser.events.values())
                    self.cache[str(path)]=dict(revision=revision,offset=stat.st_size,parsers=parsers);continue
                if path.suffix=='.json':
                    if stat.st_size>16*1024*1024:raise ValueError('Oversize metadata document')
                    value=json.loads(path.read_bytes());parser=Transcript(self.vendor,str(value.get('sessionID') or value.get('sessionId') or path.stem));parser.feed(value,0)
                    changed.extend(parser.events.values());self.cache[str(path)]=dict(revision=revision,offset=stat.st_size,parsers=[parser]);continue
                if path.suffix=='.zstd':
                    from upstream_runtime import decompress
                    parser=Transcript(self.vendor,path.parent.name)
                    for index,raw in enumerate(decompress(path).splitlines()):
                        try:parser.feed(json.loads(raw),index+1)
                        except (ValueError,TypeError,KeyError,AttributeError):self.errors+=1
                    changed.extend(parser.events.values());self.cache[str(path)]=dict(revision=revision,offset=stat.st_size,parsers=[parser]);continue
                if not old or stat.st_size<old['offset']:
                    from four_formats import FileTranscript
                    parser=FileTranscript(self.vendor,path.stem) if (self.vendor=='Grok' and path.name=='unified.jsonl' or self.vendor=='GitHub Copilot' and path.name!='events.jsonl') else Transcript(self.vendor,path.parent.name if self.vendor in ('DeepSeek','Grok','GitHub Copilot') else path.stem)
                    old=dict(offset=0,parsers=[parser],line=0)
                parser=old['parsers'][0];before=dict(parser.events)
                with path.open('rb') as stream:
                    stream.seek(old['offset']);end=min(stat.st_size,old['offset']+4*1024*1024)
                    while stream.tell()<end:
                        raw=stream.readline(2*1024*1024)
                        if not raw:break
                        if not raw.endswith(b'\n'):
                            if stream.tell()==stat.st_size:stream.seek(-len(raw),1);break
                            self.errors+=1;continue
                        old['line']+=1
                        try:row=json.loads(raw);parser.feed(row,old['line'])
                        except (ValueError,TypeError,KeyError,AttributeError):self.errors+=1
                    old['offset']=stream.tell()
                old['revision']=revision;self.cache[str(path)]=old
                changed.extend(event for key,event in parser.events.items() if before.get(key)!=event)
                if old['offset']<stat.st_size:incomplete=True
            except (OSError,sqlite3.Error,ValueError):self.errors+=1;incomplete=True
        live={str(path) for path in self.files};self.cache={key:value for key,value in self.cache.items() if key in live}
        sessions=[summary for item in self.cache.values() for parser in item['parsers'] for summary in (parser.summaries() if hasattr(parser,'summaries') else [parser.summary()])]
        unique={}
        for row in sessions:
            previous=unique.get(row['id'])
            if previous is None or row.get('priority',0)>previous.get('priority',0):unique[row['id']]=row
        sessions=list(unique.values())
        sessions.sort(key=lambda row:(row['state']!='running',-row['updated']))
        if changed:self.ledger.record(self.vendor,changed)
        if changed or self.last_report is None or time.time()-self.report_at>60:
            self.last_report=self.ledger.report(self.vendor);self.history_report=self.ledger.report(self.vendor,hours=24*400);self.report_at=time.time()
        return dict(connected=bool(self.files),sessions=sessions[:64],stats=self.last_report,history_stats=self.history_report,indexing=incomplete,
                    notice='正在索引本地用量，统计尚不完整' if incomplete else '部分记录无法核对，未计入统计' if self.errors else '本地用量 · 按请求去重')

    def database(self,path):
        with read_db(path) as db:
            db.row_factory=sqlite3.Row;deadline=time.monotonic()+1.2;db.set_progress_handler(lambda:int(time.monotonic()>deadline),10000)
            tables={row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if self.vendor=='Antigravity':
                from antigravity_proto import turn,step
                parser=Transcript('Antigravity',path.stem);rows=[];steps=[]
                for row in db.execute('SELECT idx,data FROM gen_metadata NOT INDEXED LIMIT 10000'):
                    try:rows.append((row['idx'],turn(row['data'])))
                    except (ValueError,UnicodeError,TypeError):self.errors+=1
                if any(value['at'] is None for _,value in rows) and 'steps' in tables:
                    for row in db.execute('SELECT metadata FROM steps NOT INDEXED LIMIT 10000'):
                        try:steps.append(step(row['metadata']))
                        except (ValueError,UnicodeError,TypeError):self.errors+=1
                for index,value in rows:
                    usage=value['usage'];at=value['at']
                    if at is None:
                        field='message' if value.get('message') else 'execution';identity=value.get(field)
                        generations=[r for _,r in rows if identity and r.get(field)==identity]
                        matches=[s for s in steps if identity and s.get(field)==identity and (not value.get('execution') or s.get('execution')==value['execution'])]
                        if len(generations)==len(matches)==1:at=matches[0]['at']
                    if at is None:self.errors+=1;continue
                    inp=usage.get('input',0)+usage.get('cache_write',0);out=usage.get('output',0)
                    parser.add(digest(path.stem,value.get('response') or 'row-'+str(index)),at,dict(input=inp,output=out,cache=usage.get('cache',0),cache_write=usage.get('cache_write',0),reasoning=min(out,usage.get('reasoning',0))),value.get('model') or value.get('label') or 'Antigravity model '+str(usage.get('model_id') or value.get('requested_model') or 'Unknown'))
                return [parser]
            if self.vendor=='OpenCode':
                table='session_message' if 'session_message' in tables else 'message'
                parsers={}
                for row in db.execute(f'SELECT id,session_id,data FROM {table} ORDER BY id DESC LIMIT 10000'):
                    value=json.loads(row['data']);value.setdefault('id',row['id']);sid=str(row['session_id'])
                    parser=parsers.setdefault(sid,Transcript('OpenCode',sid));parser.feed(value,0)
                return list(parsers.values())
            if self.vendor=='OpenClaw':
                parsers={}
                for row in db.execute('SELECT session_id,seq,event_json FROM transcript_events ORDER BY seq DESC LIMIT 10000'):
                    sid=row['session_id'];parser=parsers.setdefault(sid,Transcript('OpenClaw',sid));parser.feed(json.loads(row['event_json']),row['seq'])
                return list(parsers.values())
            if self.vendor=='Hermes':
                metadata={str(row['id']):dict(row) for row in db.execute('SELECT * FROM sessions ORDER BY started_at DESC LIMIT 256')}
                parsers={sid:Transcript('Hermes',sid) for sid in metadata}
                rows=db.execute('SELECT * FROM session_model_usage LIMIT 10000') if 'session_model_usage' in tables else db.execute('SELECT * FROM sessions ORDER BY started_at DESC LIMIT 256')
                for row in rows:
                    r=dict(row);sid=str(r.get('session_id',r.get('id')))
                    if sid not in parsers:continue
                    p=parsers[sid];write=count(r.get('cache_write_tokens'))
                    p.title=metadata[sid].get('title') or p.title
                    p.add(digest(str(path),sid,r.get('model'),r.get('billing_provider') or '',r.get('billing_base_url') or '',r.get('billing_mode') or '',r.get('task') or ''),stamp(r.get('first_seen') or metadata[sid].get('started_at')),
                        dict(input=count(r.get('input_tokens'))+write,output=count(r.get('output_tokens')),cache=count(r.get('cache_read_tokens')),cache_write=write,reasoning=0),r.get('model'))
                return list(parsers.values())
            if self.vendor=='ZCode':
                columns={row[1] for row in db.execute('PRAGMA table_info(model_usage)')};parsers={}
                for row in db.execute('SELECT * FROM model_usage WHERE COALESCE(completed_at,started_at)>=? ORDER BY COALESCE(completed_at,started_at) DESC LIMIT 10000',((time.time()-8*86400)*1000,)):
                    r=dict(row);sid=str(r.get('session_id') or 'unknown');p=parsers.setdefault(sid,Transcript('ZCode',sid))
                    inp=count(r.get('input_tokens'));out=count(r.get('output_tokens'));cache=count(r.get('cache_read_input_tokens'));write=count(r.get('cache_creation_input_tokens'));reason=count(r.get('reasoning_tokens'))
                    inclusive=r.get('computed_total_tokens')==inp+out if r.get('computed_total_tokens') is not None else 'computed_total_tokens' not in columns
                    if inclusive and cache>inp:raise ValueError('Cache exceeds input')
                    inp=inp-cache if inclusive else inp+write;out=out if inclusive else out+reason
                    p.add(str(r['id']),stamp(r.get('completed_at') or r.get('started_at')),dict(input=inp,output=out,cache=cache,cache_write=min(write,inp),reasoning=min(reason,out)),r.get('model_id'))
                return list(parsers.values())
            if self.vendor=='Devin':
                parsers={}
                for row in db.execute("SELECT row_id,session_id,created_at,CASE WHEN json_valid(chat_message) THEN json_extract(chat_message,'$.message_id','$.metadata.request_id','$.metadata.generation_model','$.metadata.created_at','$.metadata.metrics') END FROM message_nodes WHERE created_at>=? ORDER BY row_id DESC LIMIT 10000",(time.time()-8*86400,)):
                    if not row[3]:continue
                    message,request,model,created,metrics=json.loads(row[3]);metrics=metrics or {};sid=str(row['session_id']);p=parsers.setdefault(sid,Transcript('Devin',sid))
                    if metrics.get('input_tokens') is None and metrics.get('total_prompt_tokens') is not None:
                        inp=count(metrics.get('total_prompt_tokens'));cache=count(metrics.get('total_cached_tokens'));write=0;out=count(metrics.get('total_completion_tokens'))
                        if cache>inp:raise ValueError('Cache exceeds input')
                        inp-=cache
                    else:
                        write=count(metrics.get('cache_creation_tokens'));inp=count(metrics.get('input_tokens'))+write;cache=count(metrics.get('cache_read_tokens'));out=count(metrics.get('output_tokens'))
                    p.add(request or message or str(row['row_id']),stamp(created) or stamp(row['created_at']),dict(input=inp,output=out,cache=cache,cache_write=write,reasoning=0),model)
                return list(parsers.values())
            # Unknown schemas are surfaced; they never become a successful zero reading.
            raise ValueError('Source schema requires a provider-specific projection')
