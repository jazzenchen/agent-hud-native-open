"""Windows translation of PermissionRequest/Decision and completion semantics.

Wire shapes follow Sources/AgentHUDCore/Hooks. Request inputs and reply text
live only in memory. An unrecognized/unsupported request gets no decision.
"""
import json,time,uuid
from pathlib import Path

LIMIT=1024*1024
VENDORS={'claude':'Claude','codex':'Codex','workbuddy':'WorkBuddy','codebuddy':'CodeBuddy','cursor':'Cursor',
         'qwen':'Qwen','zcode':'ZCode','devin':'Devin'}


def text(value,limit=2048):
    return value[:limit] if isinstance(value,str) else ''


def codex_user_reviewer(payload):
    """Never hold or answer Codex automatic review. Unknown also falls through.

    Match the newest context of this exact turn, as CodexPermissionReviewer does.
    Read only a bounded tail, never infer the reviewer from approval_policy.
    """
    turn=payload.get('turn_id');path=payload.get('transcript_path')
    if not isinstance(turn,str) or not turn or not isinstance(path,str):return False
    try:
        with Path(path).open('rb') as stream:
            stream.seek(0,2);length=stream.tell();offset=max(0,length-4*LIMIT)
            stream.seek(offset);lines=stream.read(4*LIMIT).splitlines()
        if offset and lines:lines=lines[1:]
        for line in reversed(lines):
            if b'"turn_context"' not in line:continue
            try:record=json.loads(line)
            except (ValueError,UnicodeError,RecursionError):continue
            if not isinstance(record,dict):continue
            context=record.get('payload')
            if record.get('type')=='turn_context' and isinstance(context,dict) and context.get('turn_id')==turn:
                return context.get('approvals_reviewer')=='user'
    except (OSError,ValueError,RecursionError):pass
    return False


def permission(source,payload,now=None,reviewer=codex_user_reviewer):
    if source not in VENDORS or source=='cursor' or not isinstance(payload,dict):return None
    if payload.get('hook_event_name','PermissionRequest')!='PermissionRequest':return None
    sid=payload.get('session_id');tool=payload.get('tool_name');inputs=payload.get('tool_input')
    if not isinstance(sid,str) or not sid or len(sid)>512 or not isinstance(inputs,dict):return None
    if source=='codex' and not reviewer(payload):return None
    kind=text(tool,256).rsplit('__',1)[-1]
    if source in ('workbuddy','codebuddy') and kind in ('AskUserQuestion','ExitPlanMode'):return None
    if source in ('qwen','devin') and kind in ('ask_user_question','exit_plan_mode'):return None
    if source=='zcode' and kind=='ExitPlanMode':return None
    questions=[]
    if kind=='AskUserQuestion':
        raw=inputs.get('questions')
        if not isinstance(raw,list) or not 0<len(raw)<=16:return None
        for item in raw:
            if not isinstance(item,dict) or not text(item.get('question')):return None
            options=item.get('options')
            if not isinstance(options,list) or not 0<len(options)<=32:return None
            if any(not isinstance(o,dict) or not text(o.get('label')) for o in options):return None
            questions.append(dict(question=item['question'],header=text(item.get('header'),100),
                                  multi=bool(item.get('multiSelect')),options=options))
    plan=text(inputs.get('plan'),LIMIT) if kind=='ExitPlanMode' and source=='claude' else ''
    if kind=='ExitPlanMode' and not plan:return None
    detail=next((inputs[k] for k in ('command','file_path','notebook_path','url','plan') if isinstance(inputs.get(k),str)),None)
    if detail is None:detail=json.dumps(inputs,ensure_ascii=False,indent=2)
    summary=questions[0]['question'] if questions else text(inputs.get('description')) or text(detail.splitlines()[0] if detail else tool)
    suggestions=payload.get('permission_suggestions')
    offered=[]
    if source=='claude' and isinstance(suggestions,list):
        for suggestion in suggestions:
            if not isinstance(suggestion,dict) or suggestion.get('type')!='addRules' or suggestion.get('behavior')!='allow':continue
            rules=suggestion.get('rules')
            if isinstance(rules,list) and rules and all(isinstance(r,dict) and text(r.get('toolName')) for r in rules):offered.append(suggestion)
    return dict(id=uuid.uuid4().hex,kind='permission',source=source,vendor=VENDORS[source],session=sid,
                tool=text(tool,256),summary=summary,detail=detail[:LIMIT],cwd=text(payload.get('cwd'),32768),
                input=inputs,questions=questions,plan=plan,suggestions=offered,
                removed=text(inputs.get('old_string')),added=text(inputs.get('new_string') or inputs.get('content')),
                at=time.time() if now is None else now)


