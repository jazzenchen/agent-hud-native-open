"""Owned Windows native scene for the original-source bot playback."""
import json,sys,time
from pathlib import Path
from PySide6.QtCore import Qt,QRectF
from PySide6.QtGui import QPainter,QColor,QFont
from PySide6.QtWidgets import QApplication,QWidget
from PySide6.QtTest import QTest
from bot_player import library,BotPlayer


class BotScene(QWidget):
    states=('working','thinking','asking','opened','failed','limited')
    vendors=('Codex','Cursor','Claude','DeepSeek','Grok','GitHub Copilot')
    def __init__(self):
        super().__init__();self.resize(820,600);self.light=False;self.phase=2.;self.player=BotPlayer(self)
        self.setWindowTitle('Agent HUD original animation preview')
    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.RenderHint.Antialiasing);p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.fillRect(self.rect(),QColor('#f5f5f7' if self.light else '#202020'));p.setFont(QFont('Segoe UI',9));ink=QColor('#1d1d1f' if self.light else '#f5f5f7')
        for col,state in enumerate(self.states):p.setPen(ink);p.drawText(QRectF(98+col*118,8,118,30),Qt.AlignmentFlag.AlignCenter,state)
        for row,vendor in enumerate(self.vendors):
            y=46+row*88;p.setPen(ink);p.drawText(QRectF(8,y,90,70),Qt.AlignmentFlag.AlignVCenter,vendor)
            for col,state in enumerate(self.states):
                clip=library().clip(vendor,self.light,state)
                if clip:
                    frame=clip['frames'][min(len(clip['frames'])-1,int(self.phase*clip['fps']))]
                    self.player.draw_frame(p,QRectF(123+col*118,y+9,48,48),frame)
        p.end()


def main():
    app=QApplication([]);destination=Path(sys.argv[1]);destination.mkdir(parents=True,exist_ok=True)
    scene=BotScene();scene.show();QTest.qWait(150)
    if not library().ready:raise RuntimeError('Original bot assets missing')
    for light in (False,True):
        scene.light=light;scene.update();app.processEvents();scene.grab().save(str(destination/('bots-light.png' if light else 'bots-dark.png')))
    started=time.perf_counter();changed=0;before=None
    for n in range(48):
        scene.phase=n/24;scene.update();app.processEvents();image=scene.grab().toImage();sample=image.copy(98,46,118,88)
        if before is not None and sample!=before:changed+=1
        before=sample
    result=dict(original_pack_ready=True,changed_frames=changed,frames=48,cpu_capture_seconds=round(time.perf_counter()-started,3),scope='Owned native scene; CPU rendering/readback, not GPU frame time')
    (destination/'bot-native.json').write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result));scene.close()

if __name__=='__main__':main()
