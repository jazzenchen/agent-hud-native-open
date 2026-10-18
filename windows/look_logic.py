"""Pure HUDLook/ScreenPlacement opacity rules; no platform window APIs."""
def drawn_transparency(value,glass,style):
    return max(0,min(100,value))/100*(1 if glass and style=='material' else .6)

def dimming(value,glass=True,style='material'):
    return 1-drawn_transparency(value,glass,style)

def stand_in(value,glass=True,style='material'):
    opacity=dimming(value,glass,style)
    return .35+.65*opacity if glass else opacity