def decision(request,action,*,update=None,answers=None,accept_edits=False,note=''):
    """Only an explicit action produces an answer. No default or timed allow."""
    if action=='leave':return b''
    value={'behavior':'allow' if action in ('allow','always','answer','approve_plan') else 'deny'}
    if action=='always':
        if request['source']!='claude' or update not in request.get('suggestions',[]):return b''
        value['updatedPermissions']=[update]
    elif action=='answer':
        if request['source'] not in ('claude','zcode') or not request.get('questions') or not isinstance(answers,dict):return b''
        if any(k not in {q['question'] for q in request['questions']} or not isinstance(v,str) for k,v in answers.items()):return b''
        if any(not answers.get(q['question'],'').strip() for q in request['questions']):return b''
        value['updatedInput']={**request['input'],'answers':answers}
    elif action=='approve_plan':
        if request['source']!='claude' or not request.get('plan'):return b''
        value['updatedInput']=request['input']
        if accept_edits:value['updatedPermissions']=[dict(type='setMode',mode='acceptEdits',destination='session')]
    elif action=='keep_planning':
        if request['source']!='claude' or not request.get('plan'):return b''
        value['message']='The user reviewed this plan in Agent HUD and did not approve it. '+('Their feedback: '+text(note) if note.strip() else 'They want to keep planning.')
    elif action not in ('allow','deny'):return b''
    # Questions/plans cannot be approved as if they were ordinary tool calls.
    if action in ('allow','always') and (request.get('questions') or request.get('plan')):return b''
    return json.dumps(dict(hookSpecificOutput=dict(hookEventName='PermissionRequest',decision=value)),ensure_ascii=False).encode()


def buddy_last_assistant(path,session):
    """TencentBuddySessions.lastAssistantMessage: latest turn, at most 1 MiB.

    A newer user message is a boundary, not a reason to replay an older reply.
    Only the stable message identity and model leave this reader.
    """
    if not isinstance(path,str):return None
    try:
        with Path(path).open('rb') as stream:
            stream.seek(0,2);offset=max(0,stream.tell()-LIMIT);stream.seek(offset);lines=stream.read(LIMIT).splitlines()
        if offset and lines:lines=lines[1:]
        for line in reversed(lines):
            try:record=json.loads(line)
            except (ValueError,UnicodeError,RecursionError):continue
            if not isinstance(record,dict) or record.get('type')!='message' or record.get('sessionId',session)!=session:continue
            if record.get('role')=='user':return None
            if record.get('role')!='assistant' or record.get('status')!='completed':continue
            provider=record.get('providerData');provider=provider if isinstance(provider,dict) else {}
            message=record.get('message');message=message if isinstance(message,dict) else {}
            identity=text(provider.get('messageId'),512)
            model=next((text(value,100) for value in (provider.get('model'),provider.get('requestModelId'),message.get('model')) if isinstance(value,str) and value.strip()),'')
            return (identity,model) if identity.strip() else None
    except (OSError,ValueError):pass
    return None


def completion(source,payload,now=None):
    if source not in VENDORS or not isinstance(payload,dict):return None
    if source=='cursor':
        if payload.get('hook_event_name')!='stop' or payload.get('status')!='completed':return None
        sid=payload.get('conversation_id');turn=payload.get('generation_id')
        roots=payload.get('workspace_roots');cwd=roots[0] if isinstance(roots,list) and roots else ''
    else:
        if payload.get('hook_event_name')!='Stop' or payload.get('error') or payload.get('status') in ('aborted','error','cancelled'):return None
        sid=payload.get('session_id');turn=payload.get('prompt_id') if source in ('qwen','devin') else payload.get('turn_id') or payload.get('message_id')
        cwd=payload.get('cwd')
    if not isinstance(sid,str) or not sid or len(sid)>512:return None
    model=text(payload.get('model'),100)
    if source in ('workbuddy','codebuddy'):
        message=buddy_last_assistant(payload.get('transcript_path'),sid)
        if message:turn,model=message
    now=time.time() if now is None else now
    turn=text(turn,512) or 'stop-'+str(int(now*1000))
    return dict(id=uuid.uuid4().hex,kind='completion',source=source,vendor=VENDORS[source],session=sid,turn=turn,
                summary=text(payload.get('title'),100) or (Path(cwd).name if isinstance(cwd,str) and cwd else VENDORS[source]),
                message=text(payload.get('last_assistant_message')),cwd=text(cwd,32768),model=model,at=now)


class CompletionTracker:
    """Observe new running→done transitions, never alert on historical indexing."""
    def __init__(self):self.previous={};self.started=time.time()
    def update(self,snapshot):
        result=[];current={}
        for vendor,data in snapshot.items():
            for row in data.get('local',{}).get('sessions',[]):
                sid=str(row.get('id',''));key=(vendor,sid);current[key]=row.get('state')
                updated=row.get('updated')
                if self.previous.get(key)!='running' or row.get('state')!='done' or not isinstance(updated,(int,float)) or updated<self.started:continue
                source=next((s for s,v in VENDORS.items() if v==vendor),None)
                if source:
                    result.append(dict(id=uuid.uuid4().hex,kind='completion',source=source,vendor=vendor,session=sid,
                        turn='observed-'+str(row.get('updated')),summary=text(row.get('title'),100),message='',
                        cwd=text(row.get('cwd'),32768),model=text(row.get('model'),100),at=row.get('updated',time.time())))
        self.previous=current
        return result
