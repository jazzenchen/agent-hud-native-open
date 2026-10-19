"""Native compositor audit: owned wallpaper only, no user data or settings.

24 mode/edge/theme combinations, intermediate opening/closing frames, then an
actual timed reversal and hide. Runs on the Windows Qt platform. Reports exact
scope and failures, never an overall similarity score.
"""
import json,sys,time
from pathlib import Path
from PySide6.QtCore import QRect,QPoint,QSize
from PySide6.QtWidgets import QApplication
from PySide6.QtGui import QRegion
from PySide6.QtTest import QTest
from native_material_preview import Scene
from preferences import load
from placement import group_origin
from views import SimpleMeterView


def main():
    app=QApplication([]);app.setStyle('Fusion');app.setQuitOnLastWindowClosed(False)
    assert app.platformName()=='windows','Use the real Windows platform'
    destination=Path(sys.argv[1]);destination.mkdir(parents=True,exist_ok=True)
    screen=app.primaryScreen();rect=screen.geometry()
    scene=Scene();scene.setFixedSize(rect.size());scene.move(rect.topLeft())
    scene.show();scene.raise_();QTest.qWait(150)
    current=[None]
    def capture():
        # Other desktop tasks may create topmost windows during a native run.
        # Reassert only our own controlled layers before each bounded readback.
        scene.raise_()
        meter=current[0]
        if meter is not None:
            for widget in (meter,meter.peek,meter.panel):
                if widget.isVisible():widget.raise_()
        QTest.qWait(20)
        return screen.grabWindow(0,0,0,rect.width(),rect.height()).toImage()
    baseline=capture();records=[]
    options=sys.argv[2:];filters=[value for value in options if not value.startswith('--')]
    news='--news' in options
    draft='--draft' in options
    def near_shape(widget,global_point):
        local=widget.mapFromGlobal(global_point);mask=widget.mask()
        if mask.isEmpty():mask=QRegion(widget.rect())
        # Desktop readback rounds physical pixels while Qt masks are logical.
        # Exclude the 2-logical-pixel antialias fringe, not a whole bounding box.
        return any(mask.contains(local+QPoint(dx,dy)) for dx in (-2,0,2) for dy in (-2,0,2))
    for mode in ('simple','logos','notch'):
        for edge in ('top','bottom','left','right'):
            for theme in ('dark','light'):
                if filters and f'{mode}-{edge}'!=filters[0]:continue
                settings=load(dict(mode=mode,edge=edge,hud_appearance=theme,glass=True,glow_hidden=True))
                meter=SimpleMeterView('Codex',screen,settings,lambda _:None)
                if draft:
                    from panel_layout import LayoutStore
                    meter.layout_store=LayoutStore()
                    meter.layout_store.propose(dict(style=dict(width=680),sections=['tokens','blocks','sessions'],hiddenSections=['sessions']))
                current[0]=meter
                meter.set_data(dict(quota=dict(windows=[dict(label='5-hour',used=17),dict(label='Weekly',used=42)]),local=dict(sessions=[])))
                actual_edge='top' if mode=='notch' else edge
                x,y=group_origin((rect.x(),rect.y(),rect.width(),rect.height()),(meter.width(),meter.height()),actual_edge,.5,24)
                meter.place(x,y);meter.show();meter.apply_material();QTest.qWait(35)
                if news:
                    now=time.time()
                    meter.set_attention([dict(id='fixture-news',kind='quota',event='exhaustion',vendor='Codex',source='',session='',account='',window='sample',label='5 小时限额',summary='即将耗尽',remaining=8,reset=now+7200,at=now,time_to_exhaust=2400,other_limits=[])])
                samples=[]
                def audit(widget,phase):
                    image=capture();scale=image.width()/rect.width();deltas=[];points=[]
                    for px,py in ((0,0),(widget.width()-1,0),(0,widget.height()-1),(widget.width()-1,widget.height()-1)):
                        # Notch's top contact edge intentionally includes its
                        # top corners. Rectangular 1px-tall morphs have no
                        # outside corner at all, so only inspect masked points.
                        if widget.mask().isEmpty() or widget.mask().contains(QPoint(px,py)):continue
                        if widget is not meter:
                            # Side peeks intentionally tuck underneath the
                            # strip; its visible pixels are not a blur leak.
                            if near_shape(meter,widget.mapToGlobal(QPoint(px,py))):continue
                        ix=round((widget.x()-rect.x()+px)*scale);iy=round((widget.y()-rect.y()+py)*scale)
                        if not (0<=ix<image.width() and 0<=iy<image.height()):continue
                        a=image.pixelColor(ix,iy);b=baseline.pixelColor(ix,iy)
                        delta=max(abs(v-w) for v,w in zip(a.getRgb()[:3],b.getRgb()[:3]));deltas.append(delta)
                        points.append(dict(local=[px,py],screen=[ix,iy],actual=a.name(),expected=b.name(),delta=delta))
                    samples.append(dict(surface=phase,max_outside_rgb_delta=max(deltas,default=0),points=points))
                    if widget is meter.panel:
                        # Check the entire travel corridor, including pixels
                        # formerly covered by a larger frame, not just corners.
                        corridor=QRect(widget.position_for(1.),QSize(widget.content_width(),widget.layout_height())).united(widget.source_rect)
                        trail=[]
                        for gx in range(corridor.left()-4,corridor.right()+5,17):
                            for gy in range(corridor.top()-4,corridor.bottom()+5,17):
                                if near_shape(widget,QPoint(gx,gy)) or near_shape(meter,QPoint(gx,gy)):continue
                                ix=round((gx-rect.x())*scale);iy=round((gy-rect.y())*scale)
                                if not (0<=ix<image.width() and 0<=iy<image.height()):continue
                                a=image.pixelColor(ix,iy);b=baseline.pixelColor(ix,iy)
                                trail.append(max(abs(v-w) for v,w in zip(a.getRgb()[:3],b.getRgb()[:3])))
                        samples[-1]['max_trail_rgb_delta']=max(trail,default=0)
                    if max(deltas,default=0)>16 or samples[-1].get('max_trail_rgb_delta',0)>16:
                        image.save(str(destination/f'failure-{mode}-{edge}-{theme}-{phase}.png'))
                    return image
                audit(meter,'meter')
                if mode!='notch':
                    if news:meter.peek.open()
                    else:meter.hover()
                    meter.peek.animation.jump(1.);QTest.qWait(35);audit(meter.peek,'peek')
                meter.open_panel()
                for value in (.15,.5,1.,.65,.2):
                    meter.panel.animation.jump(value);QTest.qWait(35)
                    image=audit(meter.panel,'detail-'+str(value))
                    if value==1.:
                        bounds=meter.panel.geometry().adjusted(-8,-8,8,8).intersected(rect)
                        scale=image.width()/rect.width()
                        crop=QRect(round((bounds.x()-rect.x())*scale),round((bounds.y()-rect.y())*scale),round(bounds.width()*scale),round(bounds.height()*scale))
                        image.copy(crop).save(str(destination/f'{mode}-{edge}-{theme}.png'))
                if news:meter.set_attention([])
                meter.panel.animation.jump(0.);QTest.qWait(35)
                hidden=capture();changed=0
                # The former panel's centre must show its original wallpaper.
                point=meter.panel.position_for(1.);px=round((point.x()-rect.x()+200)*hidden.width()/rect.width());py=round((point.y()-rect.y()+100)*hidden.height()/rect.height())
                if 0<=px<hidden.width() and 0<=py<hidden.height():
                    changed=max(abs(a-b) for a,b in zip(hidden.pixelColor(px,py).getRgb()[:3],baseline.pixelColor(px,py).getRgb()[:3]))
                meter.open_panel();QTest.qWait(60);meter.panel.collapse();QTest.qWait(45);meter.open_panel();QTest.qWait(470)
                reversal=not meter.panel.animation.running and meter.panel.progress==1.
                reversal_state=dict(progress=meter.panel.progress,target=meter.panel.animation.state.target,
                    elapsed=meter.panel.animation.state.elapsed,duration=meter.panel.animation.state.duration,
                    leave_timer_active=meter.leave_timer.isActive())
                meter.hide_all();QTest.qWait(35)
                closed=all(not w.isVisible() for w in (meter,meter.peek,meter.panel,meter.glow))
                records.append(dict(mode=mode,configured_edge=edge,effective_edge=actual_edge,theme=theme,
                    samples=samples,after_close_rgb_delta=changed,reversal_settled=reversal,reversal_state=reversal_state,all_surfaces_closed=closed))
                for widget in (meter.peek,meter.panel,meter.glow,meter):widget.close()
                current[0]=None
    scene.close();assert records,'No mode/edge cases matched'
    result=dict(platform=app.platformName(),dpi=screen.devicePixelRatio(),cases=records,
                scope='Outside-mask corners and a 17pt travel-corridor grid (2pt fractional-DPI antialias guard), mid-morph frames, former-panel centre after close, reversal and hide. Not complete visual similarity proof.')
    (destination/'audit.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    failures=[(r['mode'],r['configured_edge'],r['theme']) for r in records if max(max(s['max_outside_rgb_delta'],s.get('max_trail_rgb_delta',0)) for s in r['samples'])>16 or r['after_close_rgb_delta']>16 or not r['reversal_settled'] or not r['all_surfaces_closed']]
    print(json.dumps(dict(cases=len(records),failures=failures)))


if __name__=='__main__':main()
