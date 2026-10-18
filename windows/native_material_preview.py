"""Developer-only native compositor QA, with an owned backdrop and explicit sample data.

Captures only our own preview scene. No account reads, client launch, input
automation or changes to the resident app/settings. Run with the normal Windows
Qt platform; QWidget.grab alone cannot verify Acrylic composition.
"""
import sys,json,time,statistics
from pathlib import Path
from PySide6.QtCore import Qt,QRectF,QPoint
from PySide6.QtGui import QPainter,QPixmap,QFont,QColor
from PySide6.QtWidgets import QApplication,QWidget
from PySide6.QtTest import QTest
from views import SimpleMeterView
from preferences import load
from source_design import DESIGN

class Scene(QWidget):
    def __init__(self):
        super().__init__(None,Qt.WindowType.FramelessWindowHint|Qt.WindowType.Tool|Qt.WindowType.WindowStaysOnTopHint)
        self.wallpaper=QPixmap(str(DESIGN['resources']/'settings-wallpaper.png'))
        self.setFixedSize(800,440);self.move(80,80);self.setWindowTitle(DESIGN['app_name'])
    def paintEvent(self,event):
        p=QPainter(self);p.drawPixmap(self.rect(),self.wallpaper)
        p.setPen(QColor('white'));p.setFont(QFont('Microsoft YaHei UI',10));p.drawText(24,410,'示例数据 · 原生材质检查');p.end()

def main():
    app=QApplication([]);app.setStyle('Fusion');app.setQuitOnLastWindowClosed(False)
    destination=Path(sys.argv[1]);destination.mkdir(parents=True,exist_ok=True)
    scene=Scene();scene.show();scene.raise_();app.processEvents()
    meter=SimpleMeterView('Codex',app.primaryScreen(),load(dict(size=28,glass=True)),lambda _:None)
    meter.set_data(dict(quota=dict(windows=[dict(label='5-hour',used=17),dict(label='Weekly',used=42)]),local=dict(sessions=[])))
    meter.place(410,180);meter.show();meter.apply_material();app.processEvents()
    result={}
    for scheme in ('dark','light'):
        meter.settings['hud_appearance']=scheme;meter.apply_material();meter.hover();meter.peek.animation.jump(1.)
        meter.peek.apply_material();meter.raise_();app.processEvents();QTest.qWait(400)
        # A HWND-only grab omits independent tool windows. Capture the bounded
        # screen area occupied by our opaque preview backdrop and its overlays.
        screenshot=scene.screen().grabWindow(0,scene.x(),scene.y(),scene.width(),scene.height())
        image=screenshot.toImage()
        samples=[image.pixelColor(x,y).lightness() for x in range(30,scene.width(),80) for y in range(30,scene.height(),60)] if not image.isNull() else []
        capture_valid=bool(samples and max(samples)-min(samples)>10)
        capture_file='native-'+scheme+('' if capture_valid else '-unavailable')+'.png'
        screenshot.save(str(destination/capture_file))
        result[scheme]=dict(meter_glass=bool(meter.native_glass),peek_glass=bool(meter.peek.native_glass),
            capture_valid=capture_valid,capture_file=capture_file,
            capture_note='Owned native scene captured' if capture_valid else 'Desktop capture unavailable/blank; cannot establish compositor fidelity',
            meter_size=[meter.width(),meter.height()],peek_size=[meter.peek.width(),meter.peek.height()],
            meter_rect=[meter.x()-scene.x(),meter.y()-scene.y(),meter.width(),meter.height()],
            peek_rect=[meter.peek.x()-scene.x(),meter.peek.y()-scene.y(),meter.peek.width(),meter.peek.height()])
        import ctypes
        from ctypes import wintypes
        user=ctypes.WinDLL('user32');gdi=ctypes.WinDLL('gdi32')
        gdi.CreateRectRgn.argtypes=[ctypes.c_int]*4;gdi.CreateRectRgn.restype=wintypes.HANDLE
        user.GetWindowRgn.argtypes=[wintypes.HWND,wintypes.HANDLE]
        gdi.PtInRegion.argtypes=[wintypes.HANDLE,ctypes.c_int,ctypes.c_int]
        gdi.DeleteObject.argtypes=[wintypes.HANDLE]
        for name,widget in (('meter',meter),('peek',meter.peek)):
            region=gdi.CreateRectRgn(0,0,0,0);kind=user.GetWindowRgn(int(widget.winId()),region)
            result[scheme][name+'_clip']=dict(type=kind,radius=widget.corner,top=[bool(gdi.PtInRegion(region,x,0)) for x in range(widget.width())])
            gdi.DeleteObject(region)
    (destination/'native-material.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    # Measure the actual Windows Qt paint path separately from screenshot/file IO.
    # These are CPU/readback costs and timer intervals, not GPU frame-rate claims.
    def measure(widget):
        for _ in range(3):widget.grab()
        values=[]
        for _ in range(30):
            start=time.perf_counter();widget.grab();values.append((time.perf_counter()-start)*1000)
        values.sort();return dict(p50_ms=round(statistics.median(values),3),p95_ms=round(values[math.ceil(len(values)*.95)-1],3))
    import math
    scene.resize(800,560);meter.peek.dismiss(immediate=True)
    timestamps=[];meter.panel.pinned=True
    meter.panel.animation.valueChanged.connect(lambda _:timestamps.append(time.perf_counter()))
    meter.open_panel();QTest.qWait(80);meter.panel.collapse();QTest.qWait(50);meter.open_panel();QTest.qWait(600)
    intervals=sorted((b-a)*1000 for a,b in zip(timestamps,timestamps[1:]))
    performance=dict(platform=app.platformName(),scope='Native Windows Qt CPU paint/readback; GPU frame time not measured',
                     panel=measure(meter.panel),peek=measure(meter.peek),
                     reversal=dict(frames=len(timestamps),settled=not meter.panel.animation.running,
                                   median_interval_ms=round(statistics.median(intervals),2) if intervals else None,
                                   p95_interval_ms=round(intervals[math.ceil(len(intervals)*.95)-1],2) if intervals else None))
    meter.panel.hide();meter.settings['mode']='logos';meter.refresh_size();meter.apply_material()
    performance['glow']={}
    for style in ('blur','dots','ascii','blocks','braille','binary'):
        meter.settings['glow_style']=style;meter.glow.sync();app.processEvents();performance['glow'][style]=measure(meter.glow)
    (destination/'ui-performance.json').write_text(json.dumps(performance,indent=2),encoding='utf-8')
    meter.hide_all();meter.peek.close();meter.glow.close();meter.panel.close();meter.close();scene.close()

if __name__=='__main__':main()
