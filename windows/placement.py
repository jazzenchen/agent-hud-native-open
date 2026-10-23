"""Windows coordinates for NotchGeometry's edge/normalized-offset placement."""
def nearest_placement(x,y,screen,extent=(0,0),current_edge='top',grab_fraction=.5):
    left,top,width,height=screen
    edge=min(dict.fromkeys((current_edge,'top','right','bottom','left')),key=lambda e:{
        'top':abs(y-top),'right':abs(x-left-width),
        'bottom':abs(y-top-height),'left':abs(x-left)}[e])
    run=extent[0] if current_edge in ('top','bottom') else extent[1]
    length=width if edge in ('top','bottom') else height
    run=min(run,length);travel=length-run
    coordinate=x-left if edge in ('top','bottom') else y-top
    offset=(coordinate-run*grab_fraction)/travel if travel>0 else .5
    return dict(edge=edge,offset=max(0,min(1,offset)))


def group_origin(screen,extent,edge='top',offset=.5,margin=3):
    left,top,width,height=screen
    w,h=extent
    if edge in ('top','bottom'):
        x=left+max(0,width-w)*offset
        return x,top+margin if edge=='top' else top+height-h-margin
    y=top+max(0,height-h)*offset
    return (left+margin if edge=='left' else left+width-w-margin),y
