"""Windows continuous-corner counterpart for SwiftUI rounded panel surfaces.

Two symmetric cubic segments per corner join with continuous second derivatives
and zero curvature at the straight edges. This is an explicit Qt approximation,
not a claim to reproduce Apple's private continuous-rectangle implementation.
Capsules retain circular ends, as the upstream capsule views do.
"""
import math
from PySide6.QtCore import QRectF
from PySide6.QtGui import QPainterPath


def surface_path(rect,radius):
    rect=QRectF(rect);path=QPainterPath()
    if rect.isEmpty():return path
    limit=min(rect.width(),rect.height())/2
    radius=max(0.,min(float(radius),limit))
    if radius<=0:path.addRect(rect);return path
    if math.isclose(radius,limit,abs_tol=.01):
        path.addRoundedRect(rect,radius,radius);return path
    # The smooth section has a longer shoulder than a circular fillet while
    # keeping the nominal source radius and rectangle bounds authoritative.
    r=min(radius*1.5,limit);a=(1-2**(-.25))*r
    l,t,b,right=rect.left(),rect.top(),rect.bottom(),rect.right()
    path.moveTo(l+r,t);path.lineTo(right-r,t)
    path.cubicTo(right-4*a,t,right-2*a,t,right-a,t+a)
    path.cubicTo(right,t+2*a,right,t+4*a,right,t+r)
    path.lineTo(right,b-r)
    path.cubicTo(right,b-4*a,right,b-2*a,right-a,b-a)
    path.cubicTo(right-2*a,b,right-4*a,b,right-r,b)
    path.lineTo(l+r,b)
    path.cubicTo(l+4*a,b,l+2*a,b,l+a,b-a)
    path.cubicTo(l,b-2*a,l,b-4*a,l,b-r)
    path.lineTo(l,t+r)
    path.cubicTo(l,t+4*a,l,t+2*a,l+a,t+a)
    path.cubicTo(l+2*a,t,l+4*a,t,l+r,t)
    path.closeSubpath();return path
