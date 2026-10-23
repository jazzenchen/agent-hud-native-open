import React from 'react';
import {AbsoluteFill,Audio,Composition,Easing,OffthreadVideo,Sequence,interpolate,registerRoot,spring,staticFile,useCurrentFrame,useVideoConfig} from 'remotion';
import {theme as t} from './theme';

const clamp={extrapolateLeft:'clamp' as const,extrapolateRight:'clamp' as const,easing:t.ease.out};
const chapters=[
 {file:'01-simple',n:'01',tag:'SIMPLE',title:['工作进度，','轻轻一瞥。'],body:'Codex · Claude Code\nCursor · WorkBuddy',note:'悬停查看额度',crop:[40,160,650,430]},
 {file:'02-details',n:'02',tag:'DETAILS',title:['展开细节，','保持专注。'],body:'额度 · Token · 会话\n同一块面板，随时掌握。',note:'实际 Windows 版面板',crop:[45,25,700,550]},
 {file:'03-approval',n:'03',tag:'ATTENTION',title:['需要确认时，','就在手边。'],body:'批准请求与等待状态\n沿用原版交互与角色动效。',note:'实际请求卡片 · 示例任务',crop:[50,105,700,430]},
 {file:'04-reply',n:'04',tag:'A LITTLE ALIVE',title:['任务完成，','小小回应。'],body:'回复提醒与小机器人\n真实播放的角色动画。',note:'原版动画资源生成的 Windows 动效',crop:[50,105,700,430]},
 {file:'05-modes',n:'05',tag:'THREE WAYS',title:['沿着屏幕，','找到位置。'],body:'简约 · 动态 · 刘海\n让工具融入工作桌面。',note:'三种模式 · 真实界面切换',crop:[300,40,680,560]},
 {file:'06-settings',n:'06',tag:'MAKE IT YOURS',title:['深与浅，','都很自然。'],body:'主题 · 材质 · 布局\nWindows 原生设置窗口。',note:'深色 → 浅色',crop:[70,10,1140,775]},
 {file:'07-accounts',n:'07',tag:'YOUR AGENTS',title:['工具不同，','一处照看。'],body:'账户、订阅与剩余积分\n此处均为独立演示数据。',note:'WorkBuddy · 示例账户与积分',crop:[70,10,1140,775]},
 {file:'08-tokens',n:'08',tag:'SEE THE RHYTHM',title:['用量有迹，','节奏可见。'],body:'Token 分布与活跃记录\n把消耗看得更清楚。',note:'示例 Token 记录 · 非真实账单',crop:[70,10,1140,775]},
];

const Background:React.FC=()=>{
 const f=useCurrentFrame();const {fps}=useVideoConfig();
 return <AbsoluteFill style={{background:t.colors.bg,overflow:'hidden'}}>
  <div style={{position:'absolute',inset:-200,background:`radial-gradient(ellipse at ${67+Math.sin(f/fps*.13)*5}% 25%, ${t.colors.bgAlt}, transparent 64%),radial-gradient(ellipse at 10% 85%, ${t.colors.bgAlt}, transparent 55%)`,transform:`rotate(${Math.sin(f/fps*.1)*2}deg)`}}/>
  <div style={{position:'absolute',left:110,top:105,width:1700,height:1,background:t.colors.line}}/>
 </AbsoluteFill>;
};

const Enter:React.FC<{children:React.ReactNode,delay?:number,style?:React.CSSProperties}>=({children,delay=0,style={}})=>{
 const f=useCurrentFrame();const {fps}=useVideoConfig();const p=spring({frame:f-delay*fps,fps,config:t.spring.smooth});
 return <div style={{...style,opacity:p,transform:`translateY(${(1-p)*28}px) scale(${.98+.02*p})`}}>{children}</div>;
};

const NativeStage:React.FC<{file:string,crop:number[],wide?:boolean}>=({file,crop})=>{
 const f=useCurrentFrame();const {fps}=useVideoConfig();const [x,y,w,h]=crop;
 const scale=Math.min(1000/w,650/h);const camera=interpolate(f,[.6*fps,4*fps],[1,1.012],{...clamp,easing:t.ease.inOut});
 return <Enter delay={.12} style={{position:'absolute',left:790,top:220,width:1000,height:650}}>
  <div style={{position:'absolute',inset:0,borderRadius:28,overflow:'hidden',border:`1px solid ${t.colors.line}`,boxShadow:`0 30px 100px ${t.colors.black}66`,background:t.colors.bgAlt}}>
   <div style={{position:'absolute',inset:0,overflow:'hidden',transform:`scale(${camera})`,transformOrigin:'center'}}>
    <OffthreadVideo muted src={staticFile(`footage-v2/${file}.mp4`)} style={{position:'absolute',width:1280*scale,height:800*scale,maxWidth:'none',left:(1000-w*scale)/2-x*scale,top:(650-h*scale)/2-y*scale}}/>
   </div>
  </div>
 </Enter>;
};

