"""Read-only translation of TencentBuddy/WorkBuddyMetering.swift.

Metered credits are session spending, never a subscription or remaining balance.
The source's model-set intersection avoids inventing attribution.
"""
import json,math,sqlite3,time
from pathlib import Path
from providers import read_db


def entry_models(entries,models):
    result={}
    for key in {key for record in entries.values() for key in record}:
        shared=None
        for sid,record in entries.items():
            if key not in record or sid not in models:continue
            shared=set(models[sid]) if shared is None else shared.intersection(models[sid])
            if not shared:break
        if shared is not None and len(shared)==1:result[key]=next(iter(shared))
    return result


def read(database,sessions,models):
    titles={};credits={};ids=list(dict.fromkeys(str(row['id']) for row in sessions))
    if not ids or not Path(database).is_file():return titles,credits
    # Only the sessions being reported are queried; never enumerate all history.
    ids_json=json.dumps(ids)
    try:
        with read_db(Path(database)) as db:
            deadline=time.monotonic()+1
            db.set_progress_handler(lambda:int(time.monotonic()>deadline),1000)
            try:
                for sid,custom,title in db.execute('SELECT id,custom_title,title FROM sessions WHERE id IN (SELECT value FROM json_each(?))',(ids_json,)):
                    name=next((v.strip().splitlines()[0][:100] for v in (custom,title) if isinstance(v,str) and v.strip() and v not in ('(No content)','/compact')),None)
                    if name:titles[str(sid)]=name
            except sqlite3.Error:pass
            if not models:return titles,credits
            entries={};contexts={}
            try:
                for sid,used,size,raw in db.execute("SELECT session_id,used,size,credit_json FROM session_usage WHERE credit_json IS NOT NULL AND credit_json!='' AND session_id IN (SELECT value FROM json_each(?))",(ids_json,)):
                    if not isinstance(raw,str) or len(raw)>1024*1024:continue
                    try:
                        value=json.loads(raw)
                        if not isinstance(value,dict) or any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or v<0 for v in value.values()):continue
                        used,size=int(used),int(size)
                        if used<0 or size<0:continue
                    except (ValueError,TypeError,RecursionError):continue
                    entries[str(sid)]=value;contexts[str(sid)]=(used,size)
            except sqlite3.Error:return titles,credits
            keyed=entry_models(entries,models)
            for sid,entries_for_session in entries.items():
                by_model={};unattributed=0.
                for key,value in entries_for_session.items():
                    if key in keyed:
                        model='workbuddy-model:'+keyed[key];by_model[model]=by_model.get(model,0)+value
                    else:unattributed+=value
                total=sum(entries_for_session.values())
                if not math.isfinite(total):continue
                used,size=contexts[sid]
                credits[sid]=dict(total=total,unattributed=unattributed,byModel=by_model,used=used,size=size)
    except (OSError,sqlite3.Error):pass
    return titles,credits
