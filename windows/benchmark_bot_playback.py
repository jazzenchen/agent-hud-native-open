"""Bounded owned-window playback benchmark, never a claim about GPU presentation."""
import argparse,json,statistics,time
from pathlib import Path
from PySide6.QtCore import Qt,QRectF,QTimer
from PySide6.QtGui import QPainter,QColor
from PySide6.QtWidgets import QApplication,QWidget
from bot_player import BotPlayer,library


def distribution(values):
    ordered=sorted(values)
    return dict(samples=len(values),p50_ms=round(statistics.median(values)*1000,3),
                p95_ms=round(ordered[int((len(ordered)-1)*.95)]*1000,3),
                worst_ms=round(max(values)*1000,3))


class Playback(QWidget):
    vendors=('Codex','Claude','Cursor','WorkBuddy')
    def __init__(self,frames,finished):
        super().__init__();self.resize(340,100);self.setWindowTitle('Agent HUD playback measurement')
        self.player=BotPlayer(self);self.index=0;self.frame_count=frames;self.finished=finished
        self.intervals=[];self.paints=[];self.previous=None;self.changed=0
        self.timer=QTimer(self);self.timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.timer.setInterval(round(1000/24));self.timer.timeout.connect(self.step)
    def paintEvent(self,event):
        started=time.perf_counter();p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform);p.fillRect(self.rect(),QColor('#202020'))
        for index,vendor in enumerate(self.vendors):
            clip=library().clip(vendor,False,'working');frames=clip['frames']
            frame=frames[min(self.index,len(frames)-1)]
            self.player.draw_frame(p,QRectF(24+index*78,30,24,24),frame)
        p.end();self.paints.append(time.perf_counter()-started)
    def step(self):
        now=time.perf_counter()
        if self.previous is not None:self.intervals.append(now-self.previous)
        self.previous=now;self.index+=1
        self.repaint()
        if self.index>=self.frame_count:
            self.timer.stop();self.finished(self);self.close();QApplication.instance().quit()


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path)
    parser.add_argument('--frames',type=int,default=144);args=parser.parse_args()
    if not 24<=args.frames<=192:parser.error('Use 24..192 source frames')
    app=QApplication([]);result={}
    def finished(scene):
        result.update(platform=app.platformName(),vendors=list(scene.vendors),
            paint=distribution(scene.paints),timer_intervals=distribution(scene.intervals),
            intervals_over_1_5_frames=sum(value>1.5/24 for value in scene.intervals),
            scope='Owned Qt window: CPU paint and event-loop cadence, not GPU/vsync or whole resident app FPS',
            image_cache=len(library().cache),atlas_cache=len(library().pages))
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result))
    scene=Playback(args.frames,finished);scene.show();scene.timer.start();app.exec()


if __name__=='__main__':main()
