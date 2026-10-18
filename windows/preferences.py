"""Persisted Windows counterparts of Settings / ScreenPlacement / PanelSwitches."""
from copy import deepcopy
from source_design import DESIGN

DEFAULTS=dict(mode='simple',glass=True,separates_agents=True,size=DESIGN['simple_size'],
    ring_width=DESIGN['ring_width'],edge='top',offset=.5,placements={},
    show_rings=True,show_numbers=True,show_logos=True,logo_size=20,logo_gap=.4,edge_distance=2,
    gap=.45,hud_appearance='dark',glass_style='material',transparency=50,
    appearance='system',match_screen=False,language='zh',launch_at_login=False,client_hooks=True,
    enabled_clients=['Codex','Cursor'],show_tray=True,hover_delay=400,collapse_delay=200,
    requires_alt=False,immediate_top=False,panel_quota=True,panel_tokens=True,
    panel_sessions=True,reset_countdown=True,panel_width=540,session_limit=5,
    glow_style='blur',glow_effect='breathe',glow_brightness=.9,glow_range=14,glow_blur=8,
    glow_outward=True,glow_working=3,glow_idle=7,glow_depth=.6,grid_pitch=10,
    grid_density=1,grid_core=0,grid_fade=5)

RANGES=dict(size=(20,60),ring_width=(1,4),offset=(0,1),logo_size=(20,60),logo_gap=(.1,.6),
    edge_distance=(0,20),gap=(.1,.6),transparency=(0,100),hover_delay=(0,1500),collapse_delay=(0,1500),
    panel_width=(480,720),session_limit=(1,20),glow_brightness=(.2,1),glow_range=(0,36),glow_blur=(0,36),
    glow_working=(1,12),glow_idle=(1,24),glow_depth=(0,1),grid_pitch=(4,12),grid_density=(.5,1.5),grid_core=(0,8),grid_fade=(0,8))
CHOICES=dict(mode=('notch','logos','simple'),edge=('top','right','bottom','left'),
    hud_appearance=('dark','light','system'),appearance=('dark','light','system'),language=('zh','en','system'),
    glass_style=('clear','regular','material'),glow_style=('blur','dots','ascii','blocks','braille','binary'),
    glow_effect=('breathe','flow','scan','ripple','shimmer','boot'))


def validate(key,value):
    if key not in DEFAULTS:raise ValueError('Unknown setting: '+key)
    if key in RANGES:
        import math
        n=float(value)
        if not math.isfinite(n):raise ValueError('Nonfinite setting')
        low,high=RANGES[key]
        return max(low,min(high,n))
    if key in CHOICES:
        if value not in CHOICES[key]:raise ValueError('Invalid choice')
        return value
    if isinstance(DEFAULTS[key],bool):
        if not isinstance(value,bool):raise ValueError('Boolean setting required')
    if key=='enabled_clients':return [c for c in ('Codex','Cursor') if c in value]
    return value


def load(saved):
    result=deepcopy(DEFAULTS)
    if not isinstance(saved,dict):return result
    for key,value in saved.items():
        if key not in DEFAULTS:continue
        try:
            if key=='placements':
                result[key]={screen:{k:validate(k,v) for k,v in fields.items() if k in DEFAULTS and k!='placements'}
                             for screen,fields in value.items() if isinstance(fields,dict)}
            else:result[key]=validate(key,value)
        except (ValueError,TypeError,AttributeError):continue
    return result
