"""Source translation of PanelLayout/Filters/HUD and saved layout documents.

No providers, credentials, Qt, or implicit writes. Stored JSON is forgiving by
field; proposals are validated separately by the MCP host. Drafts never persist.
An optional writer commits the entire saved value before memory advances, so a
failed disk write cannot claim Save succeeded or destroy the pending draft.
"""
from copy import deepcopy
import math
import time

SECTIONS=('blocks','tokens','sessions')
MEASURES=('quota','burn','tokens','consumed','cost')
SWITCHES={'panel_quota':'blocks','panel_tokens':'tokens','panel_sessions':'sessions','reset_countdown':None}
SHARED='shared'


def mark(vendor):
    return {'Codex':'ChatGPT','Grok CLI':'Grok','OpenCode Go':'OpenCode','OpenCode-dark':'OpenCode',
            'Qoder CN':'Qoder','QoderWork':'Qoder','Qoder-dark':'Qoder'}.get(vendor,vendor)


def strings(value):return [x for x in value if isinstance(x,str)] if isinstance(value,list) else []
def unique(values):return list(dict.fromkeys(x for x in values if x!=''))
def merged(values):
    seen=set();out=[]
    for name in values:
        key=mark(name)
        if name and key not in seen:seen.add(key);out.append(name)
    return out


def count(value,low,high):
    if isinstance(value,bool) or not isinstance(value,(int,float)):return None
    if not low<=value<=high or not math.isfinite(value) or value!=int(value):return None
    return int(value)


def normalize(value):
    """Canonical source JSON. Preserve unavailable block/row/account keys."""
    if not isinstance(value,dict):raise ValueError('A panel layout is a JSON object')
    result={};blocks={}
    for key,fields in (value.get('blocks') if isinstance(value.get('blocks'),dict) else {}).items():
        if not isinstance(key,str) or not isinstance(fields,dict):continue
        block={}
        for field,allowed in [('widget',('bar','ring','number','chart')),('ringSize',('small','medium','large')),
                              ('span',('full','half')),('period',('day','week','month'))]:
            if isinstance(fields.get(field),str) and fields[field] in allowed:block[field]=fields[field]
        measures=unique('consumed' if x=='tokenTotal' else x for x in strings(fields.get('measures')))
        measures=[x for x in measures if x in MEASURES]
        if measures:block['measures']=measures
        if fields.get('hidden') is True:block['hidden']=True
        for field in ('hiddenRows','rows','accounts'):
            rows=unique(strings(fields.get(field)))
            if field!='rows':rows.sort()
            if rows:block[field]=rows
        if isinstance(fields.get('countdown'),bool):block['countdown']=fields['countdown']
        columns=count(fields.get('columns'),2,6)
        if columns is not None:block['columns']=columns
        if block:blocks[key]=block
    if blocks:result['blocks']=blocks
    order=unique(strings(value.get('order')))
    if order:result['order']=order
    sections=unique([x for x in strings(value.get('sections')) if x in SECTIONS]+list(SECTIONS))
    if sections!=list(SECTIONS):result['sections']=sections
    hidden=[x for x in SECTIONS if x in strings(value.get('hiddenSections'))]
    if hidden:result['hiddenSections']=hidden
    if value.get('countdown') is False:result['countdown']=False
    style=value.get('style');out={}
    if isinstance(style,dict):
        if style.get('spacing') in ('compact','roomy'):out['spacing']=style['spacing']
        if style.get('separators') is False:out['separators']=False
        width=count(style.get('width'),480,720)
        if width is not None and width!=540:out['width']=width
    if out:result['style']=out
    hud=value.get('hud');agents=merged(strings(hud.get('agents'))) if isinstance(hud,dict) else []
    if agents:result['hud']={'agents':agents}
    sessions=value.get('sessions');out={}
    if isinstance(sessions,dict):
        limit=count(sessions.get('limit'),1,10)
        if limit is not None and limit!=5:out['limit']=limit
        if sessions.get('period') in ('week','3d','7d'):out['period']='week'
        if sessions.get('sort')=='date':out['sort']='date'
        agents=sorted(merged(strings(sessions.get('agents'))));projects=sorted(unique(strings(sessions.get('projects'))))
        states=[x for x in ('waiting','running','ended') if x in strings(sessions.get('states'))]
        if agents:out['agents']=agents
        if projects:out['projects']=projects
        if states and len(states)!=3:out['states']=states
    if out:result['sessions']=out
    tokens=value.get('tokens');out={}
    if isinstance(tokens,dict):
        if tokens.get('period') in ('week','month'):out['period']=tokens['period']
        agents=sorted(merged(strings(tokens.get('agents'))));models=sorted(unique(strings(tokens.get('models'))))
        if agents:out['agents']=agents
        if models:out['models']=models
    if out:result['tokens']=out
    return result


