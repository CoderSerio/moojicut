import {app,BrowserWindow,ipcMain,nativeImage} from 'electron';
import {resolve} from 'node:path';
import {mkdirSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {image_create,image_apply,image_finalize} from '../dist/core/core.mjs';
app.setPath('userData',resolve('.artifacts/image-ui-smoke-data'));
const svg='<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="900"><rect width="1200" height="900" fill="#f8f4e9"/><rect x="30" y="30" width="1140" height="80" fill="#dae5ed"/><text x="70" y="83" font-family="sans-serif" font-size="35">Mooncap 测试画面 · Human + Agent</text><path d="M40 250H1100M40 400H1100M40 550H1100" stroke="#99aabb" stroke-width="3"/></svg>';
let session={id:'test-image',mode:'overlay',imageUrl:`data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`,document:JSON.parse(image_create(JSON.stringify({width:1200,height:900,viewport:null}))).document};let completed=null;
ipcMain.handle('test:get',()=>session);
ipcMain.handle('test:pin',()=>({id:session.id,session}));
ipcMain.handle('test:pin-action',()=>({ok:true}));
ipcMain.handle('test:apply',(_e,command,expectedRevision)=>{const r=JSON.parse(image_apply(JSON.stringify({document:session.document,command,expectedRevision})));if(!r.ok)throw new Error(r.error.message);session={...session,document:r.document};win.webContents.send('test:changed',{id:session.id,document:r.document});return session;});
ipcMain.handle('test:complete',async(_e,action,bytes,revision)=>{
 assert.equal(revision,session.document.revision);completed={action,bytes:bytes.length,png:Buffer.from(bytes),revision};
 const base={...session.document,annotations:[]};
 const original=await win.webContents.executeJavaScript('window.mooncapRender('+JSON.stringify(base)+')');
 session={...session,document:JSON.parse(image_finalize(JSON.stringify({document:session.document}))).document,mode:'window',completed:true,imageUrl:'data:image/png;base64,'+Buffer.from(original).toString('base64')};
 win.webContents.send('test:changed',session);return{completed:true,session};
});
ipcMain.handle('test:cancel',()=>({ok:true}));
let win;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function wait(fn){for(let i=0;i<100;i++){if(await fn())return;await sleep(30);}throw Error('Timed out');}
async function js(code){return win.webContents.executeJavaScript(code);}
async function drag(x,y,x2,y2){win.webContents.sendInputEvent({type:'mouseDown',x,y,button:'left',clickCount:1});win.webContents.sendInputEvent({type:'mouseMove',x:x2,y:y2,button:'left'});win.webContents.sendInputEvent({type:'mouseUp',x:x2,y:y2,button:'left',clickCount:1});await sleep(80);}
console.log('smoke boot');setTimeout(()=>{console.error('Smoke overall timeout');app.exit(2);},20000);
async function run(){try{
 await app.whenReady();console.log('app ready');win=new BrowserWindow({width:1000,height:750,show:false,webPreferences:{preload:resolve('test/image-ui-preload.cjs'),contextIsolation:true,sandbox:true}});
 win.webContents.on('console-message',(_e,details)=>{if(details.level==='error')console.error(details.message);});
 console.log('window ready');await win.loadFile(resolve('src/renderer/image-editor.html'));console.log('loaded');await js('window.mooncapImageReady');console.log('ui ready');
 await drag(80,130,850,550);await wait(()=>session.document.viewport!==null);await wait(()=>js('document.querySelectorAll(".toolbar button").length===13'));
 const initial=session.document.viewport;assert.ok(initial.width>900);console.log('region + Rabbita 13 tools',initial);
 const geometry=await js('({width:innerWidth,height:innerHeight})');assert.equal(initial.x,Math.round(80*1200/geometry.width));assert.equal(initial.y,Math.round(130*900/geometry.height));
 await js('window.mooncapImageAction("tool","crop")');await drag(80,130,40,100);assert.ok(session.document.viewport.width>initial.width);assert.ok(session.document.viewport.x<initial.x);await js('window.mooncapImageAction("undo","")');assert.deepEqual(session.document.viewport,initial);
 await js('window.mooncapImageAction("tool","shape")');await drag(200,220,380,320);await wait(()=>session.document.annotations.length===1);assert.equal(session.document.annotations[0].type,'rect');
 await js('window.mooncapImageAction("tool","marker")');await drag(230,350,600,350);await wait(()=>session.document.annotations.length===2);assert.equal(session.document.annotations[1].opacity,.3);
 await js('window.mooncapImageAction("tool","redaction")');await js('window.mooncapImageAction("style:effect","mosaic")');await drag(500,220,650,290);await wait(()=>session.document.annotations.length===3);assert.equal(session.document.annotations[2].type,'mosaic');
 await js('window.mooncapImageAction("tool","text")');win.webContents.sendInputEvent({type:'mouseDown',x:250,y:400,button:'left',clickCount:1});win.webContents.sendInputEvent({type:'mouseUp',x:250,y:400,button:'left',clickCount:1});await wait(()=>js('!document.getElementById("image-text").hidden'));
 await js('document.getElementById("image-text").dispatchEvent(new CompositionEvent("compositionstart"));window.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",metaKey:true,bubbles:true}));');assert.equal(session.document.annotations.length,3);await js('document.getElementById("image-text").dispatchEvent(new CompositionEvent("compositionend"));');await sleep(90);
 await js('document.getElementById("image-text").value="中文输入测试\\n第二行";document.getElementById("image-text").dispatchEvent(new Event("input"));window.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",metaKey:true,bubbles:true}));');await wait(()=>session.document.annotations.length===4);assert.equal(session.document.annotations[3].text,'中文输入测试\n第二行');
 await js('window.mooncapImageAction("tool","select")');await js('window.mooncapImageAction("undo","")');assert.equal(session.document.annotations.length,3);await js('window.mooncapImageAction("redo","")');assert.equal(session.document.annotations.length,4);
 await js('window.mooncapImageAction("copy","")');assert.ok(completed.bytes>1000);assert.equal(completed.action,'copy');
 await wait(()=>js('document.getElementById("image-stage").width==='+session.document.width));
 const png=await js('window.mooncapRender(window.mooncapImageUiState ? '+JSON.stringify(session.document)+':null)');assert.ok(png.length>1000);const a=nativeImage.createFromBuffer(Buffer.from(png)).toBitmap(),b=nativeImage.createFromBuffer(completed.png).toBitmap();let delta=0;for(let i=0;i<a.length;i++)if(a[i]!==b[i])delta++;console.log('rebase channel difference',delta);assert.equal(delta,0,'rebase keeps exact pixels');
 mkdirSync('.artifacts/image-ui-qa',{recursive:true});writeFileSync('.artifacts/image-ui-qa/render.png',Buffer.from(png));writeFileSync('.artifacts/image-ui-qa/editor.png',(await win.webContents.capturePage()).toPNG());
 const rendering=await js(`(async()=>{
 const {renderDocument}=await import('./image-render.mjs');
 const src=document.createElement('canvas');src.width=200;src.height=200;const sc=src.getContext('2d');sc.fillStyle='white';sc.fillRect(0,0,200,200);
 const mark={id:'m',type:'marker',x:20,y:40,points:[{x:20,y:40},{x:150,y:40},{x:20,y:40}],color:'#ff0000',stroke:20,opacity:.3};
 const base={width:200,height:200,viewport:{x:0,y:0,width:200,height:200},annotations:[mark]};
 const once=renderDocument(base,src).getContext('2d').getImageData(80,40,1,1).data[1];
 const twice=renderDocument({...base,annotations:[mark,{...mark,id:'m2'}]},src).getContext('2d').getImageData(80,40,1,1).data[1];
 for(let x=0;x<200;x++){sc.fillStyle='rgb('+x+', '+(255-x)+', 100)';sc.fillRect(x,0,1,200);}
 const v={x:35,y:25,width:80,height:70},m={id:'pix',type:'mosaic',x:10,y:10,width:150,height:100,blockSize:12,stroke:3,color:'#000000',opacity:1};
 const a=renderDocument({...base,viewport:v,annotations:[m]},src).getContext('2d').getImageData(0,0,80,70).data;
 const cropped=document.createElement('canvas');cropped.width=80;cropped.height=70;cropped.getContext('2d').drawImage(src,35,25,80,70,0,0,80,70);
 const b=renderDocument({width:80,height:70,viewport:{x:0,y:0,width:80,height:70},annotations:[{...m,x:-25,y:-15}]},cropped).getContext('2d').getImageData(0,0,80,70).data;
 return {once,twice,rebaseEqual:a.every((x,i)=>x===b[i])};
})()`);assert.ok(rendering.once>=177&&rendering.once<=180);assert.ok(rendering.twice<rendering.once);assert.equal(rendering.rebaseEqual,true);
 await win.reload();await wait(()=>js('Boolean(window.mooncapImageReady)'));await js('window.mooncapImageReady');const reopened=await js('window.mooncapRender('+JSON.stringify(session.document)+')');assert.equal(nativeImage.createFromBuffer(Buffer.from(reopened)).toBitmap().equals(nativeImage.createFromBuffer(completed.png).toBitmap()),true,'history reopen uses cropped source with editable vectors');
 const pin=new BrowserWindow({width:640,height:480,show:false,webPreferences:{preload:resolve('test/image-ui-preload.cjs'),contextIsolation:true,sandbox:true}});
 await pin.loadFile(resolve('src/renderer/pin.html'));await pin.webContents.executeJavaScript('window.mooncapPinReady');
 const previous=session.document;
 const updated=JSON.parse(image_apply(JSON.stringify({document:previous,command:{type:'update',id:previous.annotations[0].id,patch:{color:'#0044ff'}},expectedRevision:previous.revision}))).document;
 pin.webContents.send('test:changed',{id:session.id,document:updated});await wait(()=>pin.webContents.executeJavaScript('document.getElementById("image").dataset.revision==="'+updated.revision+'"'));
 pin.webContents.send('test:changed',{id:session.id,document:previous});await sleep(40);assert.equal(await pin.webContents.executeJavaScript('Number(document.getElementById("image").dataset.revision)'),updated.revision);pin.destroy();
 console.log('PASS: pin live update + stale revision guard, C enlarge/undo, history reopen + rebase, shapes, highlighter alpha, mosaic rebase equality, Chinese composition guard, undo/redo, PNG export and revision checked completion');app.exit(0);
}catch(error){console.error(error);app.exit(1);}

}
void run();
