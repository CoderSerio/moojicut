const { app, BrowserWindow, desktopCapturer, systemPreferences, screen } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
app.setPath('userData',path.resolve('.artifacts/capture-platform-data'));
// Keep the harness alive for the native lookup after the fixture is destroyed.
app.on('window-all-closed',()=>{});
app.whenReady().then(async () => {
  const permission = process.platform==='darwin' ? systemPreferences.getMediaAccessStatus('screen') : 'granted';
  if (permission!=='granted') { console.log(JSON.stringify({status:'not-tested',reason:'screen-permission',permission})); app.exit(0); return; }
  let win;
  try {
    win = new BrowserWindow({width:640,height:480,show:true,title:'Mooncap generated capture fixture',webPreferences:{sandbox:true,contextIsolation:true}});
    await win.loadURL('data:text/html,'+encodeURIComponent('<html><body style="margin:0;background:rgb(21,86,164);color:white;display:grid;place-items:center;height:100vh;font:24px sans-serif">Mooncap · generated test window</body></html>'));
    await new Promise(resolve=>setTimeout(resolve,400));
    const id=win.getMediaSourceId();
    const { captureDimensions } = await import(pathToFileURL(path.resolve('src/main/capture-platform.mjs')).href);
    const display=screen.getDisplayMatching(win.getBounds());
    const requested=await captureDimensions(id,display);
    if(process.platform==='darwin') assert.deepEqual(requested,{width:Math.round(640*display.scaleFactor),height:Math.round(480*display.scaleFactor)},'native window bounds must not upscale a small window to the display or a 4096px thumbnail');
    const sources=await desktopCapturer.getSources({types:['window'],thumbnailSize:requested});
    const source=sources.find(item=>item.id===id);assert.ok(source&&!source.thumbnail.isEmpty());
    const size=source.thumbnail.getSize(), bitmap=source.thumbnail.toBitmap();
    if(process.platform==='darwin') assert.deepEqual(size,requested,'captured pixels must match the physical window size');
    const offset=(Math.floor(size.height*.8)*size.width+Math.floor(size.width*.25))*4;
    const rgb=[bitmap[offset+2],bitmap[offset+1],bitmap[offset]];
    // macOS display color management may transform RGB; verify this is the generated blue fixture.
    assert.ok(Math.abs(rgb[0]-21)<=20&&Math.abs(rgb[1]-86)<=20&&Math.abs(rgb[2]-164)<=20,`unexpected captured pixel ${rgb}`);
    fs.mkdirSync('.artifacts/platform-qa',{recursive:true});
    fs.writeFileSync('.artifacts/platform-qa/generated-window.png',source.thumbnail.toPNG());
    win.destroy();
    // The WindowServer can retain the closing window through its animation.
    await new Promise(resolve=>setTimeout(resolve,400));
    if(process.platform==='darwin') await assert.rejects(()=>captureDimensions(id,display),/无法读取窗口的真实尺寸/,'a closed window must fail instead of silently falling back to an oversized capture');
    const result={status:'passed',permission,source:'own-generated-window',size,requested,rgb,display:display.scaleFactor,nativeWindowSize:process.platform==='darwin'?'verified':'not-implemented',closedWindowRejected:process.platform==='darwin'};
    fs.writeFileSync('.artifacts/platform-qa/capture-result.json',JSON.stringify(result,null,2));
    console.log(JSON.stringify(result));
    app.exit(0);
  } catch(error) { console.error(error);win?.destroy();app.exit(1); }
});
