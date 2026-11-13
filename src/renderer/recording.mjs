import { $, checked, formatTime, notice, view } from './shared-ui.mjs';
import { recordingTransition } from './core-bridge.mjs';
import { appendBlobInChunks } from './recording-writer.mjs';

export function createRecording({ api, capture, onRecording }) {
  let recordingState = 'idle';
  let activeRecording = null;
  let starting = false;

  function transition(event) {
    recordingState = recordingTransition(recordingState, event);
  }

  async function prepareRecordingStream() {
    const resources = { streams: [], context: null };
    try {
      const display = await capture.displayStream(checked('system-audio'));
      resources.streams.push(display);
      const audio = display.getAudioTracks().filter((track) => track.readyState === 'live');
      if (checked('system-audio') && !audio.length) throw new Error('系统声音不可用或未授权。请检查系统权限，或取消“系统声音”后重试。');
      if (checked('microphone')) {
        const microphone = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
        resources.streams.push(microphone);
        audio.push(...microphone.getAudioTracks());
      }
      let outputAudio = audio;
      if (audio.length > 1) {
        resources.context = new AudioContext();
        await resources.context.resume();
        const destination = resources.context.createMediaStreamDestination();
        for (const track of audio) resources.context.createMediaStreamSource(new MediaStream([track])).connect(destination);
        outputAudio = destination.stream.getAudioTracks();
      }
      const stream = new MediaStream([...display.getVideoTracks(), ...outputAudio]);
      resources.streams.push(stream);
      return { stream, resources };
    } catch (error) {
      await releaseResources(resources);
      throw error;
    }
  }

  async function releaseResources(resources) {
    for (const stream of resources.streams) stream.getTracks().forEach((track) => track.stop());
    if (resources.context) await resources.context.close();
  }

  async function startRecording() {
    if (starting || capture.isBusy() || activeRecording) return;
    starting = true;
    let resources;
    let id;
    try {
      if (recordingState !== 'idle') transition('reset');
      transition('start');
      notice('请允许屏幕录制权限。');
      const prepared = await prepareRecordingStream();
      resources = prepared.resources;
      const mimeType = ['video/webm;codecs=vp8,opus', 'video/webm;codecs=vp9,opus', 'video/webm'].find((type) => MediaRecorder.isTypeSupported(type));
      if (!mimeType) throw new Error('当前运行环境不支持 WebM 录制。');
      const recorder = new MediaRecorder(prepared.stream, { mimeType, videoBitsPerSecond: 8000000 });
      const started = await api.beginRecording({ mimeType: recorder.mimeType });
      id = typeof started === 'string' ? started : started.id;
      const state = { id, recorder, resources, writes: Promise.resolve(), seq: 0, pendingBytes: 0, failure: null, stopping: false, startedAt: Date.now(), timer: null };
      activeRecording = state;
      recorder.addEventListener('dataavailable', ({ data }) => {
        if (!data.size || state.failure) return;
        state.pendingBytes += data.size;
        if (state.pendingBytes > 64 * 1024 * 1024) {
          state.failure = new Error('磁盘写入速度不足，已停止录制。已写入的原始数据仍保留在本机。');
          void stopRecording();
          return;
        }
        state.writes = state.writes.then(async () => {
          if (state.failure) return;
          await appendBlobInChunks(data, (bytes) => api.appendRecording(state.id, state.seq++, bytes));
          state.pendingBytes -= data.size;
        }).catch((error) => {
          state.failure ??= error;
          void stopRecording();
        });
      });
      recorder.addEventListener('error', (event) => {
        state.failure = event.error ?? new Error('录制发生错误。');
        void stopRecording();
      });
      recorder.addEventListener('stop', () => void finishRecording(state));
      for (const track of new Set(resources.streams.flatMap((stream) => stream.getTracks()))) track.addEventListener('ended', () => {
        if (track.kind === 'audio') state.failure ??= new Error('音频采集中断，请检查系统权限。');
        void stopRecording();
      });
      recorder.start(1000);
      transition('capture_started');
      view('recording');
      notice('');
      $('elapsed').textContent = '00:00';
      state.timer = setInterval(() => { $('elapsed').textContent = formatTime(Date.now() - state.startedAt); }, 250);
    } catch (error) {
      activeRecording = null;
      if (resources) await releaseResources(resources);
      if (id) await api.abortRecording(id);
      transition('fail');
      throw error;
    } finally { starting = false; }
  }

  async function stopRecording() {
    const state = activeRecording;
    if (!state || state.stopping) return;
    state.stopping = true;
    transition('stop');
    $('stop').disabled = true;
    notice('正在保存录像，请稍候…');
    if (state.recorder.state !== 'inactive') state.recorder.stop();
  }

  async function finishRecording(state) {
    clearInterval(state.timer);
    try {
      // MediaRecorder emits its final dataavailable before stop; all chunks must reach disk first.
      await state.writes;
      await releaseResources(state.resources);
      const recording = await api.finishRecording(state.id);
      transition('complete');
      onRecording(recording);
      notice(state.failure ? `录制提前停止：${state.failure.message}` : '录像已保存。调整范围后可直接导出适合分享的 MP4。', Boolean(state.failure));
    } catch (error) {
      transition('fail');
      await api.abortRecording(state.id).catch(() => {});
      view('capture');
      notice(`无法完成录像：${error.message}。已写入的原始文件会保留。`, true);
    } finally {
      activeRecording = null;
      $('stop').disabled = false;
    }
  }

  api.onStopRequested(() => {
    void stopRecording().catch((error) => notice(error.message, true));
  });

  return { start: startRecording, stop: stopRecording, isBusy: () => starting || Boolean(activeRecording) };
}
