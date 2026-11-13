import { video_open, video_command, video_seek, video_dispose } from '../../dist/core/core.mjs';

// This adapter owns DOM/media lifetimes only. MoonBit owns the document, command
// validation, undo/redo, kept intervals, time mapping, crop and export policy.
const api = window.mooncap;
const $ = (id) => document.getElementById(id);
const video = $('source-video'), canvas = $('preview-canvas'), timeline = $('timeline');
const context = canvas.getContext('2d', { alpha: false });
let recording, state, exporting = false, cropMode = false, cropDraft = null, cropGesture = null, timelineGesture = null;
let closeScheduled = false;
let preserveRatio = false, lastExport = null, saveTail = Promise.resolve(), frameHandle = null, disposed = false;
const time = (ms) => `${Math.floor(ms / 60000).toString().padStart(2, '0')}:${(Math.max(0, ms) % 60000 / 1000).toFixed(1).padStart(4, '0')}`;
const decode = (text) => { const result = JSON.parse(text); if (!result.ok) throw new Error(result.error.message); return result; };
const notice = (text, error = false) => { $('message').textContent = text; $('message').classList.toggle('error', error); };
const number = (id) => { const n = Number($(id).value); if (!Number.isFinite(n)) throw new Error('请输入有效数值。'); return n; };
const frameAligned = (ms) => Math.min(recording.durationMs, Math.max(0, Math.round(Math.round(ms * (recording.frameRate || 30) / 1000) * 1000 / (recording.frameRate || 30))));
const secondsField = (id) => frameAligned(number(id) * 1000);
function persist() {
  const document = state.document;
  $('draft-state').textContent = '正在保存草稿…';
  const write = api.saveVideoDraft(recording.id, document);
  saveTail = Promise.all([saveTail.catch(() => {}), write]).then(() => { $('draft-state').textContent = '草稿已保存在本机'; }).catch((error) => { $('draft-state').textContent = '草稿保存失败'; notice(error.message, true); });
}
function edit(command) {
  if (exporting) return;
  try {
    const next = decode(video_command(state.session, JSON.stringify(command)));
    state = next; cropMode = false; cropDraft = null;
    persist(); sync(); resolvePosition(); notice('');
  } catch (error) { sync(); notice(error.message, true); }
}
function sync() {
  const doc = state.document;
  $('trim-start').value = (doc.trim.startMs / 1000).toFixed(3);
  $('trim-end').value = (doc.trim.endMs / 1000).toFixed(3);
  for (const id of ['trim-start', 'trim-end', 'cut-start', 'cut-end']) { $(id).max = recording.durationMs / 1000; $(id).step = '0.001'; }
  const crop = cropDraft || doc.crop || { x: 0, y: 0, width: recording.width, height: recording.height };
  for (const key of ['x', 'y', 'width', 'height']) $(`crop-${key}`).value = crop[key];
  $('mute').checked = doc.muted; $('mute').disabled = exporting || !recording.hasAudio;
  $('preset').value = doc.preset;
  $('undo').disabled = exporting || !state.canUndo; $('redo').disabled = exporting || !state.canRedo;
  $('cut-summary').textContent = doc.cuts.length ? `已记录 ${doc.cuts.length} 次删除，保留 ${state.plan.segments.length} 段` : '尚未删除片段';
  $('output-duration').textContent = time(state.plan.outputDurationMs);
  $('source-duration').textContent = time(recording.durationMs);
  $('source-size').textContent = `${crop.width} × ${crop.height} px`;
  $('estimate').textContent = `成片 ${time(state.plan.outputDurationMs)} · 预计 ${(state.plan.profile.estimatedBytes / 1048576).toFixed(1)} MiB${state.plan.profile.fitsTarget ? '，实际大小以成片为准' : '，超过分享预算，可缩短内容或继续导出'}`;
  $('crop-toggle').textContent = cropMode ? '退出裁切调整' : '调整裁切框';
  $('crop-original').textContent = preserveRatio ? '✓ 原始比例' : '原始比例';
  video.muted = doc.muted;
  canvas.classList.toggle('cropping', cropMode);
  draw(); drawTimeline();
}
function resolvePosition() {
  if (!state || !Number.isFinite(video.currentTime)) return;
  const position = decode(video_seek(state.session, Math.min(recording.durationMs, Math.max(0, video.currentTime * 1000))));
  if (position.atEnd) { video.pause(); if (Math.abs(video.currentTime * 1000 - position.sourceMs) > 2) video.currentTime = position.sourceMs / 1000; }
  else if (Math.abs(position.sourceMs - video.currentTime * 1000) > 2) video.currentTime = position.sourceMs / 1000;
  $('source-time').textContent = time(position.sourceMs);
  $('output-time').textContent = time(position.outputMs);
  return position;
}
function seek(milliseconds) {
  const position = decode(video_seek(state.session, Math.max(0, Math.min(recording.durationMs, milliseconds))));
  $('seeking').hidden = false;
  video.currentTime = position.sourceMs / 1000;
  if (position.atEnd) video.pause();
  drawTimeline();
}
function draw() {
  if (!state || video.readyState < 2 || disposed) return;
  const rect = cropMode ? { x: 0, y: 0, width: recording.width, height: recording.height } : state.document.crop || { x: 0, y: 0, width: recording.width, height: recording.height };
  if (canvas.width !== rect.width) canvas.width = rect.width;
  if (canvas.height !== rect.height) canvas.height = rect.height;
  context.drawImage(video, rect.x, rect.y, rect.width, rect.height, 0, 0, rect.width, rect.height);
  if (cropMode && cropDraft) {
    const { x, y, width, height } = cropDraft;
    context.fillStyle = '#0008';
    context.fillRect(0, 0, canvas.width, y); context.fillRect(0, y + height, canvas.width, canvas.height - y - height);
    context.fillRect(0, y, x, height); context.fillRect(x + width, y, canvas.width - x - width, height);
    context.strokeStyle = '#b7edc8'; context.lineWidth = Math.max(2, canvas.width / 500);
    context.strokeRect(x, y, width, height); context.fillStyle = '#b7edc8';
    const size = canvas.width / Math.max(1, canvas.getBoundingClientRect().width) * 7;
    for (const [cx, cy] of [[x,y],[x+width,y],[x,y+height],[x+width,y+height]]) context.fillRect(cx-size/2,cy-size/2,size,size);
  }
}
function drawTimeline() {
  if (!state) return;
  const bounds = timeline.getBoundingClientRect();
  timeline.width = Math.max(1, Math.round(bounds.width * devicePixelRatio)); timeline.height = Math.round(62 * devicePixelRatio);
  const ctx = timeline.getContext('2d'); ctx.scale(devicePixelRatio, devicePixelRatio);
  const w = bounds.width, height = 62, x = (ms) => ms / recording.durationMs * w;
  ctx.fillStyle = '#252a27'; ctx.fillRect(0, 0, w, height);
  const trim = timelineGesture?.mode === 'trim' ? timelineGesture.trim : state.document.trim;
  ctx.fillStyle = '#653d39'; ctx.fillRect(x(trim.startMs), 10, x(trim.endMs - trim.startMs), 42);
  ctx.fillStyle = '#548769';
  for (const segment of state.plan.segments) ctx.fillRect(x(segment.sourceStartMs), 10, x(segment.sourceEndMs-segment.sourceStartMs), 42);
  ctx.fillStyle = '#a5ddb8'; ctx.fillRect(x(trim.startMs), 3, 5, 56); ctx.fillRect(x(trim.endMs)-5, 3, 5, 56);
  const cutStart = Number($('cut-start')?.value || 0)*1000, cutEnd = Number($('cut-end')?.value || 0)*1000;
  if (cutEnd > cutStart) { ctx.fillStyle = '#e9ab693b'; ctx.fillRect(x(cutStart), 0, x(cutEnd-cutStart), height); }
  ctx.fillStyle = '#fff'; ctx.fillRect(x(video.currentTime*1000), 0, 2, height);
}
function tick() {
  if (disposed) return;
  if (video.paused) { frameHandle = null; return; }
  resolvePosition(); draw(); drawTimeline();
  frameHandle = requestAnimationFrame(tick);
}
function play() {
  if (exporting || !state) return;
  if (video.paused) {
    const last = state.plan.segments.at(-1);
    if (video.currentTime*1000 >= last.sourceEndMs-50) seek(state.plan.segments[0].sourceStartMs);
    void video.play().catch((error) => notice(error.message, true));
  } else video.pause();
}
function cropFields() { return Object.fromEntries(['x','y','width','height'].map((key) => [key, Math.round(number(`crop-${key}`))])); }
function setBusy(value) {
  exporting = value;
  for (const input of $('video-controls').querySelectorAll('button,input,select')) input.disabled = value && input.id !== 'cancel-export';
  if (!value) sync();
}
function closeAfterCopy() {
  closeScheduled = true;
  // Give the host's IPC reply and clipboard transaction time to finish before
  // the desktop shell disposes this renderer. No more edits are accepted.
  setBusy(true);
  setTimeout(() => window.close(), 150);
}
async function exportVideo(mode) {
  if (exporting) return;
  video.pause();
  await saveTail;
  await api.saveVideoDraft(recording.id, state.document);
  setBusy(true); $('export-status').hidden = false; $('export-progress').value = 0; $('export-message').textContent = '正在生成 MP4…';
  try {
    const result = await api.exportVideo(recording.id, state.plan, { mode });
    if (!result || result.canceled) { notice('已取消导出，原件与剪辑草稿保留。'); return; }
    lastExport = result.path;
    $('export-actions').hidden = false;
    if (result.copyError) notice(`视频已生成，复制失败：${result.copyError}。可直接重试复制。`, true);
    else if (result.clipboardChanged) notice('视频已生成。期间剪贴板有更新，点击“复制已生成视频”继续。');
    else if (result.copied) { notice('视频文件已复制。'); closeAfterCopy(); }
    else notice(mode === 'save' ? 'MP4 已另存为。' : 'MP4 已生成，点击“复制已生成视频”。');
  } catch (error) { notice(error.message, true); }
  finally { if(!closeScheduled) setBusy(false); $('export-status').hidden = true; }
}
const actions = {
  undo: () => edit({ type:'undo' }), redo: () => edit({ type:'redo' }), reset: () => edit({ type:'reset' }),
  'set-start': () => edit({type:'trim',trim:{...state.document.trim,startMs:frameAligned(video.currentTime*1000)}}),
  'set-end': () => edit({type:'trim',trim:{...state.document.trim,endMs:frameAligned(video.currentTime*1000)}}),
  'delete-cut': () => edit({type:'cut',cut:{startMs:secondsField('cut-start'),endMs:secondsField('cut-end')}}),
  'clear-cuts': () => edit({type:'clearCuts'}),
  'crop-toggle': () => { cropMode=!cropMode; cropDraft=cropMode ? state.document.crop || {x:0,y:0,width:recording.width,height:recording.height} : null; video.pause(); sync(); },
  'crop-original': () => { preserveRatio=!preserveRatio; sync(); },
  'apply-crop': () => edit({type:'crop',crop:cropFields()}), 'clear-crop': () => edit({type:'crop',crop:null}),
  confirm: () => exportVideo('copy'), 'save-as': () => exportVideo('save'), 'cancel-export': async () => { await api.cancelExport(); setBusy(false); $('export-status').hidden=true; notice('已取消导出，原件与剪辑草稿保留。'); },
  'retry-copy': async () => { setBusy(true); try { const result=await api.retryCopyVideo(lastExport); if(result?.copied){notice('视频文件已复制。');closeAfterCopy();}else notice(result?.copyError || '文件复制未完成。',true); } finally { if(!closeScheduled)setBusy(false); } },
  'reveal-export': () => api.showInFolder(lastExport), 'copy-path': () => api.copyPath ? api.copyPath(lastExport) : navigator.clipboard.writeText(lastExport),
};
window.mooncapVideo = { dispatch(id) { if (!state || (exporting && id !== 'cancel-export')) return; Promise.resolve().then(() => actions[id]?.()).catch((error) => notice(error.message,true)); } };
await import('../../dist/ui/video.mjs');
await new Promise((resolve) => requestAnimationFrame(resolve));

