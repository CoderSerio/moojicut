import { $, action, checked, formatTime, notice, number, view } from './shared-ui.mjs';
import { cropRect, editPlan, exportProfile } from './core-bridge.mjs';

export function createVideoEditor({ api }) {
  let currentVideo = null;
  let lastExport = null;
  let exporting = false;

  async function refreshHistory() {
    const recordings = await api.listRecordings();
    $('history').replaceChildren();
    for (const item of recordings.slice(0, 20)) {
      const button = document.createElement('button');
      const complete = item.state === 'complete';
      button.textContent = `${new Date(item.createdAt).toLocaleString()} · ${complete ? formatTime(item.durationMs) : '未完成 · 原文件已保留'}`;
      button.disabled = !complete;
      button.addEventListener('click', () => openVideo(item));
      $('history').append(button);
    }
    if (!recordings.length) $('history').textContent = '还没有录像。';
  }

  function openVideo(recording) {
    currentVideo = recording;
    lastExport = null;
    $('reveal-export').hidden = true;
    $('preview').src = recording.url;
    $('trim-start').value = '0';
    $('trim-end').value = String(recording.durationMs / 1000);
    $('cut-enabled').checked = false;
    $('video-crop-enabled').checked = false;
    $('crop-x').value = '0'; $('crop-y').value = '0';
    $('crop-width').value = recording.width; $('crop-height').value = recording.height;
    $('mute').checked = false;
    view('video');
    updateEstimate();
  }

  function videoPlan() {
    if (!currentVideo) throw new Error('请先打开一段录像。');
    const edit = editPlan({
      durationMs: Math.round(currentVideo.durationMs),
      trim: { startMs: Math.round(number('trim-start') * 1000), endMs: Math.round(number('trim-end') * 1000) },
      ...(checked('cut-enabled') ? { cut: { startMs: Math.round(number('cut-start') * 1000), endMs: Math.round(number('cut-end') * 1000) } } : {}),
    });
    const crop = checked('video-crop-enabled') ? cropRect({ sourceWidth: currentVideo.width, sourceHeight: currentVideo.height, x: number('crop-x'), y: number('crop-y'), width: number('crop-width'), height: number('crop-height') }).rect : undefined;
    const profile = exportProfile({ durationMs: edit.outputDurationMs, width: crop?.width ?? currentVideo.width, height: crop?.height ?? currentVideo.height, preset: $('preset').value, hasAudio: currentVideo.hasAudio && !checked('mute'), targetBytes: Math.round(number('target-mb') * 1024 * 1024) });
    return { segments: edit.segments, crop, muted: checked('mute'), profile, outputDurationMs: edit.outputDurationMs };
  }

  function updateEstimate() {
    try {
      const plan = videoPlan();
      $('export-estimate').textContent = `保留 ${formatTime(plan.outputDurationMs)} · 预计 ${(plan.profile.estimatedBytes / 1024 / 1024).toFixed(1)} MiB${plan.profile.fitsTarget ? '（实际体积以导出结果为准）' : '；当前时长无法在最低码率下达到目标，请缩短视频或提高目标体积。'}`;
    } catch (error) { $('export-estimate').textContent = error.message; }
  }
  for (const input of document.querySelectorAll('#video-view input, #video-view select')) input.addEventListener('input', updateEstimate);
  action('set-start', () => { $('trim-start').value = $('preview').currentTime.toFixed(3); updateEstimate(); });
  action('set-end', () => { $('trim-end').value = $('preview').currentTime.toFixed(3); updateEstimate(); });

  action('export-video', async () => {
    if (exporting) return;
    const plan = videoPlan();
    exporting = true;
    $('export-status').hidden = false;
    $('export-progress').value = 0;
    $('export-message').textContent = '正在导出…';
    try {
      const result = await api.exportVideo(currentVideo.id, plan);
      if (!result || result.canceled) { $('export-message').textContent = '已取消保存。'; return; }
      lastExport = result.path;
      $('export-progress').value = 100;
      $('export-message').textContent = `已导出 MP4 · ${((result.size ?? result.bytes) / 1024 / 1024).toFixed(1)} MiB`;
      $('reveal-export').hidden = false;
      notice('MP4 已保存，可从文件夹拖入聊天窗口发送。');
    } finally { exporting = false; }
  });
  api.onExportProgress((progress) => {
    const percent = typeof progress === 'number' ? progress : progress.progress * 100;
    if (Number.isFinite(percent)) $('export-progress').value = percent;
  });
  action('reveal-export', () => api.showInFolder(lastExport));

  return { open: openVideo, refreshHistory, isExporting: () => exporting, pause: () => $('preview').pause() };
}