def arrange_agents(listed,available):
    """HUDAgentOrder: an absent-only list must never make an empty HUD."""
    keys=unique(mark(x) for x in strings(listed));present={mark(x) for x in available}
    if not present.intersection(keys):return list(available)
    ranks={name:i for i,name in enumerate(keys)}
    return sorted([x for x in available if mark(x) in ranks],key=lambda x:ranks[mark(x)])


def switches(layout):
    return {key:(layout.get('countdown',True) if section is None else section not in layout.get('hiddenSections',[])) for key,section in SWITCHES.items()}


def switching(layout,changes):
    out=deepcopy(layout);hidden=list(out.get('hiddenSections',[]))
    for key,on in changes.items():
        if key not in SWITCHES or not isinstance(on,bool):raise ValueError('Invalid panel switch')
        section=SWITCHES[key]
        if section is None:out['countdown']=on
        else:
            hidden=[x for x in hidden if x!=section]
            if not on:hidden.append(section)
    out['hiddenSections']=hidden
    return normalize(out)


def _choice(value):
    if value==SHARED:return SHARED
    return normalize(value) if isinstance(value,dict) else None


def _document():return dict(current=SHARED,previous=None,draft=None)


class PanelHolds:
    """Source 120-second memory-only holds; expiry does not change revisions."""
    duration=120
    def __init__(self,clock=time.time):self.clock=clock;self._holds={}
    def get(self,screen):
        hold=self._holds.get(screen)
        return deepcopy(hold) if hold and hold['until']>self.clock() else None
    def remaining(self,screen):
        hold=self.get(screen)
        return max(0,hold['until']-self.clock()) if hold else None
    def hold(self,screen,agent=None):
        old=self.get(screen) or {}
        self._holds[screen]=dict(until=self.clock()+self.duration,paused=False,agent=agent if agent is not None else old.get('agent'))
    def pause(self,screen):
        if self.get(screen):self._holds[screen]['paused']=True
    def end(self,screen):self._holds.pop(screen,None)
    def end_all(self):self._holds.clear()
    def expire(self):self._holds={key:row for key,row in self._holds.items() if row['until']>self.clock()}
    @property
    def screens(self):return sorted(key for key in self._holds if self.get(key))