const Chapter:React.FC<{item:typeof chapters[number]}>=({item})=>{
 const f=useCurrentFrame();const {fps}=useVideoConfig();const exit=interpolate(f,[3.74*fps,4*fps],[1,0],{...clamp,easing:t.ease.in});
 return <AbsoluteFill style={{opacity:exit,transform:`translateY(${(1-exit)*-12}px)`}}>
  <Enter delay={0} style={{position:'absolute',left:128,top:235,color:t.colors.hero,fontSize:22,letterSpacing:4,fontWeight:600}}>{item.n} / {item.tag}</Enter>
  {item.title.map((line,i)=><Enter key={line} delay={.08+i*.1} style={{position:'absolute',left:122,top:310+i*100,fontSize:82,lineHeight:1.15,fontWeight:650,letterSpacing:-3,color:t.colors.ink}}>{line}</Enter>)}
  <Enter delay={.30} style={{position:'absolute',left:128,top:575,width:590,fontSize:27,lineHeight:1.8,whiteSpace:'pre-line',color:t.colors.muted}}>{item.body}</Enter>
  <NativeStage file={item.file} crop={item.crop}/>
  <Enter delay={.42} style={{position:'absolute',left:804,top:899,fontSize:23,color:t.colors.muted}}>{item.note}</Enter>
 </AbsoluteFill>;
};

const Intro:React.FC=()=>{
 const f=useCurrentFrame();const {fps}=useVideoConfig();const exit=interpolate(f,[3.7*fps,4*fps],[1,0],{...clamp,easing:t.ease.in});
 return <AbsoluteFill style={{opacity:exit}}>
  <Enter delay={0} style={{position:'absolute',left:132,top:248,fontSize:26,color:t.colors.hero,letterSpacing:5}}>ON WINDOWS</Enter>
  <Enter delay={.1} style={{position:'absolute',left:122,top:314,fontSize:122,fontWeight:700,letterSpacing:-5,color:t.colors.ink}}>Agent HUD</Enter>
  <Enter delay={.23} style={{position:'absolute',left:132,top:477,fontSize:38,color:t.colors.ink}}>少一点切换，多一点专注。</Enter>
  <Enter delay={.36} style={{position:'absolute',left:134,top:576,fontSize:25,color:t.colors.muted,lineHeight:1.8}}>原版设计与角色动效<br/>Windows 移植开发预览</Enter>
  <NativeStage file='01-simple' crop={[55,170,420,430]}/>
 </AbsoluteFill>;
};

const Outro:React.FC=()=>{
 const f=useCurrentFrame();const {fps}=useVideoConfig();const exit=interpolate(f,[3.6*fps,4*fps],[1,0],{...clamp,easing:t.ease.in});
 return <AbsoluteFill style={{opacity:exit}}>
  <Enter style={{position:'absolute',left:132,top:260,fontSize:30,letterSpacing:4,color:t.colors.hero}}>BUILT ON THE ORIGINAL</Enter>
  <Enter delay={.10} style={{position:'absolute',left:124,top:339,fontSize:112,fontWeight:700,color:t.colors.ink,letterSpacing:-4}}>Agent HUD Open</Enter>
  <Enter delay={.24} style={{position:'absolute',left:132,top:500,fontSize:34,color:t.colors.ink}}>原作 / jazzenchen</Enter>
  <Enter delay={.34} style={{position:'absolute',left:132,top:568,fontSize:30,color:t.colors.muted,lineHeight:1.8}}>github.com/jazzenchen/agent-hud-open<br/>Windows port / nanhudev</Enter>
  <Enter delay={.48} style={{position:'absolute',left:132,top:758,fontSize:24,color:t.colors.muted}}>开发预览 · 非原作者官方 Windows 发行版</Enter>
 </AbsoluteFill>;
};

