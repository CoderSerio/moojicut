import { action, notice, view } from './shared-ui.mjs';
import { createCapture } from './capture.mjs';
import { createRecording } from './recording.mjs';
import { createImageEditor } from './image-editor.mjs';
import { createVideoEditor } from './video-editor.mjs';

// This window is a development harness. Product entry points can reuse these modules.
const api = window.mooncap;
const imageEditor = createImageEditor({ api });
const videoEditor = createVideoEditor({ api });
const capture = createCapture({
  api,
  onImage: imageEditor.open,
  isRecordingBusy: () => recording.isBusy(),
});
const recording = createRecording({ api, capture, onRecording: videoEditor.open });

action('refresh', capture.refreshSources);
action('screenshot', capture.takeScreenshot);
action('record', recording.start);
action('stop', recording.stop);
action('recordings-folder', () => api.showRecordingsFolder());
action('home', async () => {
  if (videoEditor.isExporting() || recording.isBusy()) throw new Error('请先等待当前录制或导出完成。');
  videoEditor.pause();
  view('capture');
  await Promise.all([capture.refreshSources(), videoEditor.refreshHistory()]);
});

Promise.all([
  capture.refreshSources(),
  videoEditor.refreshHistory(),
  capture.checkEnvironment(),
]).catch((error) => notice(error.message, true));
