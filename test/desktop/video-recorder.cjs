// Run with: electron test/desktop/video-recorder.cjs
const {app,BrowserWindow,ipcMain}=require('electron');
const fs=require('node:fs/promises');const {pathToFileURL}=require('node:url');const assert=require('node:assert/strict');
const path=require('node:path');const os=require('node:os');const temp=require('node:fs').mkdtempSync(path.join(os.tmpdir(),'mooncap-recorder-smoke-'));
const root=path.resolve(__dirname,'../..');
app.setPath('userData',temp+'/profile');
let win,store,timeout;
function fail(error){process.stderr.write(String(error?.stack||error)+'\n');app.exit(1);}
app.whenReady().then(async()=>{
 const {RecordingStore}=await import(pathToFileURL(root+'/src/main/recording-store.mjs'));
 const {findExecutable,runProcess}=await import(pathToFileURL(root+'/src/main/media-tools.mjs'));
 store=new RecordingStore(temp+'/recordings');await store.initialize();
 ipcMain.handle('fixture:ready',async()=>{
  await win.webContents.executeJavaScript(`(()=>{const canvas=document.createElement('canvas');canvas.width=320;canvas.height=240;const ctx=canvas.getContext('2d');const draw=()=>{ctx.fillStyle='#ff0000';ctx.fillRect(0,0,160,240);ctx.fillStyle='#0000ff';ctx.fillRect(160,0,160,240);};draw();window.fixtureTimer=setInterval(draw,30);const stream=canvas.captureStream(30);navigator.mediaDevices.getDisplayMedia=async()=>stream;})();`);
  win.webContents.send('fixture:prepare',{sourceId:'fixture',sourceWidth:320,sourceHeight:240,region:{x:160,y:0,width:160,height:240},microphone:false,systemAudio:false,cursor:false});
 });
 ipcMain.handle('fixture:prepared',()=>{win.webContents.send('fixture:start');});
 ipcMain.handle('fixture:started',()=>{setTimeout(()=>win.webContents.send('fixture:stop'),1500);});
 ipcMain.handle('fixture:failed',(_,message)=>fail(message));
 ipcMain.handle('fixture:begin',(_,value)=>store.begin(value));
 ipcMain.handle('fixture:append',(_,id,seq,bytes)=>store.append(id,seq,bytes));
 ipcMain.handle('fixture:abort',(_,id)=>store.abort(id));
 ipcMain.handle('fixture:finish',async(_,id)=>{
  try{
   const record=await store.finish(id);assert.equal(record.width,160);assert.equal(record.height,240);assert.equal(record.hasAudio,false);assert.ok(record.durationMs>=1000);
   const filename=temp+'/pixel.rgb';await fs.rm(filename,{force:true});
   await runProcess(await findExecutable('ffmpeg'),['-v','error','-i',store.get(id).filename,'-frames:v','1','-vf','scale=1:1','-f','rawvideo','-pix_fmt','rgb24',filename]);
   const pixel=await fs.readFile(filename);assert.ok(pixel[2]>200&&pixel[0]<40,`Expected only right-half blue pixels, got ${[...pixel]}`);
   process.stdout.write(JSON.stringify({record,pixel:[...pixel]})+'\n');clearTimeout(timeout);setTimeout(()=>{win.destroy();fs.rm(temp,{recursive:true,force:true}).finally(()=>app.exit(0));},150);return record;
  }catch(error){fail(error);}
 });
 win=new BrowserWindow({show:false,width:600,height:400,webPreferences:{preload:__dirname+'/video-recorder-preload.cjs',sandbox:false,contextIsolation:true,backgroundThrottling:false}});
 win.webContents.on('console-message',(_,level,message)=>process.stdout.write('console '+level+' '+message+'\n'));
 timeout=setTimeout(()=>fail('Timed out waiting for recorder'),20000);
 await win.loadFile(root+'/src/renderer/recorder.html');
}).catch(fail);
