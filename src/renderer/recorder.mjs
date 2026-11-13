import { recording_transition } from '../../dist/core/core.mjs';
import { appendBlobInChunks } from './recording-writer.mjs';
import { recordingRegion } from './recording-region.mjs';

const api = window.mooncap;
let active = null;
let starting = false;
let cancelStarting = false;
let phase = 'idle';
let preparedSession = null;
let prepareGeneration = 0;
let microphonePreview = null, microphoneGeneration = 0;
async function stopMicrophonePreview() {
  microphoneGeneration++;
  if (!microphonePreview) return;
  clearInterval(microphonePreview.timer);
  microphonePreview.stream.getTracks().forEach(track => track.stop());
  await microphonePreview.context.close().catch(() => {});
  microphonePreview = null;
}
async function previewMicrophone({ enabled, deviceId }) {
  await stopMicrophonePreview();
  const generation = microphoneGeneration;
  if (!enabled) return;
  let stream, context;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: deviceId ? { deviceId: { exact: deviceId } } : true, video: false });
    if (generation !== microphoneGeneration) { stream.getTracks().forEach(track => track.stop()); return; }
    context = new AudioContext(); await context.resume();
    const analyser = context.createAnalyser(); analyser.fftSize = 256;
    context.createMediaStreamSource(stream).connect(analyser);
    const devices = (await navigator.mediaDevices.enumerateDevices()).filter(device => device.kind === 'audioinput').map(device => ({ id: device.deviceId, label: device.label || '麦克风' }));
    await api.microphoneInfo?.({ devices, selected: stream.getAudioTracks()[0].getSettings().deviceId || deviceId, level: 0 });
    if (generation !== microphoneGeneration) { stream.getTracks().forEach(track => track.stop()); await context.close(); return; }
    const samples = new Float32Array(analyser.fftSize);
    const timer = setInterval(() => { analyser.getFloatTimeDomainData(samples); const level = Math.min(1, Math.sqrt(samples.reduce((sum,n) => sum+n*n,0) / samples.length)*4); void api.microphoneInfo?.({ level }).catch(() => {}); }, 150);
    microphonePreview = { stream, context, timer };
  } catch(error) {
    stream?.getTracks().forEach(track => track.stop()); await context?.close().catch(() => {});
    if (generation === microphoneGeneration) await api.microphoneInfo?.({ error: error.message, level: 0 });
  }
}
function transition(event) {
  const result = JSON.parse(recording_transition(phase, event));
  if (!result.ok) throw new Error(result.error.message);
  phase = result.state;
}
function fail(message) { return api.recordingFailed?.(String(message)); }

async function release(resources) {
  resources.closed = true;
  if (resources.frame !== null) resources.video?.cancelVideoFrameCallback?.(resources.frame);
  clearInterval(resources.timer);
  for (const stream of resources.streams) stream.getTracks().forEach((track) => track.stop());
  if (resources.video) { resources.video.pause(); resources.video.srcObject = null; resources.video.remove(); }
  resources.canvas?.remove();
  await resources.context?.close().catch(() => {});
}

async function prepare(config) {
  const resources = { streams: [], video: null, canvas: null, context: null, frame: null, timer: null, closed: false };
  try {
    await api.selectSource(config.sourceId, Boolean(config.systemAudio));
    const display = await navigator.mediaDevices.getDisplayMedia({
      video: { frameRate: { ideal: 30, max: 30 }, cursor: config.cursor === false ? 'never' : 'always' }, audio: Boolean(config.systemAudio),
    });
    resources.streams.push(display);
    const video = document.createElement('video');
    resources.video = video;
    video.muted = true; video.playsInline = true; video.srcObject = display;
    document.body.append(video);
    await video.play();
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('未收到采集画面，请检查屏幕录制权限。')), 15000);
      video.requestVideoFrameCallback(() => { clearTimeout(timer); resolve(); });
    });
    const inputWidth = video.videoWidth, inputHeight = video.videoHeight;
    const region = recordingRegion(config, inputWidth, inputHeight);
    const canvas = document.createElement('canvas');
    resources.canvas = canvas;
    canvas.width = region.width; canvas.height = region.height;
    document.body.append(canvas);
    const context = canvas.getContext('2d', { alpha: false });
    const paint = () => {
      if (resources.closed) return;
      if (video.videoWidth !== inputWidth || video.videoHeight !== inputHeight) {
        if (active) { active.failure ??= new Error('录制来源分辨率已变化，已停止并保留原件。'); void stop(); }
        return;
      }
      context.drawImage(video, region.x, region.y, region.width, region.height, 0, 0, region.width, region.height);
    };
    paint();
    // A hidden renderer is configured with backgroundThrottling:false by the host.
    // Keep drawing independently of any workbench or editor window lifecycle.
    resources.timer = setInterval(paint, 1000 / 30);
    const cropped = canvas.captureStream(30);
    resources.streams.push(cropped);
    const audio = display.getAudioTracks().filter((track) => track.readyState === 'live');
    if (config.systemAudio && !audio.length) throw new Error('未获得系统声音，请检查权限或关闭系统声音重试。');
    if (config.microphone) {
      const microphone = await navigator.mediaDevices.getUserMedia({ video: false, audio: config.microphoneId ? { deviceId: { exact: config.microphoneId } } : true });
      resources.streams.push(microphone);
      if (!microphone.getAudioTracks().length) throw new Error('未获得麦克风声音。');
      audio.push(...microphone.getAudioTracks());
    }
    let outputAudio = audio;
    if (audio.length > 1) {
      resources.context = new AudioContext();
      await resources.context.resume();
      const destination = resources.context.createMediaStreamDestination();
      for (const track of audio) resources.context.createMediaStreamSource(new MediaStream([track])).connect(destination);
      outputAudio = destination.stream.getAudioTracks();
      resources.streams.push(destination.stream);
    }
    const output = new MediaStream([...cropped.getVideoTracks(), ...outputAudio]);
    resources.streams.push(output);
    return { resources, stream: output, region };
  } catch (error) { await release(resources); throw error; }
}

