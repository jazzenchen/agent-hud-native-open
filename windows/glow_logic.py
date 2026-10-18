"""Platform-independent port of upstream GlowMotion/GlowMatrix math.

Source: Sources/AgentHUDDesktop/Notch/Glow/{GlowMotion,GlowMatrix}.swift.
The Qt adapter only supplies cells and paints the returned gains.
"""
from math import cos,sin,pi,exp,log,floor

PERIODS=dict(breathe=3.,scan=2.6,ripple=1.8,flow=6.,boot=4.4,shimmer=3.)
BAYER=(0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5)

def fraction(value):return value-floor(value)
def noise(column,row,step):return fraction(sin(column*12.9898+row*78.233+step*37.719)*43758.5453)
def strength(distance,pitch,core,fade):
    cells=distance/pitch
    if cells<=max(0,core):return 1.
    t=(cells-max(0,core))/max(.01,fade)
    return exp(-log(1.2/.06)*t*t) if t<=1 else 0.

def gain(effect,seconds,period,x,distance,pitch,width,depth,column=0,row=0):
    t=seconds*PERIODS[effect]/max(.25,period)
    if effect=='breathe':return 1-min(1,max(0,depth))*(.5-.5*cos(2*pi*t/3))
    if effect=='flow':return 1.
    if effect=='scan':
        margin=80/14*pitch;center=fraction(t/2.6)*(width+2*margin)-margin
        return .5+.7*exp(-((x-center)/(40/14*pitch))**2)
    if effect=='ripple':return .55+.45*(.5+.5*sin(2*pi*(distance/(3*pitch)-t/1.8)))
    if effect=='shimmer':
        step=floor(t*8)
        return 1.2 if noise(column,row,step+53)<.12 else .5+.3*noise(column,row,step)
    phase=t%4.4
    if phase<2.2:return float(distance<phase/2.2*8*pitch)
    return 1. if phase<3.6 else 1-(phase-3.6)/.8

def sheen(seconds,period,location):
    t=seconds*6/max(.25,period)
    offset=(location-(fraction(t/6)*1.5-.25))/.25
    return cos(offset*pi/2)**2 if abs(offset)<1 else 0.

def distance(x,y,width,height,radius):
    """Rounded rectangle signed distance; y-down Windows coordinates."""
    radius=max(0,min(radius,width/2,height/2))
    dx=abs(x-width/2)-(width/2-radius)
    dy=abs(y-height/2)-(height/2-radius)
    return (max(dx,0)**2+max(dy,0)**2)**.5+min(max(dx,dy),0)-radius
