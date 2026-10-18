"""Windows-only replacement for HUDSurface/JoinedGlass's native backdrop."""
import os


def frosted_backdrop(handle, enabled=True):
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
        # Acrylic, 70% black dimming: the upstream 50% transparency maps to
        # 70% retained black (HUDLook.glassDimming). No system settings change.
        accent = Accent(4 if enabled else 0, 2, 0xB2000000, 0)
        data = Data(19, ctypes.addressof(accent), ctypes.sizeof(accent))
        user = ctypes.WinDLL('user32', use_last_error=True)
        function = user.SetWindowCompositionAttribute
        function.argtypes = (wintypes.HWND, ctypes.POINTER(Data))
        function.restype = wintypes.BOOL
        return bool(function(int(handle), ctypes.byref(data)))
    except (AttributeError, OSError):
        return False
