const api = window.mooncap;
let data, current = 'history', pending = false, refreshSequence = 0, historySequence = 0;
let thumbnailObserver, thumbnailLoading = false, thumbnailQueue = [], refreshTimer;
const notice = document.querySelector('#notice');
function tell(message) { notice.hidden = !message; notice.textContent = message; }
function node(tag, text, className) { const element = document.createElement(tag); if (text) element.textContent = text; if (className) element.className = className; return element; }
function button(text, action, className) { const element = node('button', text, className); element.type='button'; element.onclick = () => void run(action); return element; }
async function run(action) { if (pending) return; pending = true; try { await action(); } catch(error) { tell(error.message); } finally { pending = false; } }
function bytes(value = 0) { if (value < 1024) return `${value} B`; const unit=Math.min(3,Math.floor(Math.log(value)/Math.log(1024))); return `${(value/1024**unit).toFixed(unit===1?0:1)} ${['B','KB','MB','GB'][unit]}`; }
function basename(filename) { return filename.split(/[\\/]/).at(-1); }
async function refresh() { const sequence=++refreshSequence; const next=await api.getLibrary(); if(sequence!==refreshSequence) return; data=next; if(current==='history') renderHistory(); if(current==='settings') renderSettings(); }
async function loadThumbnails() {
  if(thumbnailLoading) return; thumbnailLoading=true;
  try {
    while(thumbnailQueue.length) {
      const {value,target,sequence}=thumbnailQueue.shift();
      if(sequence!==historySequence || !target.isConnected || current!=='history') continue;
      try {
        const url=await api.assetThumbnail(value.kind,value.id);
        if(url && sequence===historySequence && target.isConnected) { const image=node('img'); image.src=url; image.alt=''; target.replaceChildren(image); }
      } catch { target.title='暂时无法读取缩略图，原始素材仍保留。'; }
    }
  } finally { thumbnailLoading=false; }
}
function renderHistory() {
  const target = document.querySelector('#history'); target.replaceChildren();
  thumbnailObserver?.disconnect(); thumbnailQueue=[]; const sequence=++historySequence;
  thumbnailObserver=new IntersectionObserver(entries=>{
    for(const entry of entries) if(entry.isIntersecting) { thumbnailObserver.unobserve(entry.target); thumbnailQueue.push({value:entry.target.assetValue,target:entry.target,sequence}); }
    void loadThumbnails();
  },{rootMargin:'120px'});
  const entries = [...data.images.map(value => ({...value,kind:'image'})), ...data.recordings.map(value => ({...value,kind:'video'}))].sort((a,b) => new Date(b.createdAt) - new Date(a.createdAt));
  if (!entries.length) { target.append(node('div','还没有记录。使用截图或录屏，确认后即可在这里继续编辑。','empty')); return; }
  target.append(node('p','素材与导出文件分开保存。这里删除素材时，已导出的文件会保留。','muted history-note'));
  for (const value of entries) {
    const item = node('article',null,'asset'); const thumbnail=node('div',value.kind==='image'?'▧':'▷','asset-thumbnail'); thumbnail.assetValue=value; item.append(thumbnail);
    const copy = node('div',null,'asset-copy'); copy.append(node('strong',value.name || (value.kind === 'image' ? '截图' : '屏幕录制')));
    const dimensions = value.width && value.height ? `${value.width} × ${value.height}` : '';
    copy.append(node('small',[new Date(value.createdAt).toLocaleString(),dimensions,value.kind==='video' ? (value.state === 'complete' ? `${(value.durationMs / 1000).toFixed(1)} 秒` : '录制中断 · 原始数据已保留') : '标注可继续编辑'].filter(Boolean).join(' · '))); item.append(copy);
    const controls = node('div',null,'actions'); const open = button('编辑',() => api.openAsset(value.kind,value.id)); open.disabled = value.kind === 'video' && value.state !== 'complete';
    controls.append(open,button('显示位置',() => api.revealAsset(value.kind,value.id)),button('删除',async () => { await api.removeAsset(value.kind,value.id); await refresh(); },'delete')); item.append(controls); target.append(item);
    if(value.kind==='image' || value.state==='complete') thumbnailObserver.observe(thumbnail);
  }
}
async function renderSources() {
  const target = document.querySelector('#sources'); target.replaceChildren(node('p','正在读取可截取窗口…'));
  const sources = await api.sources(); target.replaceChildren(node('p','选择窗口后，可标注并确认复制图片。'));
  const grid = node('div',null,'source-grid');
  for (const source of sources) {
    const item = button('',() => api.captureSource(source.id),'source');
    if (source.thumbnail) { const image = node('img'); image.src = source.thumbnail; image.alt = ''; item.append(image); }
    item.append(node('span',source.name)); grid.append(item);
  }
  target.append(grid,button('刷新窗口',renderSources));
}
function renderSettings() {
  const target = document.querySelector('#settings'), env = data.environment; target.replaceChildren();
  target.append(node('p','快捷键唤起功能；编辑窗口按需创建，关闭即释放。所有素材只保存在本机。'));
  const form = node('form');
  for (const [key,title] of [['screenshotShortcut','截图快捷键'],['recordingShortcut','录屏快捷键'],['stopShortcut','停止录制快捷键']]) {
    const label = node('label'); label.append(node('span',title)); const input = node('input'); input.type='text'; input.name=key; input.value=env.settings[key]; input.required=true; label.append(input);
    label.append(node('small',env.shortcuts[key] ? '已注册' : '注册失败：可能与其他应用冲突，请更换。',env.shortcuts[key]?'':'warning')); form.append(label);
  }
  form.append(node('small','使用 CommandOrControl+Shift+1 这类写法；三个快捷键必须不同。'));
  const save = node('button','保存快捷键','primary'); save.type='submit'; form.append(save);
  form.onsubmit = event => { event.preventDefault(); void run(async () => { const result = await api.savePreferences(Object.fromEntries(new FormData(form))); data.environment.settings=result.settings; data.environment.shortcuts=result.shortcuts; renderSettings(); tell(Object.keys(result.shortcuts).length === 3 ? '快捷键已保存。' : '设置已保存，部分快捷键被其他应用占用，请更换。'); }); };
  target.append(form,node('h2','权限与本机素材'));
  target.append(node('p',env.platform==='darwin' ? `屏幕录制权限：${({granted:'已允许',denied:'未允许',restricted:'受系统限制','not-determined':'尚未授权'})[env.screenPermission] || env.screenPermission}。修改后可能需要退出并重新打开应用。` : '屏幕采集和声音的可用性取决于系统权限。'));
  const actions = node('div',null,'actions'); if (env.platform==='darwin') actions.append(button('打开屏幕录制权限',() => api.openPermissions())); actions.append(button('打开素材文件夹',() => api.openDataFolder())); target.append(actions);
  target.append(node('h2','本机存储'));
  const usage=node('dl',null,'storage-usage');
  for(const [key,label] of [['imagesBytes','截图与标注'],['recordingsBytes','录像原件与草稿'],['exportsBytes','导出文件']]) { const group=node('div'); group.append(node('dt',label),node('dd',bytes(data.storage?.[key]))); usage.append(group); }
  target.append(usage,node('p','素材会一直保留，直到你主动删除。视频生成完成后，关闭编辑窗口不会删除原件。','muted'));
  target.append(node('h2','导出文件'));
  target.append(node('p','这里只管理生成的 PNG 和 MP4。删除导出文件会保留素材，但可能使尚未完成的文件粘贴失效。','muted'));
  const exportFiles=data.storage?.exportFiles || (data.exports || []).map(path=>({path}));
  if(!exportFiles.length) target.append(node('div','还没有保留的导出文件。','empty'));
  for(const file of exportFiles) {
    const row=node('article',null,'export-file'); const copy=node('div',null,'export-copy');
    copy.append(node('strong',basename(file.path)),node('small',file.path)); if(file.bytes!==undefined) copy.append(node('small',bytes(file.bytes)));
    const controls=node('div',null,'actions'); controls.append(button('显示位置',()=>api.showInFolder(file.path)),button('删除导出',async()=>{await api.deleteExport(file.path); await refresh();},'delete'));
    row.append(copy,controls); target.append(row);
  }
  target.append(node('p','视频确认会生成 MP4 文件并复制文件；生成期间如果你复制了其他内容，会保留新的剪贴板，并显示“复制视频”入口。','muted'));
}
async function section(name) { if (!['history','sources','settings'].includes(name)) name='history'; current=name; tell(''); if(name!=='history') { thumbnailObserver?.disconnect(); thumbnailQueue=[]; historySequence++; } document.querySelectorAll('.section').forEach(element => { element.hidden=element.id!==name; }); document.querySelectorAll('[data-section]').forEach(element => element.classList.toggle('active',element.dataset.section===name)); if (name==='sources') await renderSources(); else await refresh(); }
document.querySelectorAll('[data-section]').forEach(element => { element.onclick=()=>void run(()=>section(element.dataset.section)); });
document.querySelector('#capture').onclick=()=>void run(()=>api.capture('region'));
document.querySelector('#record').onclick=()=>void run(()=>api.prepareRecording());
document.querySelector('#import').onclick=()=>void run(()=>api.importImage());
api.onLibrarySection(name=>void run(()=>section(name))); api.onNotice(tell);
function scheduleRefresh() { clearTimeout(refreshTimer); refreshTimer=setTimeout(()=>{if(data && current!=='sources' && !pending) void refresh().catch(error=>tell(error.message));},180); }
api.onImageChanged(()=>{if(current==='history') scheduleRefresh();});
addEventListener('focus',scheduleRefresh);
try { data=await api.getLibrary(); await section(data.section || 'history'); } catch(error) { tell(error.message); }
