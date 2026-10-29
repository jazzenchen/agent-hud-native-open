"""Original synthesized score; no sampled commercial music or third-party audio."""
from pathlib import Path
import numpy as np
import wave
sr=48000;length=40;time=np.arange(sr*length)/sr
mix=np.zeros((len(time),2),dtype=np.float64)
def add(at,duration,note,level,kind='pluck',pan=0):
    start=int(at*sr);count=min(int(duration*sr),len(time)-start)
    if count<=0:return
    t=np.arange(count)/sr;freq=440*2**((note-69)/12)
    if kind=='pad':
        envelope=np.minimum(1,t/.35)*np.minimum(1,(duration-t)/.7)
        sound=(np.sin(2*np.pi*freq*t)+.22*np.sin(2*np.pi*freq*2.003*t))*.55*envelope
    else:
        envelope=(1-np.exp(-t*160))*np.exp(-t*5)
        sound=(np.sin(2*np.pi*freq*t)+.20*np.sin(2*np.pi*freq*2*t)+.07*np.sin(2*np.pi*freq*3*t))*envelope
    mix[start:start+count,0]+=sound*level*(1-pan*.4)
    mix[start:start+count,1]+=sound*level*(1+pan*.4)
chords=[(50,57,62,65),(46,53,58,62),(53,60,65,69),(48,55,60,64)]
for bar in range(20):
    base=bar*2;chord=chords[(bar//2)%4]
    for j,note in enumerate(chord):add(base,2.5,note,.07,'pad',(-1 if j%2 else 1)*.4)
    if bar>0:
        for beat in range(4):
            at=base+beat*.5;t=np.arange(int(.26*sr))/sr
            kick=np.sin(2*np.pi*(48*t+38*(1-np.exp(-t*25))/25))*np.exp(-t*23)*.18
            start=int(at*sr);count=min(len(kick),len(time)-start)
            mix[start:start+count]+=kick[:count,None]
            if beat%2:add(at+.25,.7,chord[(bar+beat)%4]+24,.075,'pluck',(-1 if beat==1 else 1)*.5)
    if bar%2==0:
        for k in range(4):add(base+k*.25,1.1,chord[(k+bar)%4]+24,.12,'pluck',(-.5+k/3))
# Soft stereo shimmer precedes each chapter, bass lands exactly at the edit.
rng=np.random.default_rng(20261019)
for at in range(4,40,4):
    n=int(.22*sr);z=rng.standard_normal(n);z=z-np.roll(z,1)
    env=np.sin(np.linspace(0,np.pi,n))**2*.013
    start=int((at-.22)*sr);mix[start:start+n,0]+=z*env;mix[start:start+n,1]+=np.roll(z,71)*env
fade=np.minimum(1,time/.7)*np.minimum(1,(length-time)/1.5)
mix=np.tanh(mix*1.3)*fade[:,None];mix=mix/max(1,float(np.max(np.abs(mix)))/.82)
with wave.open(str(Path(__file__).parent/'public/soundtrack.wav'),'wb') as out:
    out.setparams((2,2,sr,0,'NONE','not compressed'));out.writeframes((mix*32767).astype('<i2').tobytes())
print('Original score: 40s / 120 BPM / 48kHz stereo')
