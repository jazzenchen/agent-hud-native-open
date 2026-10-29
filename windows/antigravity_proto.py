"""Port of AntigravityProtoReader (CodexBar MIT; see THIRD_PARTY_NOTICES).

Modified for Windows by nanhudev. Unknown fields are skipped; malformed types,
varints, timestamps and lengths are rejected rather than becoming fake counts.
"""
def fields(raw):
    offset=0
    def integer():
        nonlocal offset
        value=0
        for index in range(10):
            if offset>=len(raw):raise ValueError('Truncated protobuf varint')
            byte=raw[offset];offset+=1
            if index==9 and byte>1:raise ValueError('Overflowing protobuf varint')
            value|=(byte&127)<<(index*7)
            if byte<128:return value
        raise ValueError('Invalid protobuf varint')
    while offset<len(raw):
        tag=integer();number=tag>>3;wire=tag&7
        if not 0<number<=536870911:raise ValueError('Invalid protobuf field')
        if wire==0:yield number,wire,integer();continue
        size=integer() if wire==2 else 8 if wire==1 else 4 if wire==5 else None
        if size is None or size>len(raw)-offset:raise ValueError('Invalid protobuf field length')
        value=raw[offset:offset+size];offset+=size;yield number,wire,value


def typed(wire,value,expected):
    if wire!=expected:raise ValueError('Unexpected protobuf field type')
    if expected==0 and value>9223372036854775807:raise ValueError('Counter overflow')
    return value.decode('utf-8') if expected==2 else value


def timestamp(raw):
    parts={}
    for number,wire,value in fields(raw):
        if number in (1,2):parts[number]=typed(wire,value,0)
    if 1 not in parts:return None
    if not 0<parts[1]<=253402300799 or parts.get(2,0)>999999999:raise ValueError('Invalid protobuf timestamp')
    return parts[1]+parts.get(2,0)/1e9


def turn(raw):
    result=dict(usage={},model=None,label=None,execution=None,at=None,message=None);times=[];bad_message=False
    for number,wire,value in fields(raw):
        if number==4:result['execution']=typed(wire,value,2)
        if number!=1:continue
        if wire!=2:raise ValueError('Invalid chat metadata')
        for n,w,v in fields(value):
            if n in (19,21):result['model' if n==19 else 'label']=typed(w,v,2)
            elif n==3:result['requested_model']=typed(w,v,0)
            elif n==4:
                if w!=2:raise ValueError('Invalid usage envelope')
                for key,t,item in fields(v):
                    labels={1:'model_id',2:'input',3:'output',4:'cache_write',5:'cache',9:'reasoning',10:'response_output'}
                    if key in labels:result['usage'][labels[key]]=typed(t,item,0)
                    elif key==11:result['response']=typed(t,item,2)
                    elif key==7:
                        try:
                            decoded=typed(t,item,2)
                            if not bad_message:result['message']=decoded
                        except (ValueError,UnicodeError):bad_message=True;result['message']=None
            elif n==9:
                if w!=2:raise ValueError('Invalid start metadata')
                for key,t,item in fields(v):
                    if key==4:
                        if t!=2:raise ValueError('Invalid timestamp envelope')
                        times.append(item)
    result['at']=timestamp(b''.join(times)) if times else None
    return result


def step(raw):
    result=dict(at=None,message=None,execution=None);times=[];bad_message=False
    for n,w,v in fields(raw):
        if n==1:
            if w!=2:raise ValueError('Invalid step timestamp')
            times.append(v)
        elif n==12:result['execution']=typed(w,v,2)
        elif n==9 and w==2:
            for key,t,item in fields(v):
                if key==7:
                    try:
                        decoded=typed(t,item,2)
                        if not bad_message:result['message']=decoded
                    except (ValueError,UnicodeError):bad_message=True;result['message']=None
    result['at']=timestamp(b''.join(times)) if times else None
    return result
