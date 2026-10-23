"""One theme resolver for every Windows surface, with explicit window/HUD scopes."""
import os
from PySide6.QtCore import Qt
from PySide6.QtGui import QColor,QPalette,QCursor
from PySide6.QtWidgets import QApplication
from source_design import DESIGN

def system_is_light():
    # Read the actual OS setting, not an already themed QApplication palette.
    if os.name=='nt':
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') as key:
                return bool(winreg.QueryValueEx(key,'AppsUseLightTheme')[0])
        except OSError:pass
    scheme=QApplication.styleHints().colorScheme()
    return scheme!=Qt.ColorScheme.Dark

def resolves_light(mode,system_light=None):
    return (system_is_light() if system_light is None else system_light) if mode=='system' else mode=='light'

def window_is_light(settings,screen_settings=None,system_light=None):
    mode=screen_settings.get('hud_appearance','dark') if settings.get('match_screen') and screen_settings else settings['appearance']
    return resolves_light(mode,system_light)

def tokens(light):
    source=DESIGN['light_colors'] if light else DESIGN['colors']
    return dict(bg=source['windowBackground'],sidebar=source['sidebarBackground'],ink=source['text'],
        muted=source['secondary'],tertiary=source['tertiary'],input=source.get('inputBackground','#ffffff' if light else '#1c1c1e'),
        card='#ffffff' if light else '#333333',border='#dedee2' if light else '#484848',
        divider='#e5e5e7' if light else '#3e3e3e',track='#dedee1' if light else '#48484b',
        segment='#ffffff' if light else '#57575b',accent='#0a84ff',light=light)

def apply_widget_theme(widget,light):
    t=tokens(light);palette=QPalette()
    for role,key in [(QPalette.ColorRole.Window,'bg'),(QPalette.ColorRole.WindowText,'ink'),
        (QPalette.ColorRole.Base,'card'),(QPalette.ColorRole.AlternateBase,'sidebar'),(QPalette.ColorRole.Text,'ink'),
        (QPalette.ColorRole.Button,'card'),(QPalette.ColorRole.ButtonText,'ink'),(QPalette.ColorRole.Highlight,'accent'),
        (QPalette.ColorRole.ToolTipBase,'card'),(QPalette.ColorRole.ToolTipText,'ink'),(QPalette.ColorRole.PlaceholderText,'muted')]:
        palette.setColor(role,QColor(t[key]))
    palette.setColor(QPalette.ColorRole.HighlightedText,QColor('white'))
    widget.setPalette(palette);widget.setProperty('uiLight',light)
    if widget.isVisible():native_titlebar(widget,light)

def native_titlebar(widget,light):
    if os.name!='nt' or QApplication.platformName()=='offscreen':return
    try:
        import ctypes
        from ctypes import wintypes
        value=ctypes.c_int(not light);dwm=ctypes.WinDLL('dwmapi')
        dwm.DwmSetWindowAttribute.argtypes=[wintypes.HWND,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD]
        dwm.DwmSetWindowAttribute(int(widget.winId()),20,ctypes.byref(value),ctypes.sizeof(value))
    except (OSError,AttributeError):pass

def menu_styles(light):
    t=tokens(light)
    return (f"QMenu{{background:{t['bg']};color:{t['ink']};border:1px solid {t['border']};border-radius:9px;padding:6px;font-family:'Microsoft YaHei UI';font-size:12px}} "
        "QMenu::item{padding:7px 24px;border-radius:5px} QMenu::item:selected{background:#0a84ff;color:white} "
        f"QMenu::item:disabled{{color:{t['muted']}}} QMenu::separator{{height:1px;background:{t['divider']};margin:5px 8px}}")
