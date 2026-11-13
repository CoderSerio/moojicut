import { $, notice } from './shared-ui.mjs';

export function createCapture({ api, onImage, isRecordingBusy }) {
  let selectedSource = null;
  let captureBusy = false;

  async function refreshSources() {
    const sources = await api.sources();
    $('sources').replaceChildren();
    selectedSource = sources.some((s) => s.id === selectedSource) ? selectedSource : sources[0]?.id;
    for (const source of sources) {
      const button = document.createElement('button');
      button.className = 'source';
      button.setAttribute('aria-pressed', String(source.id === selectedSource));
      const img = document.createElement('img');
      if (source.thumbnail) img.src = source.thumbnail;
      img.alt = '';
      const name = document.createElement('span');
      name.textContent = source.name;
      button.append(img, name);
      button.addEventListener('click', () => {
        selectedSource = source.id;
        for (const child of $('sources').children) child.setAttribute('aria-pressed', String(child === button));
      });
      $('sources').append(button);
    }
    $('screenshot').disabled = !selectedSource;
    $('record').disabled = !selectedSource;
    if (!sources.length) notice('未找到可采集的来源。请在系统设置中允许 MoonCap / Electron 录制屏幕，然后重启应用。', true);
  }

  async function displayStream(systemAudio = false) {
    if (!selectedSource) throw new Error('请先选择一个屏幕或窗口。');
    await api.selectSource(selectedSource, systemAudio);
    return navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: 30, max: 30 } }, audio: systemAudio });
  }

  async function liveVideo(stream) {
    const video = document.createElement('video');
    video.muted = true;
    video.srcObject = stream;
    await video.play();
    if (!video.videoWidth) await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('无法读取采集画面。')), 10000);
      video.addEventListener('loadeddata', () => { clearTimeout(timeout); resolve(); }, { once: true });
    });
    // Wait for a delivered frame instead of saving an empty canvas at stream startup.
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('采集画面超时，请重试。')), 10000);
      video.requestVideoFrameCallback(() => { clearTimeout(timer); resolve(); });
    });
    return video;
  }

  async function takeScreenshot() {
    if (captureBusy || isRecordingBusy()) return;
    captureBusy = true;
    let stream;
    try {
      notice('正在采集画面…');
      stream = await displayStream();
      const video = await liveVideo(stream);
      const image = document.createElement('canvas');
      image.width = video.videoWidth;
      image.height = video.videoHeight;
      image.getContext('2d').drawImage(video, 0, 0);
      onImage(image);
      video.srcObject = null;
      notice('拖动即可标注；选择“框选裁剪”可以只保留需要的区域。');
    } finally {
      stream?.getTracks().forEach((track) => track.stop());
      captureBusy = false;
    }
  }

  async function checkEnvironment() {
    const environment = await api.environment();
    if (!environment.systemAudio) {
      $('system-audio').disabled = true;
      $('system-audio').parentElement.title = '当前系统暂不支持系统声音采集';
    }
    if (!environment.tools.ffmpeg || !environment.tools.ffprobe) {
      notice('需要安装 FFmpeg（含 ffprobe）才能完成录像剪辑和 MP4 导出。', true);
    }
    if (environment.stopShortcut?.registered === false) {
      notice('停止快捷键被其他应用占用。录制时请使用停止浮窗或菜单栏中的“停止录制”。', true);
    }
  }

  return { refreshSources, displayStream, takeScreenshot, checkEnvironment, isBusy: () => captureBusy };
}
