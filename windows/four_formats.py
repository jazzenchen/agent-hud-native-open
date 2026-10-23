"""Windows translations of the four remaining upstream transcript readers.

Modified for Windows by nanhudev. Original schemas/precedence: GrokSessions,
CopilotSessions, DeepSeekTranscript, AntigravityProtoReader (see THIRD_PARTY_NOTICES.txt).
Only explicitly projected counters/metadata are retained, never message bodies.
"""
import json,math
from session_formats import Transcript,stamp,count,digest,first


def harness_time(value):
    # Harness specifies milliseconds, including early-epoch test/import logs;
    # do not infer the unit from the number's size.
    return value/1000 if isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value) else None

def feed(p,row,line):
    kind=row.get('type');data=row.get('data') or {};at=stamp(row.get('timestamp'))
    if p.vendor=='DeepSeek':
        if kind=='session':
            if row.get('version') not in (0,2,3,4):raise ValueError('Unsupported Harness format')
            p.sid=row.get('id') or p.sid;p.started=harness_time(row.get('createdAt'));p.format=row.get('version');p.seed=row.get('seedLength',math.inf if row.get('isSeeded') else 0);p.seed_marker=None;p.attempts=0;p.last_attempt=None;p.billing_provider='Unknown';p.requested_at=None;return
        if not hasattr(p,'seed'):return
        at=harness_time(row.get('time'));seq=row.get('seq')
        config=(data.get('header') or {}).get('config',{}) if kind=='request/header' else data
        if kind in ('request/header','request/context') and config.get('model'):
            p.model=config['model'];p.billing_provider='deepseek-official' if config.get('provider')=='deepseek-official' else 'Unknown'
        if kind=='session/end-seed' and data.get('inherited') and isinstance(seq,int) and seq<p.seed:
            p.seed_marker=seq
            if at and p.started and at>=p.started:p.seed=seq
        elif p.seed==math.inf and p.format>=4 and p.seed_marker is not None and at and p.started and at>=p.started:p.seed=p.seed_marker
        if not isinstance(seq,int) or seq<p.seed:return
        if kind=='session/title' and isinstance(data.get('title'),str):p.title=data['title'].splitlines()[0][:100]
        if kind=='turn/start':p.state='running'
        if kind=='turn/end':p.state='done' if (data.get('reason') or {}).get('kind')=='completed' else 'stopped'
        if kind=='step/start':p.requested_at=at
        if kind=='llm/retry-started':p.last_attempt=None;p.requested_at=at
        if kind not in ('assistant/chunk','assistant/message','assistant/attempt'):return
        chunks=[item.get('chunk') for item in data.get('stream') or [] if isinstance(item,dict)] or [data.get('chunk')]
        usage=data.get('usage') or next((chunk.get('usage') for chunk in reversed(chunks) if isinstance(chunk,dict) and chunk.get('type')=='usage'),None)
        if not isinstance(usage,dict) or data.get('turn') is None or data.get('step') is None:return
        attempt=(data['turn'],data['step'])
        if kind!='assistant/attempt' and p.last_attempt and p.last_attempt[:2]==attempt:key=p.last_attempt[2]
        else:
            p.attempts+=1;key=digest(p.sid,'attempt',p.attempts)
            p.last_attempt=(*attempt,key) if kind!='assistant/attempt' else None
        write=count(usage.get('cacheWriteTokens'));out=count(usage.get('outputTokens'))
        tokens=dict(input=count(usage.get('inputTokens'))+write,output=out,cache=count(usage.get('cacheReadTokens')),cache_write=write,reasoning=min(out,count(usage.get('reasoningTokens'))))
        if at is not None:
            p.events.pop(key,None)
            p.add(key,at,tokens)
            if key in p.events:p.events[key].update(correction=True,billing_provider=p.billing_provider,requested_at=p.requested_at if p.requested_at is not None else at)
    elif p.vendor=='Grok':
        if row.get('method') not in ('session/update','_x.ai/session/update'):return
        params=row.get('params') or {};meta=params.get('_meta') or {};update=params.get('update') or {};at=stamp(meta.get('agentTimestampMs'))
        if not params.get('sessionId'):return
        p.sid=params['sessionId'];p.model=(update.get('_meta') or {}).get('modelId') or meta.get('modelId') or p.model
        k=update.get('sessionUpdate')
        if k in ('user_message_chunk','agent_message_chunk','tool_call','tool_call_update'):p.state='running'
        if k!='turn_completed':return
        p.state='done' if update.get('stop_reason')=='end_turn' else 'stopped';usage=update.get('usage') or {}
        if usage.get('inputTokens') is None or usage.get('outputTokens') is None:return
        models=usage.get('modelUsage') or {}
        if len(models)==1:p.model=next(iter(models))
        inp=count(usage['inputTokens']);cache=count(first(usage,'cachedReadTokens','cacheReadTokens'))
        if cache>inp:raise ValueError('Grok cache exceeds input')
        key=digest(p.sid,meta.get('eventId') or line)
        p.add(key,at,dict(input=inp-cache,output=count(usage['outputTokens']),cache=cache,cache_write=0,reasoning=0))
        if key in p.events:p.events[key]['priority']=1
    elif p.vendor=='GitHub Copilot':
        if kind=='session.start':p.copilot_started=True;p.model=data.get('selectedModel') or p.model
        if kind=='session.model_change':p.model=data.get('newModel') or p.model
        if kind in ('user.message','assistant.turn_start'):p.state='running'
        if kind=='abort':p.state='stopped'
        if kind=='hook.start' and data.get('hookType')=='agentStop':p.state='done' if (data.get('input') or {}).get('stopReason')=='end_turn' else 'stopped'
        if kind!='session.shutdown':return
        p.state='done';peaks=getattr(p,'peaks',{});seen=getattr(p,'snapshots',set())
        for raw,metric in (data.get('modelMetrics') or {}).items():
            key=digest(p.sid,row.get('id') or at,raw)
            if key in seen:continue
            seen.add(key);usage=metric.get('usage') or {};values=[count(usage.get(k)) for k in ('inputTokens','outputTokens','cacheReadTokens')]
            baseline=peaks.get(raw,[0,0,0] if getattr(p,'copilot_started',False) else None)
            peaks[raw]=[max(a,b) for a,b in zip(peaks.get(raw,values),values)]
            if baseline is None:continue
            inp,out,cache=[max(0,a-b) for a,b in zip(values,baseline)];cache=min(cache,inp)
            model=raw if raw not in ('auto','') else data.get('currentModel') or p.model
            p.add(key,at,dict(input=inp-cache,output=out,cache=cache,cache_write=0,reasoning=0),model)
            if key in p.events:p.events[key]['priority']=1
        p.peaks=peaks;p.snapshots=seen


