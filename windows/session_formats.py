"""Translations of upstream provider token layouts; no prompt/tool text is retained."""
import hashlib,math
from datetime import datetime,timezone


def stamp(value):
    if isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value) and value>0:return value/1000 if value>1e11 else value
    if isinstance(value,str):
        try:return datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()
        except ValueError:
            try:return stamp(float(value))
            except ValueError:pass
    return None


def count(value):
    if value is None:return 0
    if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or value<0 or int(value)!=value:raise ValueError('Invalid token counter')
    return int(value)


def first(value,*keys):return next((value[key] for key in keys if value.get(key) is not None),None)
def digest(*parts):return hashlib.sha256('\0'.join(map(str,parts)).encode()).hexdigest()


def tencent_tokens(usage):
    # TencentBuddySessions.tokens: nested/total evidence decides inclusive counts.
    listed=first(usage,'cache_read_input_tokens','cacheReadInputTokens','cacheTokens','prompt_cache_hit_tokens','cached_tokens')
    details=first(usage,'inputTokensDetails','input_tokens_details','prompt_tokens_details')
    details=[details] if isinstance(details,dict) else details if isinstance(details,list) else []
    nested=sum(count(row.get('cached_tokens')) for row in details)
    cache=count(listed) if listed is not None else nested
    inp=count(first(usage,'input_tokens','inputTokens','prompt_tokens'));out=count(first(usage,'output_tokens','outputTokens','completion_tokens'))
    write=count(first(usage,'cache_creation_input_tokens','cacheCreationInputTokens','cachedWriteTokens','prompt_cache_write_tokens'))
    reasoning=count(first(usage,'completion_thinking_tokens','completionThinkingTokens','reasoningTokens'))
    total=first(usage,'total_tokens','totalTokens');inclusive=(listed is None and bool(details)) or total==inp+out
    miss=first(usage,'cachedMissTokens','cacheMissTokens')
    fresh=count(miss)+(0 if inclusive else write) if miss is not None else inp-cache if inclusive else inp+write
    if fresh<0:raise ValueError('Cache exceeds inclusive input')
    output=out if inclusive else out+reasoning
    return dict(input=fresh,output=output,cache=cache,cache_write=min(write,fresh),reasoning=min(reasoning,output))


