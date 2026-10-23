"""Original MCPProtocol / MCPServer / MCPLineBuffer translated without GUI IO."""
import json,base64,math
from copy import deepcopy
from pathlib import Path

CONTRACT=json.loads((Path(__file__).parent/'assets/upstream-mcp-contract.json').read_text(encoding='utf-8'))
HANDSHAKE=CONTRACT['handshakeRevisions'];STATELESS=CONTRACT['statelessRevisions'];REVISIONS=STATELESS+HANDSHAKE
VERSION_KEY='io.modelcontextprotocol/protocolVersion';CAPABILITIES_KEY='io.modelcontextprotocol/clientCapabilities'
INFO_KEY='io.modelcontextprotocol/serverInfo';SUBSCRIPTION_KEY='io.modelcontextprotocol/subscriptionId'
TOOLS={tool['name']:tool for tool in CONTRACT['tools']}
MESSAGES={-32700:'Parse error',-32600:'Invalid Request',-32601:'Method not found',-32602:'Invalid params',-32022:'Unsupported protocol version'}
INSTRUCTIONS=CONTRACT['instructions'].replace("at the Mac's notch","in the Windows HUD")


def line(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False)


def parse(value):
    if isinstance(value,bytes):value=value.decode('utf-8')
    def invalid(value):raise ValueError('Non-JSON number: '+value)
    def number(text):
        scientific='e' in text.lower()
        if not scientific and ('.' not in text or not set(text.split('.')[1])-{'0'}):
            integer=int(text.split('.')[0])
            if -(2**63)<=integer<2**63:return integer
        result=float(text)
        if not math.isfinite(result):raise ValueError('Nonfinite number')
        if scientific and result.is_integer() and -(2**63)<=result<2**63:return int(result)
        return result
    def validate(value):
        pending=[(value,0)]
        while pending:
            item,depth=pending.pop()
            if depth>=512:raise ValueError('JSON nesting limit')
            if isinstance(item,str):item.encode('utf-8')
            elif isinstance(item,dict):
                for key,member in item.items():key.encode('utf-8');pending.append((member,depth+1))
            elif isinstance(item,list):pending.extend((member,depth+1) for member in item)
    def first(pairs):
        result={}
        for key,item in pairs:
            key.encode('utf-8')
            if key in result:validate(item)
            else:result[key]=item
        return result
    result=json.loads(value,parse_constant=invalid,parse_int=number,parse_float=number,object_pairs_hook=first)
    validate(result)
    return result


def error(code,identifier=None,message=None,data=None):
    failure={'code':code,'message':message or MESSAGES[code]}
    if data is not None:failure['data']=data
    return dict(jsonrpc='2.0',id=identifier,error=failure)


def validate_reply(reply):
    if not isinstance(reply,dict):return None
    if reply.get('state') in ('off','notRunning','unanswered'):return reply
    if reply.get('ok') is False and isinstance(reply.get('error'),str):return reply
    if reply.get('ok') is not True or not isinstance(reply.get('result'),dict):return None
    images=reply.get('images',[])
    if not isinstance(images,list):return None
    for image in images:
        if not isinstance(image,dict) or not isinstance(image.get('mimeType'),str) or not image['mimeType'] or not isinstance(image.get('data'),str):return None
        try:base64.b64decode(image['data'],validate=True)
        except (ValueError,TypeError):return None
    return reply


class LineBuffer:
    def __init__(self,limit=4*1024*1024):self.limit=limit;self.pending=bytearray()
    def take(self,data):
        result=[]
        for part in data.split(b'\n')[:-1]:
            self.pending.extend(part[:max(0,self.limit-len(self.pending))]);result.append(bytes(self.pending).removesuffix(b'\r'));self.pending.clear()
        part=data.rsplit(b'\n',1)[-1];self.pending.extend(part[:max(0,self.limit-len(self.pending))])
        return result
    def rest(self):
        result=bytes(self.pending).removesuffix(b'\r') if self.pending else None;self.pending.clear();return result


