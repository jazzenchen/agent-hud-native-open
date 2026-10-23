import {Easing} from 'remotion';
export const theme={
 colors:{bg:'#07121e',bgAlt:'#17334a',hero:'#76e5b6',ink:'#f3f6fa',muted:'#a7bdcc',line:'rgba(220,237,248,.16)',glass:'rgba(18,39,55,.65)',black:'#000000'},
 fonts:{display:'Segoe UI, Microsoft YaHei UI, sans-serif',body:'Segoe UI, Microsoft YaHei UI, sans-serif',mono:'Consolas, monospace'},
 ease:{out:Easing.bezier(.16,1,.3,1),inOut:Easing.bezier(.83,0,.17,1),in:Easing.bezier(.7,0,.84,0)},
 spring:{smooth:{damping:23,stiffness:110,mass:1},snappy:{damping:20,stiffness:180,mass:.7}}
};