class Transcript:
    def __init__(self,vendor,sid):
        self.vendor=vendor;self.sid=sid;self.model='Unknown';self.events={};self.title=vendor+' · '+sid[:8];self.title_priority=0;self.updated=0.;self.state='unknown';self.previous_total=None;self.started=None;self.boundary=None;self.active_calls={};self.activity=None
    def add(self,key,at,tokens,model=None):
        if at is None or not sum(tokens[k] for k in ('input','output','cache')):return
        self.updated=max(self.updated,at)
        event=dict(id=str(key),session=self.sid,model=model or self.model,at=at,**tokens)
        prior=self.events.get(str(key))
        if prior is None or sum(event[k] for k in ('input','output','cache'))>=sum(prior[k] for k in ('input','output','cache')):self.events[str(key)]=event
    def feed(self,row,line):
        if not isinstance(row,dict):raise ValueError('Invalid transcript object')
        if self.vendor in ('DeepSeek','Grok','GitHub Copilot'):
            from four_formats import feed
            return feed(self,row,line)
        vendor=self.vendor;kind=row.get('type');message=row.get('message') or {};at=stamp(row.get('timestamp'))
        if not isinstance(message,dict):message={}
        if kind in ('custom-title','ai-title','topic','session_info'):
            name=first(row,'customTitle','aiTitle','topic','name')
            priority={'custom-title':3,'ai-title':2,'topic':1,'session_info':1}.get(kind,0)
            if isinstance(name,str) and name.strip() and name not in ('(No content)','/compact') and priority>=self.title_priority:self.title=name.splitlines()[0][:100];self.title_priority=priority
        self.model=first(row,'model','modelId') or message.get('model') or self.model
        if vendor=='Codex':
            payload=row.get('payload') or {};pk=payload.get('type')
            if kind=='session_meta' and self.started is None:
                self.sid=payload.get('id') or self.sid;self.started=stamp(payload.get('timestamp')) or at;self.boundary=payload.get('subagent_history_start_ordinal');return
            inherited=(at is not None and self.started is not None and at<self.started) or (isinstance(self.boundary,int) and isinstance(row.get('ordinal'),int) and row['ordinal']<=self.boundary)
            if kind=='turn_context':self.model=payload.get('model') or self.model
            if kind=='response_item' and self.state=='running' and not inherited and at is not None:
                call=payload.get('call_id');name=str(payload.get('name') or '').rsplit('.',1)[-1]
                if pk in ('function_call','custom_tool_call','local_shell_call') and call:
                    work='command' if pk=='local_shell_call' or name in ('exec','shell','shell_command','exec_command','write_stdin','js','js_reset') or name.startswith('mcp__') else 'edit' if name=='apply_patch' else 'read' if name=='view_image' else 'question' if name=='request_user_input_async' else None
                    if work:self.active_calls[call]=work
                    while len(self.active_calls)>256:self.active_calls.pop(next(iter(self.active_calls)))
                elif pk in ('function_call_output','custom_tool_call_output') and call:self.active_calls.pop(call,None)
                self.activity=next(reversed(self.active_calls.values()),'thinking');self.updated=max(self.updated,at)
            if kind!='event_msg':return
            if pk=='task_started' and not inherited:self.state='running';self.active_calls.clear();self.activity='thinking'
            elif pk in ('task_complete','task_completed') and not inherited:self.state='done';self.active_calls.clear();self.activity=None
            elif pk=='turn_aborted' and not inherited:self.state='stopped';self.active_calls.clear();self.activity=None
            if pk in ('task_started','task_complete','task_completed','turn_aborted') and at is not None and not inherited:self.updated=max(self.updated,at)
            if pk!='token_count':return
            info=payload.get('info') or {};total=info.get('total_token_usage');usage=info.get('last_token_usage')
            if total is not None and total==self.previous_total:return
            if total:
                reset=self.previous_total and any(count(total.get(k))<count(self.previous_total.get(k)) for k in ('input_tokens','output_tokens','cached_input_tokens'))
                if self.previous_total and not reset:usage={key:max(0,count(value)-count(self.previous_total.get(key))) for key,value in total.items()}
                else:usage=usage or total
            self.previous_total=total
            if not usage or inherited:return
            cache=count(usage.get('cached_input_tokens'));inp=count(usage.get('input_tokens'));out=count(usage.get('output_tokens'));reason=count(usage.get('reasoning_output_tokens'))
            self.add(digest(self.sid,at,total),at,dict(input=max(0,inp-cache),output=out,cache=cache,cache_write=min(max(0,inp-cache),count(usage.get('cache_write_input_tokens'))),reasoning=min(out,reason)))
        elif vendor=='Claude':
            if kind!='assistant' or not isinstance(message.get('usage'),dict):return
            usage=message['usage'];write=count(usage.get('cache_creation_input_tokens'))
            self.add(message.get('id') or row.get('uuid') or digest(self.sid,line),at,
                dict(input=count(usage.get('input_tokens'))+write,output=count(usage.get('output_tokens')),cache=count(usage.get('cache_read_input_tokens')),cache_write=write,reasoning=0))
        elif vendor in ('CodeBuddy','WorkBuddy'):
            provider=row.get('providerData') or {}
            if kind not in ('message','function_call') or kind=='message' and row.get('role')!='assistant' or row.get('status') not in (None,'completed'):return
            usage=message.get('usage') or provider.get('usage') or provider.get('rawUsage')
            if not isinstance(usage,dict):return
            self.add(provider.get('messageId') or provider.get('traceId') or row.get('id') or digest(self.sid,line),at,tencent_tokens(usage),provider.get('model') or self.model)
        elif vendor in ('OpenClaw','Pi'):
            if kind!='message' or message.get('role')!='assistant' or not isinstance(message.get('usage'),dict):return
            if message.get('api')=='openclaw-transcript' or message.get('provider') in ('openclaw','claude-cli') or str(message.get('idempotencyKey','')).startswith('codex-app-server:'):return
            usage=message['usage'];write=count(usage.get('cacheWrite'))
            self.add(digest(message.get('provider'),message['responseId']) if message.get('responseId') else digest(row.get('id') or line,at,self.model),
                stamp(message.get('timestamp')) or at,dict(input=count(usage.get('input'))+write,output=count(usage.get('output')),cache=count(usage.get('cacheRead')),cache_write=write,reasoning=0))
        elif vendor=='Qwen':
            if row.get('forkedFrom') or kind!='system' or row.get('subtype')!='ui_telemetry':return
            event=(row.get('systemPayload') or {}).get('uiEvent') or {}
            if event.get('event.name')!='qwen-code.api_response' and event.get('name') not in ('qwen-code.api_response','api_response'):return
            usage=event.get('usage') or event
            inp=count(first(usage,'input_token_count','input_tokens','inputTokens'));cache=count(first(usage,'cached_content_token_count','cached_tokens','cacheReadTokens'))
            if cache>inp:raise ValueError('Cache exceeds input')
            out=count(first(usage,'output_token_count','output_tokens','outputTokens'));thought=count(usage.get('thoughts_token_count'))
            separate=thought>0 and usage.get('total_token_count')==inp+out+thought
            self.add(row.get('uuid') or digest(self.sid,line),stamp(event.get('event.timestamp')) or at,dict(input=inp-cache,output=out+(thought if separate else 0),cache=cache,cache_write=0,reasoning=min(thought,out+(thought if separate else 0))),event.get('model'))
        elif vendor=='OpenCode':
            if row.get('role')!='assistant' or not isinstance(row.get('tokens'),dict):return
            usage=row['tokens'];cache=usage.get('cache') or {};write=count(cache.get('write'));reason=count(usage.get('reasoning'))
            self.add(row.get('id') or digest(self.sid,line),stamp((row.get('time') or {}).get('created')) or at,
                dict(input=count(usage.get('input'))+write,output=count(usage.get('output'))+reason,cache=count(cache.get('read')),cache_write=write,reasoning=reason),row.get('modelID'))
        elif vendor=='Kimi':
            if kind=='llm.request':self.model=row.get('model') or self.model;return
            if kind=='usage.record' and row.get('usageScope')=='turn':
                usage=row.get('usage') or {};write=count(usage.get('inputCacheCreation'))
                self.add(digest(self.sid,'usage',line),stamp(row.get('time')),dict(input=count(usage.get('inputOther'))+write,output=count(usage.get('output')),cache=count(usage.get('inputCacheRead')),cache_write=write,reasoning=0))
            elif message.get('type')=='StatusUpdate':
                payload=message.get('payload') or {};usage=payload.get('token_usage')
                if not isinstance(usage,dict):return
                write=count(usage.get('input_cache_creation'))
                self.add(digest(self.sid,payload.get('message_id') or line),at,dict(input=count(usage.get('input_other'))+write,output=count(usage.get('output')),cache=count(usage.get('input_cache_read')),cache_write=write,reasoning=0))
    def summary(self):
        totals={key:sum(row.get(key,0) for row in self.events.values()) for key in ('input','output','cache','cache_write','reasoning')}
        return dict(id=self.sid,title=self.title,state=self.state,updated=self.updated,tokens=sum(totals[k] for k in ('input','output','cache')),
                    model=self.model,activity=self.activity if self.state=='running' else None,priority=max((e.get('priority',0) for e in self.events.values()),default=0),breakdown=dict(input=max(0,totals['input']-totals['cache_write']),cache=totals['cache'],output=max(0,totals['output']-totals['reasoning']),reasoning=totals['reasoning']),**totals)
