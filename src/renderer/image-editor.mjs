import { image_apply } from '../../dist/core/core.mjs';
import { loadSource, renderDocument, pngBytes, bounds, hitObjects, textLayout } from './image-render.mjs';

const api=window.mooncap,canvas=document.getElementById('image-stage'),ctx=canvas.getContext('2d'),tools=document.getElementById('image-tools'),textBox=document.getElementById('image-text'),menu=document.getElementById('image-menu');
let session,source,sourceUrl,tool='select',selected=null,gesture=null,preview=null,busy=false,composing=false,compositionEnded=0,textEdit=null,lastHit=null,stylePreview=null,queuedFrame=0;
const basic={color:'#ef4444',stroke:3,opacity:1,fill:false,shape:'rect',dash:false,arrowHead:'end',fontSize:24,bold:false,align:'left',effect:'redact',blockSize:12};
const defaults={shape:{...basic},arrow:{...basic},pencil:{...basic},marker:{...basic,color:'#facc15',stroke:24,opacity:.3},redaction:{...basic,color:'#000000'},text:{...basic}};
try{const saved=JSON.parse(localStorage.getItem('mooncap.image.styles.v1')||'{}');for(const key of Object.keys(defaults))Object.assign(defaults[key],saved[key]);}catch{}
const names={select:'选择与移动',crop:'调整选区',shape:'形状',arrow:'线条',pencil:'画笔',marker:'荧光笔',redaction:'遮挡',text:'文字',eraser:'擦除整条标注'};
function notice(message){const el=document.getElementById('image-notice');el.textContent=message;el.hidden=!message;}
function current(){return session?.document;}
function chosen(){return current()?.annotations.find(a=>a.id===selected);}
function effective(){return preview||current();}
function coordinates(event){const r=canvas.getBoundingClientRect();return {x:Math.max(0,Math.min(current().width,(event.clientX-r.left)*current().width/r.width)),y:Math.max(0,Math.min(current().height,(event.clientY-r.top)*current().height/r.height))};}
function scale(){return canvas.getBoundingClientRect().width/current().width;}
function normalized(a,b){const x=Math.round(Math.min(a.x,b.x)),y=Math.round(Math.min(a.y,b.y));return {x,y,width:Math.round(Math.max(a.x,b.x))-x,height:Math.round(Math.max(a.y,b.y))-y};}
function changedState(){
  if(!current())return;
  const item=stylePreview?.item||chosen(),style={...(item||defaults[tool]||basic)};style.opacityPercent=Math.round((style.opacity??1)*100);
  const state={tool,kind:item?.type||tool,selected:Boolean(item),style,canUndo:!!current().undo.length,canRedo:!!current().redo.length,busy,status:busy?'正在处理…':item?'编辑已选对象':names[tool]};
  window.mooncapImageUiState=state;window.dispatchEvent(new CustomEvent('mooncap:image-ui',{detail:JSON.stringify(state)}));
  requestAnimationFrame(placeTools);
}
async function accept(value){
  if(!value)return;
  if(value.session)value=value.session;
  if(value.id&&session&&value.id!==session.id)return;
  if(value.document&&session?.document&&value.document.revision<session.document.revision)return;
  session={...session,...value};
  if(session.imageUrl&&session.imageUrl!==sourceUrl){sourceUrl=session.imageUrl;source=await loadSource(sourceUrl);}
  if(selected&&!chosen())selected=null;
  if(!gesture&&!stylePreview)preview=null;
  layout();changedState();schedulePaint();
}
async function apply(command,revision=current().revision){
  if(busy)return false;
  busy=true;changedState();notice('');
  try{await accept(await api.applyImageCommand(session.id,command,revision));return true;}
  catch(error){preview=null;notice(error.message||String(error));try{await accept(await api.getImageSession());}catch{}return false;}
  finally{busy=false;changedState();schedulePaint();}
}
function previewCommand(command,base=gesture?.document||current()){
  const result=JSON.parse(image_apply(JSON.stringify({document:{...base,undo:[],redo:[]},command,expectedRevision:base.revision})));
  if(result.ok){preview=result.document;schedulePaint();}return result.ok;
}
function layout(){
  if(!current())return;const d=current();canvas.width=d.width;canvas.height=d.height;
  let width=innerWidth,height=innerHeight,left=0,top=0;
  if(session.mode!=='overlay'){const s=Math.min((innerWidth-40)/d.width,(innerHeight-180)/d.height,1);width=d.width*s;height=d.height*s;left=(innerWidth-width)/2;top=Math.max(20,(innerHeight-height-120)/2);}
  Object.assign(canvas.style,{width:`${width}px`,height:`${height}px`,left:`${left}px`,top:`${top}px`});placeTools();
}
function placeTools(){
  const d=effective();if(!d)return;const v=gesture?.kind==='region'?gesture.rect:d.viewport;tools.hidden=!d.viewport;document.getElementById('selection-help').hidden=!!v;
  if(!v){document.getElementById('size-label').hidden=true;return;}
  const r=canvas.getBoundingClientRect(),sx=r.width/d.width,sy=r.height/d.height;
  const box={x:r.left+v.x*sx,y:r.top+v.y*sy,width:v.width*sx,height:v.height*sy};
  const w=tools.offsetWidth,h=tools.offsetHeight;
  const left=Math.max(8,Math.min(innerWidth-w-8,box.x+box.width-w));
  let top=box.y+box.height+9;if(top+h>innerHeight-8)top=box.y-h-9;if(top<8)top=Math.max(8,innerHeight-h-8);
  Object.assign(tools.style,{left:`${left}px`,top:`${top}px`});
  const label=document.getElementById('size-label');label.hidden=false;label.textContent=`${v.width} × ${v.height} px`;label.style.left=`${Math.max(4,box.x)}px`;label.style.top=`${Math.max(3,box.y-25)}px`;
}
function handles(item){
  if(item.type==='arrow')return [{x:item.x,y:item.y,key:'start'},{x:item.x2,y:item.y2,key:'end'}];
  if(['pencil','marker'].includes(item.type))return [];
  const b=item.type?bounds(item,ctx):item;
  if(item.type==='text')return [{x:b.x+b.width,y:b.y+b.height/2,key:'e'}];
  return [['nw',0,0],['n',.5,0],['ne',1,0],['e',1,.5],['se',1,1],['s',.5,1],['sw',0,1],['w',0,.5]].map(([key,x,y])=>({key,x:b.x+b.width*x,y:b.y+b.height*y}));
}
function drawOutline(item,showHandles=true){
  const b=item.type?bounds(item,ctx):item,s=scale();ctx.save();ctx.strokeStyle='#9bd3ff';ctx.lineWidth=1/s;ctx.setLineDash([4/s,3/s]);ctx.strokeRect(b.x,b.y,b.width,b.height);ctx.setLineDash([]);
  if(showHandles)for(const h of handles(item)){ctx.fillStyle='#fff';ctx.strokeStyle='#197db4';ctx.fillRect(h.x-3/s,h.y-3/s,6/s,6/s);ctx.strokeRect(h.x-3/s,h.y-3/s,6/s,6/s);}ctx.restore();
}
function paint(){
  queuedFrame=0;if(!source||!current())return;const d=effective();ctx.clearRect(0,0,canvas.width,canvas.height);const visible=textEdit?.existing?{...d,annotations:d.annotations.filter(a=>a.id!==textEdit.item.id)}:d;
  ctx.drawImage(source,0,0,d.width,d.height);if(d.viewport)ctx.drawImage(renderDocument(visible,source),d.viewport.x,d.viewport.y);
  let v=d.viewport;if(gesture?.kind==='region')v=gesture.rect;
  if(session.mode==='overlay'){
    ctx.save();ctx.fillStyle='#080d16a8';ctx.beginPath();ctx.rect(0,0,d.width,d.height);if(v)ctx.rect(v.x,v.y,v.width,v.height);ctx.fill('evenodd');ctx.restore();
  }
  if(v){drawOutline(v,tool==='crop');if(tool==='select'&&selected){const item=d.annotations.find(a=>a.id===selected);if(item)drawOutline(item);}}
  placeTools();
}
function schedulePaint(){if(!queuedFrame)queuedFrame=requestAnimationFrame(paint);}
function newItem(p){const s=defaults[tool]||basic;return {...s,id:crypto.randomUUID(),type:tool==='shape'?s.shape:tool==='redaction'?s.effect:tool,x:p.x,y:p.y,width:1,height:1,x2:p.x,y2:p.y};}
function handleAt(item,p){return handles(item).find(h=>Math.hypot(h.x-p.x,h.y-p.y)<=7/scale());}
function resizeRect(b,key,p){let x=b.x,y=b.y,right=x+b.width,bottom=y+b.height;if(key.includes('w'))x=p.x;if(key.includes('e'))right=p.x;if(key.includes('n'))y=p.y;if(key.includes('s'))bottom=p.y;return normalized({x,y},{x:right,y:bottom});}
function translateItem(item,dx,dy){return {...item,x:item.x+dx,y:item.y+dy,...(item.x2!==undefined?{x2:item.x2+dx,y2:item.y2+dy}:{}),...(item.points?{points:item.points.map(p=>({x:p.x+dx,y:p.y+dy}))}:{})};}
canvas.addEventListener('pointerdown',async event=>{
  if(!current()||busy||event.button!==0)return;
  menu.hidden=true;if(textEdit){await finishText();return;}
  const p=coordinates(event),d=current();canvas.setPointerCapture(event.pointerId);canvas.focus();stylePreview=null;
  const base={start:p,document:d,revision:d.revision,moved:false};
  if(!d.viewport){gesture={...base,kind:'region'};return;}
  if(tool==='crop'){
    const h=handleAt(d.viewport,p),v=d.viewport;
    if(!h&&(p.x<v.x||p.x>v.x+v.width||p.y<v.y||p.y>v.y+v.height))return;
    gesture={...base,kind:h?'crop-resize':'crop-move',handle:h?.key,rect:v};return;
  }
  if(tool==='select'){
    const item=chosen(),h=item&&handleAt(item,p);
    if(h){gesture={...base,kind:'resize',item,handle:h.key};return;}
    const hits=hitObjects(d,p,ctx,5/scale());
    let index=0;if(lastHit&&Math.hypot(lastHit.x-p.x,lastHit.y-p.y)<3/scale()&&Date.now()-lastHit.time<1500)index=(lastHit.index+1)%Math.max(1,hits.length);
    selected=hits[index]?.id||null;lastHit={...p,index,time:Date.now()};const target=chosen();
    if(target)gesture={...base,kind:'move',item:target};changedState();schedulePaint();return;
  }
  if(tool==='text'){startText(newItem(p));return;}
  if(tool==='eraser'){gesture={...base,kind:'erase',ids:new Set()};updateGesture(event);return;}
  gesture={...base,kind:'draw',item:newItem(p)};
  if(tool==='pencil'||tool==='marker')gesture.item.points=[p];
});
function updateGesture(event){
  const g=gesture;if(!g)return;const p=coordinates(event);g.moved ||= Math.hypot(p.x-g.start.x,p.y-g.start.y)*scale()>2;
  if(g.kind==='region'){g.rect=normalized(g.start,p);schedulePaint();return;}
  let command;
  if(g.kind==='move')command={type:'update',id:g.item.id,patch:translateItem(g.item,p.x-g.start.x,p.y-g.start.y)};
  else if(g.kind==='resize'){
    let patch;if(g.item.type==='arrow')patch=g.handle==='start'?{x:p.x,y:p.y}:{x2:p.x,y2:p.y};else patch=resizeRect(bounds(g.item,ctx),g.handle,p);
    if(g.item.type==='text'){patch={width:Math.max(20,p.x-g.item.x)};patch.height=textLayout({...g.item,...patch},ctx).height;}
    if(patch.width===0||patch.height===0)return;command={type:'update',id:g.item.id,patch};
  } else if(g.kind==='crop-resize'||g.kind==='crop-move'){
    let rect;if(g.kind==='crop-resize')rect=resizeRect(g.rect,g.handle,p);else rect={...g.rect,x:Math.round(Math.max(0,Math.min(current().width-g.rect.width,g.rect.x+p.x-g.start.x))),y:Math.round(Math.max(0,Math.min(current().height-g.rect.height,g.rect.y+p.y-g.start.y)))};
    if(rect.width<1||rect.height<1)return;command={type:'crop',rect};
  } else if(g.kind==='erase'){
    for(const hit of hitObjects(g.document,p,ctx,8/scale()))g.ids.add(hit.id);
    if(g.ids.size)command={type:'remove',ids:[...g.ids]};
  } else if(g.kind==='draw'){
    let item={...g.item};
    if(item.points){const last=item.points.at(-1);if(Math.hypot(last.x-p.x,last.y-p.y)>=.8&&item.points.length<12000)item.points.push(p);if(item.points.length<2)return;}
    else if(item.type==='arrow'){
      let x2=p.x,y2=p.y;if(event.shiftKey){const len=Math.hypot(p.x-item.x,p.y-item.y),a=Math.round(Math.atan2(p.y-item.y,p.x-item.x)/(Math.PI/4))*Math.PI/4;x2=item.x+Math.cos(a)*len;y2=item.y+Math.sin(a)*len;}item={...item,x2,y2};
    } else {
      let end=p;if(event.shiftKey&&['rect','ellipse'].includes(item.type)){const n=Math.max(Math.abs(p.x-item.x),Math.abs(p.y-item.y));end={x:Math.max(0,Math.min(current().width,item.x+Math.sign(p.x-item.x)*n)),y:Math.max(0,Math.min(current().height,item.y+Math.sign(p.y-item.y)*n))};}
      item={...item,...normalized(g.start,end)};if(!item.width||!item.height)return;
    }
    command={type:'add',annotations:[item]};
  }
  if(command&&previewCommand(command,g.document))g.command=command;
}
canvas.addEventListener('pointermove',event=>{if(gesture)updateGesture(event);});
canvas.addEventListener('pointerup',async event=>{
  if(!gesture)return;updateGesture(event);const g=gesture;gesture=null;preview=null;
  if(g.kind==='region'&&g.rect?.width>=1&&g.rect?.height>=1){tool='select';await apply({type:'crop',rect:g.rect},g.revision);}
  else if(g.command&&(g.moved||g.kind==='erase'))await apply(g.command,g.revision);
  changedState();schedulePaint();
});
function cancelGesture(){gesture=null;preview=null;stylePreview=null;changedState();schedulePaint();}
canvas.addEventListener('pointercancel',cancelGesture);
canvas.addEventListener('dblclick',event=>{
  if(!current()?.viewport){const d=current();void apply({type:'crop',rect:{x:0,y:0,width:d.width,height:d.height}});return;}
  if(tool==='select'){const a=hitObjects(current(),coordinates(event),ctx,5/scale()).find(a=>a.type==='text');if(a)startText(a,true);}
});
function startText(item,existing=false){
  const r=canvas.getBoundingClientRect(),s=scale();item={...item,type:'text',width:existing?item.width:Math.max(30,Math.min(300,current().width-item.x)),height:item.fontSize*1.3,text:item.text||''};
  textEdit={item,existing,revision:current().revision};selected=null;textBox.value=item.text;textBox.hidden=false;
  Object.assign(textBox.style,{left:`${r.left+item.x*s}px`,top:`${r.top+item.y*s}px`,width:`${item.width*s}px`,fontSize:`${item.fontSize*s}px`,fontWeight:item.bold?'700':'400',color:item.color,textAlign:item.align||'left'});
  textBox.style.height=`${Math.max(36,item.height*s)}px`;textBox.focus();textBox.select();changedState();schedulePaint();
}
textBox.addEventListener('input',()=>{textBox.style.height='auto';textBox.style.height=`${Math.max(30,textBox.scrollHeight)}px`;});
textBox.addEventListener('compositionstart',()=>{composing=true;});textBox.addEventListener('compositionend',()=>{composing=false;compositionEnded=performance.now();});
async function finishText(cancel=false){
  if(!textEdit)return true;if(composing){notice('请先完成输入法选词，再确认');return false;}
  const edit=textEdit;textEdit=null;textBox.hidden=true;
  if(cancel){canvas.focus();schedulePaint();return true;}
  const item={...edit.item,text:textBox.value};if(!item.text.trim()){if(edit.existing)await apply({type:'remove',ids:[item.id]},edit.revision);return true;}
  item.height=textLayout(item,ctx).height;
  const ok=await apply(edit.existing?{type:'update',id:item.id,patch:item}:{type:'add',annotations:[item]},edit.revision);canvas.focus();return ok;
}
async function finish(action){
  if(busy||gesture||!current()?.viewport)return;if(!await finishText())return;
  busy=true;changedState();notice('');
  try{const revision=current().revision,bytes=await pngBytes(renderDocument(current(),source));const result=await api.completeImage(session.id,action,bytes,revision);if(result?.canceled||result===null)return;}
  catch(error){notice(error.message||String(error));}
  finally{busy=false;changedState();}
}
function styleValue(key,value){if(['stroke','fontSize','blockSize','opacityPercent'].includes(key))return Number(value);if(['fill','dash','bold'].includes(key))return value==='true';return value;}
async function changeStyle(key,raw,isPreview){
  let value=styleValue(key,raw);if(key==='opacityPercent'){key='opacity';value/=100;}
  if(key==='color'&&!/^#[0-9a-fA-F]{6}$/.test(value)){notice('请输入有效的 #rrggbb 色值');changedState();return;}
  const item=chosen();if(item){
    const base=stylePreview?.base||current();const patch={[key]:value};if(item.type==='text')patch.height=textLayout({...item,...patch},ctx).height;
    if(isPreview){stylePreview={base,item:{...item,...patch}};previewCommand({type:'update',id:item.id,patch},base);}
    else{const revision=stylePreview?.base.revision??current().revision;stylePreview=null;preview=null;await apply({type:'update',id:item.id,patch},revision);}
  }else if(defaults[tool]){defaults[tool][key]=value;if(!isPreview)localStorage.setItem('mooncap.image.styles.v1',JSON.stringify(defaults));}
  changedState();
}
window.mooncapImageAction=async(action,value)=>{
  if(busy)return;
  if(action.startsWith('style:')||action.startsWith('preview:'))return changeStyle(action.split(':')[1],value,action.startsWith('preview:'));
  if(['copy','save','pin'].includes(action))return finish(action);
  if(action==='cancel'){if(textEdit)await finishText(true);return api.cancelImage(session.id);}
  if(action==='tool'){if(!await finishText())return;cancelGesture();selected=null;tool=value;changedState();return;}
  if(action==='undo'||action==='redo'){if(textEdit)return;selected=null;return apply({type:action});}
  if(action==='delete'&&selected)return apply({type:'remove',ids:[selected]});
  if((action==='front'||action==='back')&&selected)return apply({type:'order',id:selected,position:action});
};
canvas.addEventListener('contextmenu',event=>{
  event.preventDefault();if(busy||gesture)return;menu.replaceChildren();
  for(const [label,action,value] of [['选择与移动 V','tool','select'],['调整选区 C','tool','crop'],...(selected?[['删除标注','delete',''],...(!['redact','mosaic'].includes(chosen()?.type)?[['置于顶层','front',''],['置于底层','back','']]:[])]:[])]){
    const button=document.createElement('button');button.textContent=label;button.addEventListener('click',()=>{menu.hidden=true;void window.mooncapImageAction(action,value);});menu.append(button);
  }
  menu.hidden=false;menu.style.left=`${Math.min(event.clientX,innerWidth-menu.offsetWidth-8)}px`;menu.style.top=`${Math.min(event.clientY,innerHeight-menu.offsetHeight-8)}px`;
});
let keyMove=null;
window.addEventListener('keydown',event=>{
  if(event.isComposing||composing||performance.now()-compositionEnded<80)return;
  const input=event.target.matches?.('input,textarea,select');
  if(textEdit){if(event.key==='Escape'){event.preventDefault();void finishText(true);}else if(event.key==='Enter'&&(event.metaKey||event.ctrlKey)){event.preventDefault();void finishText();}return;}
  if(input)return;const mod=event.metaKey||event.ctrlKey;
  if(event.key==='Escape'){
    event.preventDefault();if(!menu.hidden){menu.hidden=true;return;}if(gesture||stylePreview){cancelGesture();return;}if(selected){selected=null;changedState();schedulePaint();return;}void api.cancelImage(session.id);return;
  }
  if(busy)return;
  if(mod&&event.key.toLowerCase()==='z'){event.preventDefault();void window.mooncapImageAction(event.shiftKey?'redo':'undo','');return;}
  if((event.key==='Enter'||mod&&event.key.toLowerCase()==='c')&&!gesture){event.preventDefault();void finish('copy');return;}
  if(mod&&event.key.toLowerCase()==='s'){event.preventDefault();void finish('save');return;}
  if(event.key==='Delete'||event.key==='Backspace'){event.preventDefault();void window.mooncapImageAction('delete','');return;}
  if(selected&&['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key)){
    event.preventDefault();if(!keyMove)keyMove={document:current(),revision:current().revision,dx:0,dy:0,id:selected};const n=event.shiftKey?10:1;keyMove.dx+=event.key==='ArrowLeft'?-n:event.key==='ArrowRight'?n:0;keyMove.dy+=event.key==='ArrowUp'?-n:event.key==='ArrowDown'?n:0;previewCommand({type:'move',id:keyMove.id,dx:keyMove.dx,dy:keyMove.dy},keyMove.document);return;
  }
  const map={v:'select',c:'crop',r:'shape',a:'arrow',p:'pencil',h:'marker',b:'redaction',t:'text',e:'eraser'};if(!mod&&map[event.key.toLowerCase()])void window.mooncapImageAction('tool',map[event.key.toLowerCase()]);
});
window.addEventListener('keyup',event=>{if(keyMove&&event.key.startsWith('Arrow')){const g=keyMove;keyMove=null;preview=null;void apply({type:'move',id:g.id,dx:g.dx,dy:g.dy},g.revision);}});
window.addEventListener('resize',()=>{layout();schedulePaint();});
window.mooncapRender=async(doc,url)=>Array.from(await pngBytes(renderDocument(doc,url?await loadSource(url):source)));
window.mooncapImageReady=(async()=>{
  await accept(await api.getImageSession());
  const unsubscribe=api.onImageChanged(value=>{void accept(value);});
  addEventListener('beforeunload',()=>{unsubscribe?.();if(queuedFrame)cancelAnimationFrame(queuedFrame);});
  await import('../../dist/ui/image.mjs');changedState();canvas.focus();
})().catch(error=>notice(error.message||String(error)));
