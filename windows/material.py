"""Windows-only replacement for HUDSurface/JoinedGlass's native backdrop."""
import os
from look_logic import dimming


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
        # Retain the original HUDLook dimming semantics; only the compositor changes.
        alpha=max(1,round(255*dimming(transparency,True,style)))
        # GradientColor is ABGR. Legacy state 3 ignores the tint and leaves light
        # surfaces dark; all glass styles use the tinted Acrylic compositor here.
        rgb=0x00f7f5f5 if light else 0
        accent = Accent(4 if enabled else 0, 0, (alpha<<24)|rgb, 0)
        data = Data(19, ctypes.addressof(accent), ctypes.sizeof(accent))
        user = ctypes.WinDLL('user32', use_last_error=True)
        function = user.SetWindowCompositionAttribute
        function.argtypes = (wintypes.HWND, ctypes.POINTER(Data))
        function.restype = wintypes.BOOL
        return bool(function(int(handle), ctypes.byref(data)))
    except (AttributeError, OSError):
        return False

def rounded_native_window(widget,radius):
    """Clip the compositor as well as Qt paint, and remove DWM's external border."""
    if os.name!='nt' or getattr(widget,'preview',getattr(getattr(widget,'meter',None),'preview',False)):return
    from PySide6.QtWidgets import QApplication
    if QApplication.platformName()=='offscreen':return
    import ctypes
    from ctypes import wintypes
    try:
        handle=int(widget.winId());dwm=ctypes.WinDLL('dwmapi');user=ctypes.WinDLL('user32');gdi=ctypes.WinDLL('gdi32')
        dwm.DwmSetWindowAttribute.argtypes=[wintypes.HWND,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD]
        border=wintypes.DWORD(0xfffffffe);corners=wintypes.DWORD(2)
        dwm.DwmSetWindowAttribute(handle,34,ctypes.byref(border),ctypes.sizeof(border))
        dwm.DwmSetWindowAttribute(handle,33,ctypes.byref(corners),ctypes.sizeof(corners))
        user.GetClientRect.argtypes=[wintypes.HWND,ctypes.POINTER(wintypes.RECT)]
        user.SetWindowRgn.argtypes=[wintypes.HWND,wintypes.HANDLE,wintypes.BOOL]
        gdi.CreateRoundRectRgn.argtypes=[ctypes.c_int]*6;gdi.CreateRoundRectRgn.restype=wintypes.HANDLE
        gdi.DeleteObject.argtypes=[wintypes.HANDLE]
        rect=wintypes.RECT()
        if user.GetClientRect(handle,ctypes.byref(rect)):
            diameter=max(1,round(2*radius*widget.devicePixelRatioF()))
            region=gdi.CreateRoundRectRgn(0,0,rect.right+1,rect.bottom+1,diameter,diameter)
            if region and not user.SetWindowRgn(handle,region,True):gdi.DeleteObject(region)
    except (OSError,AttributeError):pass
