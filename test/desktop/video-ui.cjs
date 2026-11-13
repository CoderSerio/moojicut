// Run with: electron test/desktop/video-ui.cjs
const {app,BrowserWindow,ipcMain}=require('electron');
const fs=require('node:fs/promises');
const path=require('node:path');const os=require('node:os');const {pathToFileURL}=require('node:url');
const temp=require('node:fs').mkdtempSync(path.join(os.tmpdir(),'mooncap-video-ui-smoke-'));
const root=path.resolve(__dirname,'../..');
app.setPath('userData',temp+'/profile');
app.whenReady().then(async()=>{
 const {findExecutable,runProcess}=await import(pathToFileURL(root+'/src/main/media-tools.mjs'));
 const fixture=temp+'/fixture.webm';
 await runProcess(await findExecutable('ffmpeg'),['-v','error','-f','lavfi','-i','testsrc2=size=640x360:rate=30','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','6','-c:v','libvpx','-deadline','realtime','-c:a','libopus',fixture]);
 ipcMain.handle('fixture:recording',()=>({id:'fixture',url:pathToFileURL(fixture).href,state:'complete',durationMs:6000,width:640,height:360,hasAudio:true,frameRate:30}));
 const win=new BrowserWindow({show:false,width:1100,height:800,webPreferences:{preload:__dirname+'/video-ui-preload.cjs',contextIsolation:true,sandbox:false,backgroundThrottling:false}});
 win.webContents.on('console-message',(_event,level,message)=>process.stdout.write('console '+level+' '+message+'\n'));
 await win.loadFile(root+'/src/renderer/video-editor.html',{query:{id:'fixture'}});
 await win.webContents.executeJavaScript(`new Promise((resolve,reject)=>{const until=Date.now()+10000;const check=()=>{if(document.getElementById('confirm')&&document.getElementById('source-video').readyState>=2)resolve();else if(Date.now()>until)reject(new Error('Video UI did not become ready'));else setTimeout(check,50);};check();})`);
 const result=await win.webContents.executeJavaScript(`(async()=>{
 const field=(id,value)=>{const element=document.getElementById(id);element.value=value;element.dispatchEvent(new Event('change',{bubbles:true}));};
 const click=id=>document.getElementById(id).click();
 const pause=()=>new Promise(resolve=>setTimeout(resolve,80));
 const initial={title:document.title,buttons:document.querySelectorAll('button').length,width:document.getElementById('preview-canvas').width,loaded:document.getElementById('source-video').readyState,message:document.getElementById('message').textContent};
 field('cut-start','1');field('cut-end','2');click('delete-cut');await pause();
 field('cut-start','3');field('cut-end','4');click('delete-cut');await pause();
 const cutDuration=document.getElementById('output-duration').textContent;
 click('undo');await pause();const undoDuration=document.getElementById('output-duration').textContent;
 click('redo');await pause();
 field('crop-x','10');field('crop-y','10');field('crop-width','401');field('crop-height','201');click('apply-crop');await pause();
 const crop=[document.getElementById('preview-canvas').width,document.getElementById('preview-canvas').height];
 document.getElementById('mute').checked=true;document.getElementById('mute').dispatchEvent(new Event('change',{bubbles:true}));await pause();
 const muted=document.getElementById('source-video').muted;
 click('confirm');await pause();
 return{initial,cutDuration,undoDuration,crop,muted,message:document.getElementById('message').textContent,exportVisible:!document.getElementById('export-actions').hidden};
 })()`);
 process.stdout.write(JSON.stringify(result)+'\n');
 if(process.env.MOONCAP_SMOKE_OUTPUT) await fs.writeFile(process.env.MOONCAP_SMOKE_OUTPUT,(await win.webContents.capturePage()).toPNG());
 if(result.initial.buttons<10||result.initial.loaded<2||result.cutDuration!=='00:04.0'||result.undoDuration!=='00:05.0'||result.crop[0]!==400||result.crop[1]!==200||!result.muted||!result.exportVisible) throw new Error('UI smoke did not satisfy expected workflow');
 win.destroy();await fs.rm(temp,{recursive:true,force:true});app.exit(0);
}).catch(error=>{process.stderr.write(error.stack+'\n');app.exit(1);});