def otel_count(value):
    if isinstance(value,str) and value.isascii() and value.isdigit():value=int(value)
    return count(value)


class FileTranscript:
    """Source logs can contain several sessions; trace context joins stay exact."""
    def __init__(self,vendor,sid):self.vendor=vendor;self.sid=sid;self.parsed={};self.contexts={};self.pending={};self.models={}
    def feed(self,row,line):
        if not isinstance(row,dict):raise ValueError('Invalid source document')
        if self.vendor=='Grok':
            sid=row.get('sid');ctx=row.get('ctx') or {};msg=row.get('msg');pid=str(row.get('pid',''))
            if msg=='AuthManager::new':self.models={key:value for key,value in self.models.items() if key[1]!=pid};return
            changed={'model changed':'model','model catalog: notifying clients':'current_model_id','backend_search: model switch':'new_model'}.get(msg)
            if changed:
                if sid:self.models[(sid,pid)]=ctx.get(changed)
                return  # A process-wide model is not assigned across unknown sessions.
            if msg!='shell.turn.inference_done' or not sid:return
            inp=count(ctx.get('prompt_tokens'));cache=count(ctx.get('cached_prompt_tokens'))
            if cache>inp:raise ValueError('Invalid Grok counters')
            parser=self.parsed.setdefault(sid,Transcript(self.vendor,sid));key=digest(sid,row.get('event_id') or row.get('eventId') or ctx.get('event_id') or json.dumps(row,sort_keys=True,separators=(',',':')))
            parser.add(key,stamp(row.get('ts')),dict(input=inp-cache,output=count(ctx.get('completion_tokens')),cache=cache,cache_write=0,reasoning=0),self.models.get((sid,pid)) or 'Unknown')
            if key in parser.events:parser.events[key]['priority']=2
        else:
            attrs=row.get('attributes') or {}
            if not isinstance(attrs,dict):return
            trace=row.get('traceId') or (row.get('spanContext') or {}).get('traceId');sid=attrs.get('gen_ai.conversation.id');model=attrs.get('gen_ai.response.model') or attrs.get('gen_ai.request.model')
            if trace:
                known=self.contexts.get(trace,{});self.contexts[trace]=dict(session=known.get('session') or sid,model=known.get('model') or model)
            if attrs.get('gen_ai.operation.name')!='chat' and not str(row.get('name','')).startswith('chat '):return
            if attrs.get('gen_ai.usage.input_tokens') is None and attrs.get('gen_ai.usage.output_tokens') is None:return
            at=row.get('startTime') or row.get('endTime')
            if not isinstance(at,list) or len(at)!=2:return
            at=stamp(at[0]+at[1]/1e9);inp=otel_count(attrs.get('gen_ai.usage.input_tokens',0));out=otel_count(attrs.get('gen_ai.usage.output_tokens',0));cache=otel_count(first(attrs,'gen_ai.usage.cache_read.input_tokens','gen_ai.usage.cache_read_input_tokens') or 0)
            if cache>inp:raise ValueError('Copilot cache exceeds input')
            span=row.get('spanId') or (row.get('spanContext') or {}).get('spanId');key=digest(trace,span) if trace and span else digest(attrs.get('gen_ai.response.id') or json.dumps(row,sort_keys=True))
            self.pending[key]=dict(sid=sid,trace=trace,model=model,at=at,tokens=dict(input=max(0,inp-cache),output=out,cache=cache,cache_write=0,reasoning=0))
    def finalize(self):
        for key,event in self.pending.items():
            ctx=self.contexts.get(event['trace'],{});sid=event['sid'] or ctx.get('session')
            if not sid:continue
            parser=self.parsed.setdefault(sid,Transcript(self.vendor,sid));identity=digest(sid,key)
            parser.add(identity,event['at'],event['tokens'],event['model'] or ctx.get('model'))
            if identity in parser.events:parser.events[identity]['priority']=2
    @property
    def events(self):
        self.finalize();return {key:value for parser in self.parsed.values() for key,value in parser.events.items()}
    def summaries(self):
        self.finalize();return [parser.summary() for parser in self.parsed.values()]
