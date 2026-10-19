"""PanelLayoutPlan / PanelLines translated from the unchanged original core."""
from copy import deepcopy
from panel_layout import normalize,unique,MEASURES

SIDE_INSETS=36.
CELL_INSET=6.
CELL_GAP=8.
NARROWEST_CONTENT=440.-SIDE_INSETS


def cell_width(width,columns):return (width-2*CELL_INSET-(max(1,columns)-1)*CELL_GAP)/max(1,columns)


NARROWEST_CELL=cell_width(NARROWEST_CONTENT,6)
WIDEST_HEADING=20.+6+96+6+8+6+86+2
NARROWEST_HALF=max(WIDEST_HEADING,2*cell_width(480.-SIDE_INSETS,4)+2*CELL_INSET+CELL_GAP)


def columns_fitting(width):
    return next((n for n in range(6,1,-1) if cell_width(width,n)>=NARROWEST_CELL),2)


def spacing_metrics(spacing='regular'):
    values={'compact':(6,6,5,5,2,6,1,2,4),'regular':(10,10,8,8,4,10,2,4,6),
            'roomy':(14,14,11,11,6,14,3,6,8)}[spacing]
    return dict(zip(('sections','blocks','divided','blockParts','rowPadding','cellLines','cellPadding','chartTop','sessionRows'),values))


def block_plan(key,kind,change,countdown=True,token_period='day'):
    if kind not in ('quota','billing'):raise ValueError('Unknown block kind')
    widgets=('bar','ring','number','chart') if kind=='quota' else ('number','chart')
    widget=change.get('widget') if change.get('widget') in widgets else widgets[0]
    offered=['tokens' if kind=='quota' else 'cost'] if widget=='chart' else list(MEASURES)
    measures=[value for value in change.get('measures',[]) if value in offered] or offered
    cells=kind=='quota' and widget in ('ring','number')
    return dict(key=key,kind=kind,widget=widget,measures=measures,hiddenRows=[],rows=[],accounts=change.get('accounts',[]),
                countdown=change.get('countdown',countdown) if kind=='quota' else True,
                columns=change.get('columns',4) if cells else 4,
                ringSize=change.get('ringSize','medium') if kind=='quota' and widget=='ring' else 'medium',
                span='half' if widget!='bar' and change.get('span')=='half' else 'full',
                period=change.get('period','day' if kind=='quota' else token_period) if widget=='chart' or kind=='billing' else 'day')


def plan(layout,blocks,content_width=None,pairs=True):
    layout=normalize(layout);existing={}
    for block in blocks:existing.setdefault(block['key'],block)
    order=unique([key for key in layout.get('order',[]) if key in existing]+[block['key'] for block in blocks])
    planned=[]
    for key in order:
        block=existing[key];change=layout.get('blocks',{}).get(key,{})
        if change.get('hidden'):continue
        drawn=block_plan(key,block['kind'],change,layout.get('countdown',True),layout.get('tokens',{}).get('period','day'))
        accounts=[account for account in block.get('accounts',[]) if not drawn['accounts'] or account['id'] in drawn['accounts']]
        if drawn['accounts'] and not accounts:continue
        row_keys=set(block.get('rowKeys',[]));kept=row_keys if not drawn['accounts'] else {row for account in accounts for row in account.get('rowKeys',[])}
        drawn['hiddenRows']=sorted(row_keys.intersection(change.get('hiddenRows',[])))
        drawn['rows']=[row for row in change.get('rows',[]) if row in row_keys]
        if row_keys and not kept.difference(drawn['hiddenRows']):continue
        planned.append(drawn)
    width=layout.get('style',{}).get('width',540)-SIDE_INSETS if content_width is None else content_width
    half=(width-spacing_metrics(layout.get('style',{}).get('spacing','regular'))['blocks'])/2
    halves_fit=bool(pairs and half>=NARROWEST_HALF);lines=[];index=0
    while index<len(planned):
        paired=index+1<len(planned) and planned[index]['span']=='half' and planned[index+1]['span']=='half'
        if paired and halves_fit:
            line=deepcopy(planned[index:index+2])
            for block in line:
                if block['kind']=='quota' and block['widget'] in ('ring','number'):
                    asked=layout.get('blocks',{}).get(block['key'],{}).get('columns',2)
                    block['columns']=min(asked,columns_fitting(half))
            lines.append(line);index+=2
        else:
            block=deepcopy(planned[index]);block['span']='full';lines.append([block]);index+=1
    sections=[section for section in layout.get('sections',['blocks','tokens','sessions']) if section not in layout.get('hiddenSections',[])]
    return dict(halvesFit=halves_fit,sections=sections,lines=lines)


def grid_geometry(heights,width,columns=4,spacing='regular'):
    """QuotaCellGrid: partial last line keeps column width and is centred."""
    metrics=spacing_metrics(spacing);result=[];y=metrics['cellPadding'];usable=width-2*CELL_INSET
    lines=[heights[index:index+columns] for index in range(0,len(heights),columns)]
    for line_index,line in enumerate(lines):
        count=columns if len(lines)>1 else len(line)
        cell=max(0,(usable-(count-1)*CELL_GAP)/max(1,count));used=len(line)*cell+max(0,len(line)-1)*CELL_GAP
        start=CELL_INSET+(usable-used)/2
        for index,height in enumerate(line):result.append(dict(x=start+index*(cell+CELL_GAP),y=y,width=cell,height=height,line=line_index))
        y+=max(line,default=0)+metrics['cellLines']
    return result,(y-metrics['cellLines'] if lines else y)+metrics['cellPadding']
