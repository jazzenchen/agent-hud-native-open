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
        rgb=0x00f5f5f7 if light else 0
        accent = Accent((3 if style=='clear' else 4) if enabled else 0, 2, (alpha<<24)|rgb, 0)
        data = Data(19, ctypes.addressof(accent), ctypes.sizeof(accent))
        user = ctypes.WinDLL('user32', use_last_error=True)
        function = user.SetWindowCompositionAttribute
        function.argtypes = (wintypes.HWND, ctypes.POINTER(Data))
        function.restype = wintypes.BOOL
        return bool(function(int(handle), ctypes.byref(data)))
    except (AttributeError, OSError):
        return False