const Film:React.FC=()=>{
 const {fps}=useVideoConfig();const f=useCurrentFrame();
 return <AbsoluteFill style={{fontFamily:t.fonts.body,color:t.colors.ink}}>
  <Background/>
  <Sequence durationInFrames={4*fps}><Intro/></Sequence>
  {chapters.map((item,i)=><Sequence key={item.file} from={(4+i*4)*fps} durationInFrames={4*fps}><Chapter item={item}/></Sequence>)}
  <Sequence from={36*fps} durationInFrames={4*fps}><Outro/></Sequence>
  <div style={{position:'absolute',top:52,left:130,fontSize:24,fontWeight:600,letterSpacing:.4}}>Agent HUD Open <span style={{color:t.colors.muted,fontWeight:400}}> / Windows preview</span></div>
  <div style={{position:'absolute',bottom:46,left:132,fontSize:20,color:t.colors.muted}}>示例账户 · 用量、积分与 Token 记录均为演示数据</div>
  <div style={{position:'absolute',bottom:46,right:130,fontSize:20,color:t.colors.muted}}>WINDOWS / 2026</div>
  <AbsoluteFill style={{pointerEvents:'none',background:`linear-gradient(135deg,${t.colors.bg}09,transparent 45%,${t.colors.bgAlt}08)`,mixBlendMode:'soft-light'}}/>
  <AbsoluteFill style={{pointerEvents:'none',opacity:.028,backgroundImage:`url("data:image/svg+xml,%3Csvg viewBox='0 0 180 180' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' opacity='.7' filter='url(%23n)'/%3E%3C/svg%3E")`}}/>
  <AbsoluteFill style={{pointerEvents:'none',boxShadow:`inset 0 0 160px ${t.colors.black}38`}}/>
  <Audio src={staticFile('soundtrack.wav')} volume={.68}/>
 </AbsoluteFill>;
};
const Tour:React.FC=()=>{
 const f=useCurrentFrame();const {fps}=useVideoConfig();
 const captions=['悬停，看明细。','点击，看额度、消耗速率和 Token。','批准请求，当场处理。','一轮结束，回复就在这里。','简约、动态、刘海，贴合你的桌面。','深浅主题与设置，在 Windows 上。','订阅、账户与剩余积分。','用量走势与 Token 活跃记录。'];
 return <AbsoluteFill style={{fontFamily:t.fonts.body,color:t.colors.ink}}>
  <Background/>
  {chapters.map((item,i)=><Sequence key={item.file} from={i*4*fps} durationInFrames={4*fps}>
    <AbsoluteFill>
      <OffthreadVideo muted src={staticFile(`footage-v2/${item.file}.mp4`)} style={{position:'absolute',left:192,top:0,width:1536,height:960}}/>
      <Enter delay={.14} style={{position:'absolute',left:200,right:200,top:985,textAlign:'center',fontSize:29,fontWeight:600,textShadow:`0 2px 12px ${t.colors.black}`}}>{captions[i]}</Enter>
    </AbsoluteFill>
  </Sequence>)}
  <Sequence from={32*fps} durationInFrames={4*fps}>
    <AbsoluteFill style={{justifyContent:'center',alignItems:'center'}}>
      <Enter style={{fontSize:74,fontWeight:650,letterSpacing:-2}}>Agent HUD Open</Enter>
      <Enter delay={.12} style={{fontSize:30,color:t.colors.muted,marginTop:30}}>Windows 移植开发预览</Enter>
      <Enter delay={.25} style={{fontSize:25,color:t.colors.ink,marginTop:65}}>原作 / jazzenchen · Windows port / nanhudev</Enter>
      <Enter delay={.36} style={{fontSize:24,color:t.colors.muted,marginTop:20}}>github.com/jazzenchen/agent-hud-open</Enter>
      <Enter delay={.5} style={{fontSize:20,color:t.colors.muted,marginTop:48}}>非原作者官方 Windows 发行版</Enter>
    </AbsoluteFill>
  </Sequence>
  <div style={{position:'absolute',left:32,top:22,fontSize:18,color:t.colors.muted}}>Agent HUD Open / Windows preview</div>
  <div style={{position:'absolute',left:32,bottom:18,fontSize:16,color:t.colors.muted}}>示例账户 · 用量、积分与 Token 记录为演示数据</div>
  <AbsoluteFill style={{pointerEvents:'none',background:`linear-gradient(135deg,${t.colors.bg}04,transparent 45%,${t.colors.bgAlt}05)`,mixBlendMode:'soft-light'}}/>
  <AbsoluteFill style={{pointerEvents:'none',opacity:.012,backgroundImage:`url("data:image/svg+xml,%3Csvg viewBox='0 0 180 180' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")`}}/>
  <AbsoluteFill style={{pointerEvents:'none',boxShadow:`inset 0 0 100px ${t.colors.black}22`}}/>
  <Audio src={staticFile('soundtrack.wav')} endAt={36*fps} volume={(frame)=>.68*interpolate(frame,[34.5*fps,36*fps],[1,0],{...clamp,easing:t.ease.inOut})}/>
 </AbsoluteFill>;
};
const Root=()=> <><Composition id='WindowsPromo' component={Film} durationInFrames={1200} fps={30} width={1920} height={1080}/><Composition id='OriginalStyleTour' component={Tour} durationInFrames={1080} fps={30} width={1920} height={1080}/></>;
registerRoot(Root);