try {
  const id = new URLSearchParams(location.search).get('id');
  recording = await api.getRecording(id);
  if(recording.interruptedReason) notice(`录制曾中断，已保留可播放原件：${recording.interruptedReason}`,true);
  let draft = null;
  try { draft = await api.loadVideoDraft(id); } catch(error) { notice(`无法读取草稿：${error.message}。原件仍保留。`,true); }
  state = decode(video_open(JSON.stringify(recording), draft ? JSON.stringify(draft) : ''));
  video.src = recording.url; video.load();
  $('cut-end').value = Math.min(1,recording.durationMs/1000);
  sync();
  if(recording.exporting){setBusy(true);$('export-status').hidden=false;$('export-progress').value=(recording.exportProgress||0)*100;$('export-message').textContent='视频正在后台生成…';}
  if(recording.exportError)notice(recording.exportError,true);
  if(recording.lastExport?.path){lastExport=recording.lastExport.path;$('export-actions').hidden=false;}
  video.addEventListener('loadeddata', () => { seek(state.plan.segments[0].sourceStartMs); draw(); });
  video.addEventListener('seeked', () => { $('seeking').hidden=true; resolvePosition(); draw(); });
  video.addEventListener('error', () => notice('无法播放原始录像，原件已保留。',true));
  video.addEventListener('play', () => { $('play').textContent='❚❚ 暂停'; if(frameHandle===null) tick(); });
  video.addEventListener('pause', () => { $('play').textContent='▶ 播放'; draw(); drawTimeline(); });
  $('play').addEventListener('click',play);
  for(const id of ['trim-start','trim-end']) $(id).addEventListener('change',()=> {try{edit({type:'trim',trim:{startMs:secondsField('trim-start'),endMs:secondsField('trim-end')}});}catch(e){notice(e.message,true);sync();}});
  for(const id of ['cut-start','cut-end']) $(id).addEventListener('input',drawTimeline);
  $('mute').addEventListener('change',()=>edit({type:'mute',muted:$('mute').checked}));
  $('preset').addEventListener('change',()=>edit({type:'preset',preset:$('preset').value}));
  for(const key of ['x','y','width','height']) $(`crop-${key}`).addEventListener('input',()=>{if(cropMode){try{cropDraft=cropFields();draw();}catch{/* Keep the last valid preview until input is complete. */}}});
  api.onExportProgress((value)=>{
    if(value?.id && value.id!==recording.id)return;
    if(value?.phase==='error'||value?.phase==='canceled'){
      setBusy(false);$('export-status').hidden=true;notice(value.error || '已取消导出，原件与草稿保留。',value.phase==='error');return;
    }
    if(value?.phase==='complete'){
      const result=value.result||value;
      if(result.path){lastExport=result.path;$('export-actions').hidden=false;}
      $('export-status').hidden=true;
      if(result.copied){notice('视频文件已复制。');closeAfterCopy();}
      else{setBusy(false);notice(result.copyError || (result.clipboardChanged?'视频已生成，剪贴板有更新，可点击复制。':'视频已生成。'),Boolean(result.copyError));}
      return;
    }
    if(!exporting)return;
    const n=typeof value==='number'?value:value.progress;
    if(Number.isFinite(n))$('export-progress').value=Math.max(0,Math.min(100,n*100));
    $('export-message').textContent=value?.phase==='copy'?'正在复制视频文件…':`正在生成 MP4 · ${Math.round((n||0)*100)}%`;
  });
  tick();
} catch(error) { notice(error.message,true); }