async function prepareForRecording(config) {
  if (active || starting) return;
  await stopMicrophonePreview();
  const generation = ++prepareGeneration;
  if (preparedSession) await release(preparedSession.resources);
  preparedSession = null;
  try {
    const prepared = await prepare(config);
    if (generation !== prepareGeneration) { await release(prepared.resources); return; }
    preparedSession = prepared;
    await api.recorderPrepared?.({ region: prepared.region });
  } catch (error) { if (generation === prepareGeneration) await fail(error.message); }
}

async function cancelPreparation() {
  await stopMicrophonePreview();
  prepareGeneration += 1;
  if (preparedSession) await release(preparedSession.resources);
  preparedSession = null;
  if (starting) cancelStarting = true;
}

async function start() {
  if (starting || active) return;
  starting = true; cancelStarting = false;
  let prepared, id;
  try {
    if (phase !== 'idle') transition('reset');
    transition('start');
    prepared = preparedSession;
    preparedSession = null;
    if (!prepared) throw new Error('录制尚未准备好，请重新选择区域。');
    if (prepared.resources.streams.some(stream => stream.getTracks().some(track => track.readyState !== 'live'))) throw new Error('采集来源已中断，请重新准备录制。');
    const mimeType = ['video/webm;codecs=vp8,opus', 'video/webm;codecs=vp9,opus', 'video/webm'].find((type) => MediaRecorder.isTypeSupported(type));
    if (!mimeType) throw new Error('当前系统没有可用的录制编码器。');
    const recorder = new MediaRecorder(prepared.stream, { mimeType, videoBitsPerSecond: 8_000_000 });
    const result = await api.beginRecording({ mimeType: recorder.mimeType });
    id = typeof result === 'string' ? result : result.id;
    const state = { id, recorder, resources: prepared.resources, writes: Promise.resolve(), sequence: 0, pendingBytes: 0, failure: null, stopping: false, finished: false };
    active = state;
    recorder.addEventListener('dataavailable', ({ data }) => {
      if (!data.size || state.failure?.writeFailure) return;
      state.pendingBytes += data.size;
      if (state.pendingBytes > 64 * 1024 * 1024) {
        state.failure ??= new Error('磁盘写入速度不足，录制已停止。');
        void stop();
        return;
      }
      state.writes = state.writes.then(async () => {
        await appendBlobInChunks(data, (bytes) => api.appendRecording(id, state.sequence++, bytes));
      }).catch((error) => {
        error.writeFailure = true; state.failure = error; void stop();
      }).finally(() => { state.pendingBytes -= data.size; });
    });
    recorder.addEventListener('error', (event) => { state.failure ??= event.error || new Error('采集编码失败。'); void stop(); });
    recorder.addEventListener('stop', () => void finish(state));
    for (const track of new Set(state.resources.streams.flatMap((stream) => stream.getTracks()))) {
      track.addEventListener('ended', () => {
        if (!state.stopping) { state.failure ??= new Error(track.kind === 'audio' ? '音频来源中断。' : '屏幕采集来源中断。'); void stop(); }
      });
    }
    recorder.start(1000);
    transition('capture_started');
    await api.recordingStarted?.(id);
    if (cancelStarting) await stop();
  } catch (error) {
    if (prepared) await release(prepared.resources);
    if (id) await api.abortRecording(id).catch(() => {});
    active = null;
    if (phase === 'requesting' || phase === 'recording') transition('fail');
    await fail(error.message);
  } finally { starting = false; }
}

async function stop() {
  if (starting && !active) { cancelStarting = true; return; }
  const state = active;
  if (!state || state.stopping) return;
  state.stopping = true;
  transition('stop');
  if (state.recorder.state !== 'inactive') state.recorder.stop();
  else await finish(state);
}

async function finish(state) {
  if (state.finished) return;
  state.finished = true;
  try {
    await state.writes;
    await release(state.resources);
    if (state.failure?.writeFailure) throw state.failure;
    await api.finishRecording(state.id, state.failure ? { interruptedReason: state.failure.message.slice(0, 2000) } : {});
    transition('complete');
  } catch (error) {
    if (phase !== 'error') transition('fail');
    await api.abortRecording(state.id).catch(() => {});
    await fail(`无法完成录像：${error.message}。已写入的原始数据仍保留在本机。`);
  } finally { active = null; }
}

api.onPrepareRecording((config) => { void prepareForRecording(config); });
api.onPreviewMicrophone?.((options) => { void previewMicrophone(options); });
api.onStartRecording(() => { void start(); });
api.onCancelRecorderPreparation?.(() => { void cancelPreparation(); });
api.onStopRequested(() => { void stop(); });
window.addEventListener('beforeunload', () => { if (active) void release(active.resources); if (preparedSession) void release(preparedSession.resources); });
await api.recorderReady?.();