class Server:
    def __init__(self,version,call):self.version=version;self.call=call
    @property
    def info(self):return dict(name='agent-hud',title='Agent HUD',version=self.version)
    @property
    def capabilities(self):return {'tools':{'listChanged':False}}
    def response(self,result,identifier,stateless=False):
        result=deepcopy(result)
        if stateless:
            result.setdefault('_meta',{})[INFO_KEY]=self.info;result['resultType']='complete'
        return dict(jsonrpc='2.0',id=identifier,result=result)
    @staticmethod
    def cacheable(result):return {**result,'ttlMs':300000,'cacheScope':'public'}
    def lines(self,raw):
        if isinstance(raw,str):raw=raw.encode('utf-8')
        if not raw.strip(b' \t\r'):return []
        try:message=parse(raw)
        except (ValueError,UnicodeError,RecursionError):return [line(error(-32700))]
        if isinstance(message,list):
            if not message:return [line(error(-32600))]
            answers=[answer for item in message for answer in self.answers(item)]
            notifications=[answer for answer in answers if 'method' in answer]
            responses=[answer for answer in answers if 'method' not in answer]
            return [line(answer) for answer in notifications+([responses] if responses else [])]
        return [line(answer) for answer in self.answers(message)]
    def answers(self,message):
        if not isinstance(message,dict):return [error(-32600)]
        identifier=message.get('id');has_id='id' in message
        if has_id and not (isinstance(identifier,str) or type(identifier) is int and -(2**63)<=identifier<2**63):
            return [error(-32600,message='Invalid Request: id must be a string or an integer')]
        if message.get('jsonrpc')!='2.0' or not isinstance(message.get('method'),str):
            if 'method' not in message and ('result' in message or 'error' in message):return []
            return [error(-32600,identifier)]
        if not has_id:return []
        params=message.get('params')
        if params is None:params={}
        if not isinstance(params,dict):return [error(-32602,identifier,'Invalid params: params must be an object')]
        return self.method(message['method'],params,identifier)
    def method(self,method,params,identifier):
        if method=='initialize':
            requested=params.get('protocolVersion');revision=requested if requested in HANDSHAKE else HANDSHAKE[0]
            return [self.response(dict(protocolVersion=revision,capabilities=self.capabilities,serverInfo=self.info,instructions=INSTRUCTIONS),identifier)]
        meta=params.get('_meta');meta=meta if isinstance(meta,dict) else {}
        carries=VERSION_KEY in meta or CAPABILITIES_KEY in meta
        stateless=False
        if carries or method in ('server/discover','subscriptions/listen'):
            requested=meta.get(VERSION_KEY)
            if not isinstance(requested,str):return [error(-32602,identifier,'Invalid params: _meta needs '+VERSION_KEY)]
            if requested not in HANDSHAKE:
                if requested not in STATELESS:return [error(-32022,identifier,data=dict(supported=REVISIONS,requested=requested))]
                if not isinstance(meta.get(CAPABILITIES_KEY),dict):return [error(-32602,identifier,'Invalid params: _meta needs '+CAPABILITIES_KEY)]
                stateless=True
        if method=='ping':return [self.response({},identifier,stateless)]
        if method=='server/discover' and stateless:
            return [self.response({**self.cacheable(dict(supportedVersions=REVISIONS)), 'capabilities':self.capabilities,'instructions':INSTRUCTIONS},identifier,True)]
        if method=='tools/list':
            if params.get('cursor') is not None:return [error(-32602,identifier,'Invalid params: unknown cursor')]
            result={'tools':list(TOOLS.values())}
            return [self.response(self.cacheable(result) if stateless else result,identifier,stateless)]
        if method=='tools/call':return [self.tool(params,identifier,stateless)]
        if method=='subscriptions/listen' and stateless:
            tag={SUBSCRIPTION_KEY:identifier}
            return [dict(jsonrpc='2.0',method='notifications/subscriptions/acknowledged',params={'_meta':tag,'notifications':{}}),self.response({'_meta':tag},identifier,True)]
        return [error(-32601,identifier,'Method not found: '+method)]
    def tool(self,params,identifier,stateless):
        name=params.get('name')
        if not isinstance(name,str):return error(-32602,identifier,"Invalid params: tools/call needs the tool's name")
        if name not in TOOLS:return error(-32602,identifier,'Unknown tool: '+name)
        arguments=params.get('arguments')
        if arguments is None:arguments={}
        if not isinstance(arguments,dict):return error(-32602,identifier,'Invalid params: arguments must be an object')
        text='Agent HUD did not answer. Try again.';failed=True;images=[]
        try:
            answer=validate_reply(self.call(dict(tool=name,arguments=arguments))) or {'state':'unanswered'}
            state=answer.get('state') if isinstance(answer,dict) else None
            if state=='off':text="Agent HUD's agent tools are off. Turn them on in Settings › Experimental."
            elif state=='notRunning':text='Agent HUD is not running. Open Agent HUD and try again.'
            elif answer.get('ok') is True and isinstance(answer.get('result'),dict):
                try:text=line(answer['result']);images=answer.get('images',[]);failed=False
                except (ValueError,TypeError):text="Agent HUD's answer could not be read. Try again."
            elif answer.get('ok') is False and isinstance(answer.get('error'),str):text=answer['error']
        except Exception:pass  # IO faults cannot corrupt the JSON-RPC stream.
        content=[dict(type='text',text=text)]
        if not failed:
            content.extend(dict(type='image',mimeType=picture['mimeType'],data=picture['data']) for picture in images)
        return self.response(dict(content=content,isError=failed),identifier,stateless)


def serve(stdin,stdout,server):
    buffer=LineBuffer();read=getattr(stdin,'read1',stdin.read)
    try:
        while chunk:=read(65536):
            for message in buffer.take(chunk):
                for answer in server.lines(message):stdout.write(answer.encode('utf-8')+b'\n');stdout.flush()
        rest=buffer.rest()
        if rest is not None:
            for answer in server.lines(rest):stdout.write(answer.encode('utf-8')+b'\n');stdout.flush()
    except (BrokenPipeError,ConnectionResetError):return