function canvasPoint(event){const r=canvas.getBoundingClientRect();return{x:Math.max(0,Math.min(recording.width,(event.clientX-r.left)/r.width*recording.width)),y:Math.max(0,Math.min(recording.height,(event.clientY-r.top)/r.height*recording.height))};}
canvas.addEventListener('pointerdown',(event)=>{
  if(!cropMode||exporting||event.button!==0)return;
  event.preventDefault();video.pause();canvas.setPointerCapture(event.pointerId);
  const point=canvasPoint(event), rect=cropDraft, threshold=12*recording.width/canvas.getBoundingClientRect().width;
  let mode='new', anchor=null;
  for(const [x,y,ox,oy] of [[rect.x,rect.y,rect.x+rect.width,rect.y+rect.height],[rect.x+rect.width,rect.y,rect.x,rect.y+rect.height],[rect.x,rect.y+rect.height,rect.x+rect.width,rect.y],[rect.x+rect.width,rect.y+rect.height,rect.x,rect.y]])if(Math.hypot(point.x-x,point.y-y)<threshold){mode='resize';anchor={x:ox,y:oy};break;}
  if(mode==='new'&&point.x>rect.x&&point.x<rect.x+rect.width&&point.y>rect.y&&point.y<rect.y+rect.height)mode='move';
  cropGesture={mode,start:point,previous:{...rect},anchor:anchor||point};
});
canvas.addEventListener('pointermove',(event)=>{
  if(!cropGesture)return;
  const point=canvasPoint(event),g=cropGesture;
  if(g.mode==='move')cropDraft={...g.previous,x:Math.max(0,Math.min(recording.width-g.previous.width,Math.round(g.previous.x+point.x-g.start.x))),y:Math.max(0,Math.min(recording.height-g.previous.height,Math.round(g.previous.y+point.y-g.start.y)))};
  else{
    let width=Math.max(2,Math.abs(point.x-g.anchor.x)),height=Math.max(2,Math.abs(point.y-g.anchor.y));
    if(preserveRatio){const ratio=recording.width/recording.height;width=Math.min(width,height*ratio);height=width/ratio;}
    cropDraft={x:Math.round(Math.min(g.anchor.x,point.x)),y:Math.round(Math.min(g.anchor.y,point.y)),width:Math.floor(width/2)*2,height:Math.floor(height/2)*2};
  }
  for(const key of ['x','y','width','height'])$(`crop-${key}`).value=cropDraft[key];draw();
});
canvas.addEventListener('pointerup',()=>{cropGesture=null;});
canvas.addEventListener('pointercancel',()=>{if(cropGesture)cropDraft=cropGesture.previous;cropGesture=null;sync();});
function timelineTime(event){const r=timeline.getBoundingClientRect();return frameAligned(Math.max(0,Math.min(1,(event.clientX-r.left)/r.width))*recording.durationMs);}
timeline.addEventListener('pointerdown',(event)=>{
  if(!state||exporting||event.button!==0)return;event.preventDefault();video.pause();timeline.focus();timeline.setPointerCapture(event.pointerId);
  const at=timelineTime(event),threshold=12/timeline.getBoundingClientRect().width*recording.durationMs,trim=state.document.trim;
  const edge=Math.abs(at-trim.startMs)<threshold?'startMs':Math.abs(at-trim.endMs)<threshold?'endMs':null;
  timelineGesture={mode:edge?'trim':'select',edge,start:at,at,trim:{...trim},moved:false};
});
timeline.addEventListener('pointermove',(event)=>{
  const g=timelineGesture;if(!g)return;g.at=timelineTime(event);g.moved ||= Math.abs(g.at-g.start)>recording.durationMs/timeline.getBoundingClientRect().width*4;
  if(g.mode==='trim'){g.trim[g.edge]=g.at;$('trim-start').value=(g.trim.startMs/1000).toFixed(3);$('trim-end').value=(g.trim.endMs/1000).toFixed(3);}
  else if(g.moved){$('cut-start').value=(Math.min(g.start,g.at)/1000).toFixed(3);$('cut-end').value=(Math.max(g.start,g.at)/1000).toFixed(3);}
  drawTimeline();
});
timeline.addEventListener('pointerup',()=>{const g=timelineGesture;timelineGesture=null;if(!g)return;if(g.mode==='trim')edit({type:'trim',trim:g.trim});else if(!g.moved)seek(g.at);drawTimeline();});
timeline.addEventListener('pointercancel',()=>{timelineGesture=null;sync();});
window.addEventListener('keydown',(event)=>{
  if(!state||event.isComposing)return;
  if(event.key==='Escape'){
    if(cropGesture){cropDraft=cropGesture.previous;cropGesture=null;sync();event.preventDefault();return;}
    if(timelineGesture){timelineGesture=null;sync();event.preventDefault();return;}
    if(cropMode){cropMode=false;cropDraft=null;sync();event.preventDefault();return;}
    if(!exporting&&!event.target.closest('input,select,textarea,[contenteditable=true]'))window.close();return;
  }
  if(event.target.closest('input,select,textarea,button,a,[role=menuitem],[contenteditable=true]')||exporting)return;
  if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='z'){event.preventDefault();edit({type:event.shiftKey?'redo':'undo'});}
  else if((event.ctrlKey)&&event.key.toLowerCase()==='y'){event.preventDefault();edit({type:'redo'});}
  else if(event.key===' '){event.preventDefault();play();}
  else if(event.key==='Enter'&&!cropGesture&&!timelineGesture){event.preventDefault();void exportVideo('copy');}
  else if((event.key==='ArrowLeft'||event.key==='ArrowRight')&&(event.target===canvas||event.target===timeline)){event.preventDefault();seek(video.currentTime*1000+(event.key==='ArrowLeft'?-1:1)*(event.shiftKey?5000:1000));}
});
window.addEventListener('beforeunload',()=>{disposed=true;cancelAnimationFrame(frameHandle);video.pause();if(state)video_dispose(state.session);});
window.addEventListener('resize',()=>{draw();drawTimeline();});