class LayoutStore:
    """Saved/shared/screen layout documents; style/app drafts belong to the host.

    The writer accepts canonical saved JSON or None for no saved value. It must
    commit atomically or raise. Every public reading is a defensive copy.
    """
    def __init__(self,saved=None,writer=None):
        self.writer=writer;self.revision=0;self.holds=PanelHolds()
        root=saved if isinstance(saved,dict) else {};shared=root.get('shared');shared=shared if isinstance(shared,dict) else {}
        self._state=dict(current=normalize(shared.get('current')) if isinstance(shared.get('current'),dict) else {},
            previous=normalize(shared.get('previous')) if isinstance(shared.get('previous'),dict) else None,draft=None,screens={})
        for key,sides in (root.get('screens') if isinstance(root.get('screens'),dict) else {}).items():
            if not isinstance(key,str) or not key or not isinstance(sides,dict):continue
            current=_choice(sides.get('current'));previous=_choice(sides.get('previous'))
            doc=dict(current=SHARED if current is None else current,previous=previous,draft=None)
            if doc['current']!=SHARED or previous is not None:self._state['screens'][key]=doc
    @property
    def current(self):return deepcopy(self._state['current'])
    @property
    def previous(self):return deepcopy(self._state['previous'])
    @property
    def draft(self):return deepcopy(self._state['draft'])
    @property
    def screens(self):return deepcopy(self._state['screens'])
    def effective(self,screen=None):
        state=self._state;doc=state['screens'].get(screen,_document());choice=doc['draft'] if doc['draft'] is not None else doc['current']
        if screen is not None and choice!=SHARED:return deepcopy(choice)
        return deepcopy(state['draft'] if state['draft'] is not None else state['current'])
    def uses_shared(self,screen=None):
        doc=self._state['screens'].get(screen,_document())
        return (doc['draft'] if doc['draft'] is not None else doc['current'])==SHARED
    def own(self,screen):
        choice=self._state['screens'].get(screen,_document())['current']
        return deepcopy(choice) if choice!=SHARED else None
    def draft_scope(self,screen=None):
        if self._state['screens'].get(screen,{}).get('draft') is not None:return ('screen',screen)
        return SHARED if self.uses_shared(screen) and self._state['draft'] is not None else None
    def has_draft(self,screen=None):return self.draft_scope(screen) is not None
    def can_revert(self,screen=None):
        return (self._state['previous'] if screen is None else self._state['screens'].get(screen,{}).get('previous')) is not None
    def saved_switches(self,screen=None):
        own=self.own(screen)
        return switches(self.current if own is None else own)
    @staticmethod
    def _persisted(state):
        root={}
        if state['current'] or state['previous'] is not None:
            root['shared']={'current':deepcopy(state['current'])}
            if state['previous'] is not None:root['shared']['previous']=deepcopy(state['previous'])
        for key,doc in state['screens'].items():
            sides={}
            if doc['current']!=SHARED:sides['current']=deepcopy(doc['current'])
            if doc['previous'] is not None:sides['previous']=deepcopy(doc['previous'])
            if sides:root.setdefault('screens',{})[key]=sides
        return root or None
    def persisted(self):return self._persisted(self._state)
    def _change(self,change):
        proposed=deepcopy(self._state);result=change(proposed)
        proposed['screens']={key:doc for key,doc in proposed['screens'].items() if doc!=_document()}
        if proposed==self._state:return result
        saved=self._persisted(proposed)
        if saved!=self.persisted() and self.writer:self.writer(deepcopy(saved))
        self._state=proposed;self.revision+=1
        return result
    def propose(self,layout,screen=None):
        choice=_choice(layout) if screen is not None else normalize(layout)
        if choice is None:raise ValueError('Invalid screen layout')
        def change(state):
            doc=state if screen is None else state['screens'].setdefault(screen,_document())
            doc['draft']=None if choice==doc['current'] else choice
            return doc['draft'] is not None
        return self._change(change)
    def _end_scope(self,screen):
        for key in self.holds.screens:
            if key==screen or screen is None and self.uses_shared(key):self.holds.end(key)
    def save(self,screen=None):
        self._end_scope(screen)
        def change(state):
            doc=state if screen is None else state['screens'].setdefault(screen,_document())
            if doc['draft'] is not None:doc.update(previous=doc['current'],current=doc['draft'],draft=None)
        self._change(change)
    def discard(self,screen=None):
        def change(state):
            doc=state if screen is None else state['screens'].setdefault(screen,_document());doc['draft']=None
        self._change(change)
    def save_panel(self,screen=None):
        if screen is not None:self.holds.end(screen)
        if self.draft_scope(screen)==SHARED:self.save()
        if screen is not None and self._state['screens'].get(screen,{}).get('draft') is not None:self.save(screen)
    def discard_panel(self,screen=None):
        if screen is not None:self.holds.end(screen)
        if self.draft_scope(screen)==SHARED:self._end_scope(None);self.discard()
        if screen is not None and self._state['screens'].get(screen,{}).get('draft') is not None:self.discard(screen)
    def revert(self,screen=None):
        self._end_scope(screen)
        def change(state):
            doc=state if screen is None else state['screens'].setdefault(screen,_document())
            if doc['previous'] is not None:doc['current'],doc['previous']=doc['previous'],doc['current']
            doc['draft']=None
        self._change(change)
    def reset(self,screen=None):
        self._end_scope(screen)
        def change(state):
            doc=state if screen is None else state['screens'].setdefault(screen,_document())
            if doc['current']!={}:doc['previous']=doc['current']
            doc.update(current={},draft=None)
        self._change(change)
    def use_shared(self,screen):
        self.holds.end(screen)
        def change(state):
            doc=state['screens'].setdefault(screen,_document())
            if doc['current']!=SHARED:doc['previous']=doc['current']
            doc.update(current=SHARED,draft=None)
        self._change(change)
    def set_switches(self,changes,screen=None):
        if any(key not in SWITCHES or not isinstance(on,bool) for key,on in changes.items()):raise ValueError('Invalid panel switch')
        was=self.saved_switches(screen);changed={key:on for key,on in changes.items() if was.get(key)!=on}
        if not changed:return
        def change(state):
            doc=state['screens'].get(screen)
            target=doc if doc and doc['current']!=SHARED else state
            target['current']=switching(target['current'],changed)
            if isinstance(target['draft'],dict):
                drafted=switching(target['draft'],changed);target['draft']=None if drafted==target['current'] else drafted
        self._change(change)

    def edit_field(self,key,value,screen=None):
        """A person's scalar edit reaches the saved document and its draft only."""
        if key in SWITCHES:return self.set_switches({key:value},screen)
        if key not in ('panel_width','session_limit'):raise ValueError('Invalid panel field')
        low,high=(480,720) if key=='panel_width' else (1,10)
        value=count(value,low,high)
        if value is None:raise ValueError('Invalid panel field value')
        def edit(layout):
            layout=deepcopy(layout)
            if key=='panel_width':layout.setdefault('style',{})['width']=value
            else:layout.setdefault('sessions',{})['limit']=value
            return normalize(layout)
        def change(state):
            doc=state['screens'].get(screen);target=doc if doc and doc['current']!=SHARED else state
            target['current']=edit(target['current'])
            if isinstance(target['draft'],dict):
                draft=edit(target['draft']);target['draft']=None if draft==target['current'] else draft
        self._change(change)


def legacy_layout(settings):
    """Carry this Windows port's earlier scalar preferences into source JSON."""
    layout=switching({}, {key:settings.get(key,True) if isinstance(settings.get(key,True),bool) else True for key in SWITCHES})
    width=count(settings.get('panel_width',540),480,720)
    if width is not None:layout['style']={'width':width}
    limit=count(settings.get('session_limit',5),1,20)
    if limit is not None:layout['sessions']={'limit':min(limit,10)}
    return normalize(layout)


def migrate_settings(settings):
    """Read-only migration. It never writes, starts a provider, or forgets style."""
    shared=legacy_layout(settings);root={'shared':{'current':shared}} if shared else {}
    keys=set(SWITCHES)|{'panel_width','session_limit'}
    for screen,fields in settings.get('placements',{}).items():
        if isinstance(fields,dict) and keys.intersection(fields):
            root.setdefault('screens',{})[screen]={'current':legacy_layout({**settings,**fields})}
    return root or None


def effective_settings(settings,layout):
    return {**settings,**switches(layout),
            'panel_width':layout.get('style',{}).get('width',540),
            'session_limit':layout.get('sessions',{}).get('limit',5)}
