const api = window.mooncap;
const config = await api.getCaptureSetup();
const env = await api.environment();
const canvas = document.querySelector('#selection'), context = canvas.getContext('2d');
const panel = document.querySelector('#record-panel'), status = document.querySelector('#status');
const start = document.querySelector('#start'), label = document.querySelector('#region-label');
const image = new Image(); image.src = config.imageUrl; await image.decode();
const microphone = document.querySelector('#microphone'), device = document.querySelector('#microphone-device');
microphone.checked = config.microphone;
let microphoneId = config.microphoneId || '';
const audio = document.querySelector('#system-audio'); audio.checked = config.systemAudio && env.systemAudio; audio.disabled = !env.systemAudio;
let region = null, drag = null, busy = false, generation = 0;
async function previewMicrophone() {
  document.querySelector('#microphone-options').hidden = !microphone.checked;
  document.querySelector('#microphone-status').textContent = microphone.checked ? '正在检查输入…' : '';
  try { await api.previewMicrophone(microphone.checked, microphoneId); }
  catch(error) { document.querySelector('#microphone-status').textContent = error.message; }
}
microphone.onchange = () => void previewMicrophone();
device.onchange = () => { microphoneId = device.value; void previewMicrophone(); };
api.onMicrophoneInfo(info => {
  if (info.devices) {
    device.replaceChildren(new Option('系统默认',''), ...info.devices.map(value => new Option(value.label,value.id)));
    device.value = microphoneId || ''; document.querySelector('#microphone-status').textContent = '输入已就绪';
  }
  if (info.error) document.querySelector('#microphone-status').textContent = `无法使用麦克风：${info.error}`;
  if (Number.isFinite(info.level)) document.querySelector('#microphone-level').value = info.level;
});
const point = event => ({ x: Math.max(0, Math.min(config.sourceWidth, Math.round(event.clientX * config.sourceWidth / innerWidth))), y: Math.max(0, Math.min(config.sourceHeight, Math.round(event.clientY * config.sourceHeight / innerHeight))) });
function paint() {
  canvas.width = config.sourceWidth; canvas.height = config.sourceHeight;
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  context.fillStyle = 'rgba(9,13,21,.55)'; context.fillRect(0, 0, canvas.width, canvas.height);
  if (!region) { label.hidden = true; return; }
  const r = region, scale = innerWidth / config.sourceWidth;
  context.drawImage(image, r.x, r.y, r.width, r.height, r.x, r.y, r.width, r.height);
  context.lineWidth = 2 / scale; context.strokeStyle = '#8bb4ff'; context.strokeRect(r.x, r.y, r.width, r.height);
  label.hidden = false; label.textContent = `${r.width} × ${r.height} px`;
  label.style.left = `${Math.min(innerWidth - 160, Math.max(8, r.x * scale))}px`;
  label.style.top = `${Math.max(8, r.y * innerHeight / config.sourceHeight - 32)}px`;
  start.disabled = r.width < 2 || r.height < 2 || busy;
}
canvas.addEventListener('pointerdown', event => { if (busy || event.button !== 0) return; drag = point(event); canvas.setPointerCapture(event.pointerId); panel.classList.add('selecting'); });
canvas.addEventListener('pointermove', event => { if (!drag) return; const end = point(event); region = { x: Math.min(drag.x, end.x), y: Math.min(drag.y, end.y), width: Math.abs(drag.x - end.x), height: Math.abs(drag.y - end.y) }; paint(); });
canvas.addEventListener('pointerup', event => { if (!drag) return; drag = null; canvas.releasePointerCapture(event.pointerId); panel.classList.remove('selecting'); document.querySelector('#heading').textContent = region?.width > 1 ? '准备好后开始录制' : '拖动选择录制区域'; });
canvas.addEventListener('pointercancel', () => { drag = null; panel.classList.remove('selecting'); });
document.querySelector('#full-screen').onclick = () => { if (busy) return; region = { x: 0, y: 0, width: config.sourceWidth, height: config.sourceHeight }; paint(); };
async function cancel() { generation++; busy = true; await api.cancelRecordingPreparation(); }
async function reset() {
  generation++; await api.resetRecordingPreparation(); busy = false;
  panel.hidden = false; document.querySelector('#countdown').hidden = true;
  for (const control of panel.querySelectorAll('input,button,select')) control.disabled = false;
  document.querySelector('#cursor').disabled = true; audio.disabled = !env.systemAudio;
  status.textContent = '已返回准备，选区和声音设置已保留。'; paint(); canvas.focus();
  if (microphone.checked) void previewMicrophone();
}
document.querySelector('#cancel').onclick = () => void cancel();
async function begin() {
  if (busy || !region || region.width < 2 || region.height < 2) return;
  busy = true; const current = ++generation;
  start.disabled = true;
  for (const control of panel.querySelectorAll('input,select,button:not(#cancel)')) control.disabled = true;
  status.textContent = '正在准备画面与声音，系统可能请求权限…';
  try {
    await api.prepareRecorder({ region, microphone: microphone.checked, microphoneId, systemAudio: audio.checked, cursor: true });
    if (current !== generation) return;
    const countdown = document.querySelector('#countdown'); countdown.hidden = false; panel.hidden = true; label.hidden = true;
    for (let remaining = 3; remaining > 0; remaining--) { countdown.textContent = String(remaining); await new Promise(resolve => setTimeout(resolve, 1000)); if (current !== generation) return; }
    countdown.textContent = '开始';
    await api.startPreparedRecording();
  } catch (error) {
    if (current !== generation) return;
    status.textContent = error.message; busy = false; panel.hidden = false; document.querySelector('#countdown').hidden = true;
    for (const control of panel.querySelectorAll('input,button,select')) control.disabled = false;
    document.querySelector('#cursor').disabled = true; audio.disabled = !env.systemAudio; paint();
  }
}
start.onclick = () => void begin();
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') { event.preventDefault(); void (busy ? reset() : cancel()); }
  else if (event.key === 'Enter' && event.target === canvas) { event.preventDefault(); void begin(); }
  else if (region && !busy && event.target === canvas && ['ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(event.key)) {
    event.preventDefault(); const step = event.shiftKey ? 10 : 1;
    region.x = Math.max(0, Math.min(config.sourceWidth - region.width, region.x + (event.key === 'ArrowLeft' ? -step : event.key === 'ArrowRight' ? step : 0)));
    region.y = Math.max(0, Math.min(config.sourceHeight - region.height, region.y + (event.key === 'ArrowUp' ? -step : event.key === 'ArrowDown' ? step : 0))); paint();
  }
});
addEventListener('resize', paint); paint(); canvas.focus();
if (microphone.checked) void previewMicrophone();
