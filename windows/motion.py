"""Shared sleeping clock and exact damped springs; retarget without losing velocity."""
from dataclasses import dataclass
from math import pi,sqrt,exp,cos,sin
import os,time,weakref
from PySide6.QtCore import QObject,QTimer,Qt,Signal
from PySide6.QtWidgets import QApplication
from shiboken6 import isValid

_motion_cache=(0.,True)
def animations_enabled():
    """Read SPI_GETCLIENTAREAANIMATION. Never write system preferences."""
    global _motion_cache
    now=time.monotonic()
    if now-_motion_cache[0]<1:return _motion_cache[1]
    enabled=True
    if os.name=='nt':
        try:
            import ctypes
            from ctypes import wintypes
            user=ctypes.WinDLL('user32');value=wintypes.BOOL()
            user.SystemParametersInfoW.argtypes=[wintypes.UINT,wintypes.UINT,ctypes.c_void_p,wintypes.UINT]
            if user.SystemParametersInfoW(0x1042,0,ctypes.byref(value),0):enabled=bool(value.value)
        except (OSError,AttributeError):pass
    _motion_cache=(now,enabled);return enabled

@dataclass
class SpringState:
    position:float=0.
    velocity:float=0.
    target:float=0.
    frequency:float=4.
    damping:float=1.
    def advance(self,seconds):
        if seconds<=0:return
        w=2*pi*self.frequency;d=self.position-self.target;v=self.velocity;z=self.damping
        if z>=1:
            decay=exp(-w*seconds);coefficient=v+w*d
            self.position=self.target+(d+coefficient*seconds)*decay
            self.velocity=(v-w*coefficient*seconds)*decay
        else:
            wd=w*sqrt(1-z*z);decay=exp(-z*w*seconds);a=d;b=(v+z*w*d)/wd
            c=cos(wd*seconds);s=sin(wd*seconds);offset=a*c+b*s
            self.position=self.target+decay*offset
            self.velocity=decay*(-z*w*offset+wd*(-a*s+b*c))
        if self.settled:self.position=self.target;self.velocity=0.
    @property
    def settled(self):return abs(self.position-self.target)<.0005 and abs(self.velocity)<.005

class MotionClock(QObject):
    def __init__(self):
        super().__init__(QApplication.instance());self.active=weakref.WeakSet();self.last=time.monotonic()
        self.timer=QTimer(self);self.timer.setTimerType(Qt.TimerType.PreciseTimer);self.timer.setInterval(16);self.timer.timeout.connect(self.frame)
    def add(self,driver):
        if driver not in self.active:driver._last_frame=time.monotonic()
        self.active.add(driver)
        if not self.timer.isActive():self.last=time.monotonic();self.timer.start()
    def frame(self):
        now=time.monotonic();self.last=now
        for driver in tuple(self.active):
            if not isValid(driver) or not driver.running:self.active.discard(driver);continue
            elapsed=max(0,now-driver._last_frame);driver._last_frame=now
            driver.state.advance(elapsed);driver.valueChanged.emit(driver.state.position)
            if driver.state.settled:
                driver.running=False;self.active.discard(driver);driver.finished.emit()
        if not self.active:self.timer.stop()

_clock=None
def motion_clock():
    global _clock
    if _clock is None or not isValid(_clock):_clock=MotionClock()
    return _clock

class SpringDriver(QObject):
    valueChanged=Signal(float)
    finished=Signal()
    def __init__(self,parent=None,value=0.,frequency=4.,damping=1.):
        super().__init__(parent);self.state=SpringState(value,0.,value,frequency,damping);self.running=False
    def retarget(self,target,immediate=False):
        self.state.target=float(target)
        if immediate or not animations_enabled():self.jump(target);return
        self.running=True;motion_clock().add(self)
    def jump(self,value):
        self.stop();self.state.position=self.state.target=float(value);self.state.velocity=0.
        self.valueChanged.emit(float(value));self.finished.emit()
    def stop(self):
        self.running=False
        if _clock is not None and isValid(_clock):
            _clock.active.discard(self)
            if not _clock.active:_clock.timer.stop()
