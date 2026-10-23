"""Windows-only replacement for HUDSurface/JoinedGlass's native backdrop."""
import os
from look_logic import dimming


class PanelFrost:
    """Bounded in-memory backdrop, clipped by the same path as panel content.

    Windows Accent blur ignores rounded layered-window regions. Sample before
    showing the panel instead; keep it still throughout a morph (no capture of
    the panel itself, no screen polling or files). Refresh on the next opening.
    """
    def __init__(self):
        self.image=None
        self.origin=None

    def capture(self,screen,bounds):
        from PySide6.QtCore import Qt,QRectF
        from PySide6.QtGui import QImage,QPainter
        from PySide6.QtWidgets import QGraphicsScene,QGraphicsPixmapItem,QGraphicsBlurEffect
        self.image=None
        bounds=bounds.adjusted(-32,-32,32,32).intersected(screen.geometry())
        # QScreen's desktop capture offsets are relative to that screen,
        # including monitors whose virtual-desktop origin is negative.
        pixmap=screen.grabWindow(0,bounds.x()-screen.geometry().x(),bounds.y()-screen.geometry().y(),bounds.width(),bounds.height())
        if pixmap.isNull():return False
        # Work in logical pixels; the source pixmap retains its device ratio.
        scene=QGraphicsScene();item=QGraphicsPixmapItem(pixmap)
        blur=QGraphicsBlurEffect();blur.setBlurRadius(24)
        blur.setBlurHints(QGraphicsBlurEffect.BlurHint.QualityHint)
        item.setGraphicsEffect(blur);scene.addItem(item)
        image=QImage(pixmap.size(),QImage.Format.Format_ARGB32_Premultiplied)
        image.setDevicePixelRatio(pixmap.devicePixelRatio());image.fill(Qt.GlobalColor.transparent)
        painter=QPainter(image)
        scene.render(painter,QRectF(0,0,bounds.width(),bounds.height()),QRectF(0,0,bounds.width(),bounds.height()))
        painter.end();self.image=image;self.origin=bounds.topLeft()
        return True

    def paint(self,painter,widget,path):
        if self.image is None:return False
        painter.save();painter.setClipPath(path)
        painter.drawImage(self.origin-widget.pos(),self.image)
        painter.restore();return True

    def covers(self,bounds):
        if self.image is None:return False
        from PySide6.QtCore import QRect
        return QRect(self.origin,self.image.deviceIndependentSize().toSize()).contains(bounds)

    def clear(self):self.image=None;self.origin=None


def frosted_backdrop(handle, enabled=True, transparency=50, light=False, style='material'):
    if os.name != 'nt':
        return False
    import ctypes
    from ctypes import wintypes

    class Accent(ctypes.Structure):
        _fields_ = [('state', ctypes.c_int), ('flags', ctypes.c_int),
                    ('gradient', ctypes.c_uint), ('animation', ctypes.c_int)]

    class Data(ctypes.Structure):
        _fields_ = [('attribute', ctypes.c_int), ('data', ctypes.c_void_p), ('size', ctypes.c_size_t)]

    try:
        # The original pre-Liquid-Glass path separates FrostedGlass from its
        # dimming layer. Do the same: native blur only, with the themed dimming
        # painted inside Qt's capsule. Acrylic's native gradient ignores custom
        # regions and left a rectangular tint outside the requested silhouette.
        accent = Accent(3 if enabled else 0,0,0,0)
        data = Data(19, ctypes.addressof(accent), ctypes.sizeof(accent))
        user = ctypes.WinDLL('user32', use_last_error=True)
        function = user.SetWindowCompositionAttribute
        function.argtypes = (wintypes.HWND, ctypes.POINTER(Data))
        function.restype = wintypes.BOOL
        return bool(function(int(handle), ctypes.byref(data)))
    except (AttributeError, OSError):
        return False

def rounded_native_window(widget,radius):
    """Let Qt's shape mask own clipping; suppress DWM's second frame/radius."""
    if os.name!='nt' or getattr(widget,'preview',getattr(getattr(widget,'meter',None),'preview',False)):return
    from PySide6.QtWidgets import QApplication
    if QApplication.platformName()=='offscreen':return
    import ctypes
    from ctypes import wintypes
    try:
        handle=int(widget.winId());dwm=ctypes.WinDLL('dwmapi')
        dwm.DwmSetWindowAttribute.argtypes=[wintypes.HWND,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD]
        # The custom region owns the silhouette. A second DWM corner treatment
        # can round an already rounded layered surface with a different radius.
        border=wintypes.DWORD(0xfffffffe);corners=wintypes.DWORD(1)
        dwm.DwmSetWindowAttribute(handle,34,ctypes.byref(border),ctypes.sizeof(border))
        dwm.DwmSetWindowAttribute(handle,33,ctypes.byref(corners),ctypes.sizeof(corners))
        # QWidget.setMask already updates the physical HWND region, with Qt's
        # fractional-DPI rounding. A second CreateRoundRectRgn disagreed with
        # that mask at small sizes and exposed a 1px rim during collapse.
    except (OSError,AttributeError):pass
