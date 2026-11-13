import { app, BrowserWindow, desktopCapturer, dialog, nativeImage, screen, shell, systemPreferences } from 'electron';
import { mkdir, readFile, readdir, realpath, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { ImageStore } from './image-store.mjs';
import { exportRecording, validateExportPlan } from './media-export.mjs';
import { findExecutable } from './media-tools.mjs';
import { validatePng } from './media-input.mjs';
import { clipboardVersion, copyFile, copyFileIfUnchanged, copyPng } from './platform-clipboard.mjs';
import { createLibraryService } from './library-service.mjs';
import { captureDimensions } from './capture-platform.mjs';

const renderer = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../renderer');
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function createApplication({ directory, recordings, desktop, state, preferences }) {
  const exportDirectory = path.join(directory, 'exports');
  await mkdir(exportDirectory, { recursive: true });
  const allowedOutputs = new Set((await readdir(exportDirectory)).filter(name => /\.(png|mp4)$/.test(name)).map(name => path.join(exportDirectory, name)));
  const imageLocks = new Set();
  const copyingOutputs = new Set();
  const images = new ImageStore(path.join(directory, 'images'), {
    onChange: session => desktop.send('mooncap:image-changed', session),
    cropPng: (bytes, rect) => nativeImage.createFromBuffer(bytes).crop(rect).toPNG(),
  });
  await images.initialize();
  const library = createLibraryService({ directory, images, recordings, allowedOutputs,
    isBusy: () => Boolean(state.exporting || state.exportPreparing || state.preparing || state.recordingPhase || recordings.activeId || imageLocks.size || copyingOutputs.size), renderCapture });
  let activeCaptureId = null;
  let exportAbort;
  let exportTask;
  let preparePromise;
  let prepareResolve;
  let prepareReject;
  let preparationGeneration = 0;
  const videoResults = new Map();
  let captureStarting = false;
  let hiddenForRecording = [];

  async function startCapture(operation) {
    if (captureStarting) throw new Error('正在准备画面，请稍候。');
    assertIdle(); captureStarting = true;
    try { return await operation(); } finally { captureStarting = false; }
  }
  function restoreAfterRecording() {
    for (const win of hiddenForRecording) if (!win.isDestroyed()) win.showInactive();
    hiddenForRecording = [];
  }
  async function protectOriginals(filename) {
    const parent = await realpath(path.dirname(filename));
    const destination = path.join(parent, path.basename(filename));
    for (const original of [images.directory, recordings.directory]) {
      const root = await realpath(original);
      if (destination === root || destination.startsWith(`${root}${path.sep}`)) throw new Error('不能覆盖本应用保存的原件和草稿。');
    }
    return destination;
  }

  function assertIdle() {
    if (recordings.activeId || state.preparing || state.recordingPhase) throw new Error('请先结束当前录制。');
    if (activeCaptureId) { try { if (!images.get(activeCaptureId).completed) throw new Error('请先完成或取消当前截图。'); } catch (error) { if (error.code !== 'unknown_capture') throw error; } }
  }
  async function listSources() {
    const sources = await desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 320, height: 200 }, fetchWindowIcons: true });
    const own = new Set(BrowserWindow.getAllWindows().map(win => win.getMediaSourceId()));
    return sources.filter(source => !own.has(source.id)).map(source => ({ id: source.id, name: source.name, displayId: source.display_id, thumbnail: source.thumbnail.isEmpty() ? null : source.thumbnail.toDataURL() }));
  }
  async function snapshot({ sourceId, display } = {}) {
    const visible = BrowserWindow.getAllWindows().filter(win => win.isVisible());
    for (const win of visible) win.hide();
    try {
      await wait(120);
      let target = display || screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
      if (sourceId?.startsWith('screen:')) {
        const available = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 0, height: 0 } });
        const selected = available.find(item => item.id === sourceId);
        target = screen.getAllDisplays().find(item => String(item.id) === selected?.display_id);
        if (!target) throw new Error('所选显示器已不可用，请重新选择。');
      }
      const dimensions = await captureDimensions(sourceId, target);
      const sources = await desktopCapturer.getSources({ types: [sourceId?.startsWith('window:') ? 'window' : 'screen'], thumbnailSize: dimensions });
      const source = sourceId ? sources.find(item => item.id === sourceId) : sources.find(item => String(item.display_id) === String(target.id));
      if (!source || source.thumbnail.isEmpty()) throw new Error('无法取得屏幕画面。请检查系统的屏幕录制权限后重新打开 Mooncap。');
      return { png: source.thumbnail.toPNG(), sourceId: source.id, displayBounds: target.bounds, scaleFactor: target.scaleFactor, ...source.thumbnail.getSize() };
    } finally { for (const win of visible) if (!win.isDestroyed()) win.showInactive(); }
  }
  async function capture(mode = 'region') {
    if (activeCaptureId) { try { const current = images.get(activeCaptureId); if (!current.completed) { desktop.showImage(current, current.mode === 'overlay'); return current; } } catch {} }
    return startCapture(async () => {
      const captured = await snapshot();
      const session = await images.create({ ...captured, name: '桌面截图', mode: 'overlay', viewport: mode === 'region' ? null : { x: 0, y: 0, width: captured.width, height: captured.height } });
      activeCaptureId = session.id; desktop.showImage(session, true); return session;
    });
  }
  async function captureSource(sourceId, region, show = true) {
    return startCapture(async () => {
    const captured = await snapshot({ sourceId });
    let png = captured.png;
    if (region) {
      const { x, y, width, height } = region;
      if (![x, y, width, height].every(Number.isInteger) || x < 0 || y < 0 || width < 1 || height < 1 || x + width > captured.width || y + height > captured.height) throw new Error('截图区域超出来源。');
      png = nativeImage.createFromBuffer(png).crop(region).toPNG();
    }
    const session = await images.create({ png, mode: 'window', name: '窗口截图' });
    if (show) { activeCaptureId = session.id; desktop.showImage(session); }
    return session;
    });
  }
  async function importImage(filename) {
    return startCapture(async () => {
    if (!filename) {
      const choice = await dialog.showOpenDialog({ title: '导入图片', properties: ['openFile'], filters: [{ name: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp'] }] });
      if (choice.canceled) return { canceled: true };
      filename = choice.filePaths[0];
    }
    if (!path.isAbsolute(filename)) throw new Error('图片路径必须是绝对路径。');
    if ((await stat(filename)).size > 100 * 1024 * 1024) throw new Error('图片文件过大。');
    const image = nativeImage.createFromBuffer(await readFile(filename));
    if (image.isEmpty()) throw new Error('无法读取该图片。');
    const size = image.getSize();
    if (size.width * size.height > 80_000_000) throw new Error('图片超过 8000 万像素，请先缩小。');
    const session = await images.create({ png: image.toPNG(), name: path.basename(filename), mode: 'window' });
    activeCaptureId = session.id; desktop.showImage(session); return session;
    });
  }
  async function renderCapture(id) {
    await images.record(id).tail;
    const value = images.get(id);
    if (!value.document.viewport) throw new Error('请先选择截图区域。');
    const win = new BrowserWindow({ width: 32, height: 32, show: false, webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false } });
    win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    try {
      await win.loadFile(path.join(renderer, 'render.html'));
      await win.webContents.executeJavaScript('window.mooncapRenderReady');
      const bytes = await win.webContents.executeJavaScript(`window.renderMooncap(${JSON.stringify(value.document)},${JSON.stringify(value.imageUrl)})`);
      return { png: Buffer.from(bytes), revision: value.document.revision, session: value };
    } finally { win.destroy(); }
  }
  function applyImage(id, command, expectedRevision) {
    if (imageLocks.has(id)) throw new Error('图片正在输出，请稍后重试。');
    return images.apply(id, command, expectedRevision);
  }
  async function savePng(bytes, filename) {
    if (!filename) {
      const choice = await dialog.showSaveDialog({ title: '保存截图', defaultPath: path.join(app.getPath('pictures'), `Mooncap-${Date.now()}.png`), filters: [{ name: 'PNG 图片', extensions: ['png'] }] });
      if (choice.canceled || !choice.filePath) return { canceled: true };
      filename = choice.filePath;
    }
    filename = await protectOriginals(filename);
    const temporary = path.join(path.dirname(filename), `.mooncap-${randomUUID()}.png`);
    try { await writeFile(temporary, validatePng(bytes), { flag: 'wx' }); await rename(temporary, filename); }
    finally { await rm(temporary, { force: true }).catch(() => {}); }
    allowedOutputs.add(filename); return { path: filename };
  }
  async function completeImage(id, action, bytes, expectedRevision, close = true) {
    if (!['copy', 'save', 'pin'].includes(action)) throw new Error('未知的完成操作。');
    if (imageLocks.has(id)) throw new Error('图片正在输出。');
    imageLocks.add(id);
    try {
      await images.record(id).tail;
      const current = images.get(id);
      if (expectedRevision !== undefined && current.document.revision !== expectedRevision) throw Object.assign(new Error('图片已被修改，请重试。'), { code: 'revision_conflict' });
      if (!bytes) { const rendered = await renderCapture(id); bytes = rendered.png; expectedRevision = rendered.revision; }
      const png = validatePng(bytes), decoded = nativeImage.createFromBuffer(png);
      const rect = current.document.viewport;
      if (!rect || decoded.isEmpty() || decoded.getSize().width !== rect.width || decoded.getSize().height !== rect.height) throw new Error('输出图片与选区尺寸不一致。');
      let result = {};
      if (action === 'copy') await copyPng(png);
      else if (action === 'save') { result = await savePng(png); if (result.canceled) return result; }
      const completed = await images.complete(id, { expectedRevision });
      if (action === 'pin') desktop.pin(id, png, rect.width, rect.height);
      if (close) { if (activeCaptureId === id) activeCaptureId = null; desktop.closeImage(id); }
      desktop.notify(action === 'copy' ? '图片已复制' : action === 'pin' ? '图片已贴到桌面' : '图片已保存');
      return { ...result, completed: true, session: completed };
    } finally { imageLocks.delete(id); }
  }
  async function cancelImage(id) {
    if (imageLocks.has(id)) throw new Error('请等待当前图片输出完成。');
    if (activeCaptureId === id) activeCaptureId = null;
    await images.cancel(id); desktop.closeImage(id); return { canceled: true };
  }
  async function prepareRecording() {
    if (state.preparing) { desktop.setupWindow?.show(); return; }
    if (recordings.activeId) { desktop.notify('正在录制，使用停止快捷键结束。'); return; }
    if (state.exporting) throw new Error('请等待当前视频生成完成。');
    return startCapture(async () => {
      hiddenForRecording = BrowserWindow.getAllWindows().filter(win => win.isVisible());
      for (const win of hiddenForRecording) win.hide();
      try {
        const captured = await snapshot();
        const config = { ...captured, png: undefined, imageUrl: `data:image/png;base64,${captured.png.toString('base64')}`, sourceWidth: captured.width, sourceHeight: captured.height, ...preferences.value };
        state.preparing = true; state.captureConfig = config; desktop.showSetup(config); desktop.updateMenu();
      } catch (error) { restoreAfterRecording(); throw error; }
    });
  }
  async function prepareRecorder(options) {
    if (!state.preparing || !state.captureConfig || prepareResolve) throw new Error('录制准备已结束或正在进行。');
    const generation = ++preparationGeneration;
    const config = { ...state.captureConfig, region: options?.region, microphone: options?.microphone, microphoneId: typeof options?.microphoneId === 'string' ? options.microphoneId.slice(0,500) : '', systemAudio: options?.systemAudio, cursor: options?.cursor !== false };
    // Keep the selected source/display authoritative; renderer only sets options.
    config.sourceId = state.captureConfig.sourceId;
    const r = config.region;
    if (!r || ![r.x, r.y, r.width, r.height].every(Number.isInteger) || r.x < 0 || r.y < 0 || r.width < 2 || r.height < 2 || r.x + r.width > config.sourceWidth || r.y + r.height > config.sourceHeight) throw new Error('请选择有效录制区域。');
    if (typeof config.microphone !== 'boolean' || typeof config.systemAudio !== 'boolean') throw new Error('声音设置无效。');
    await Promise.all([findExecutable('ffmpeg'), findExecutable('ffprobe')]);
    const check = path.join(recordings.directory, `.write-check-${randomUUID()}`);
    try { await writeFile(check, '', { flag: 'wx' }); } finally { await rm(check, { force: true }); }
    if (generation !== preparationGeneration || !state.preparing) throw new Error('已取消录制准备。');
    state.captureConfig = config;
    preparePromise = new Promise((resolve, reject) => { prepareResolve = resolve; prepareReject = reject; });
    void preparePromise.catch(() => {});
    let timer;
    try {
      const rec = await desktop.ensureRecorder();
      if (generation !== preparationGeneration || !state.preparing || rec.isDestroyed()) throw new Error('已取消录制准备。');
      rec.webContents.send('mooncap:prepare-recording', config);
      return await Promise.race([preparePromise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('录制准备超时，请检查权限后重试。')), 60000); })]);
    }
    catch (error) {
      if (generation === preparationGeneration) { prepareResolve = undefined; prepareReject = undefined; state.recorderPrepared = false; desktop.destroyRecorder(); }
      throw error;
    }
    finally { clearTimeout(timer); }
  }
  async function startPreparedRecording() {
    if (!state.preparing || !state.recorderPrepared) throw new Error('录制来源尚未准备好。');
    state.preparing = false; state.recordingPhase = 'requesting';
    desktop.closeSetup();
    // Wait for the prepared stream to receive frames without the countdown overlay.
    await wait(250);
    if (!desktop.recorderWindow || state.recordingPhase !== 'requesting') throw new Error('录制已取消。');
    desktop.recorderWindow.webContents.send('mooncap:start-recording', state.captureConfig);
    desktop.updateMenu();
    await preferences.update({ microphone: state.captureConfig.microphone, microphoneId: state.captureConfig.microphoneId, systemAudio: state.captureConfig.systemAudio });
    return { started: true };
  }
  async function cancelRecordingPreparation() {
    preparationGeneration++;
    state.preparing = false; state.recorderPrepared = false; state.recordingPhase = null;
    prepareReject?.(new Error('已取消录制准备。')); prepareResolve = undefined; prepareReject = undefined;
    desktop.recorderWindow?.webContents.send('mooncap:cancel-recorder-preparation');
    desktop.destroyRecorder(); desktop.closeSetup(); restoreAfterRecording(); desktop.updateMenu();
  }
  async function resetRecordingPreparation() {
    if (!state.preparing) throw new Error('录制已经开始。');
    preparationGeneration++;
    prepareReject?.(new Error('已返回录制准备。')); prepareResolve = undefined; prepareReject = undefined;
    state.recorderPrepared = false;
    desktop.destroyRecorder();
    return { reset: true };
  }
  async function previewMicrophone(enabled, deviceId) {
    if (!state.preparing || state.recorderPrepared) throw new Error('请先返回录制准备。');
    if (typeof enabled !== 'boolean') throw new Error('无效的麦克风状态。');
    if (!enabled && !desktop.recorderWindow) return;
    const recorder = await desktop.ensureRecorder();
    recorder.webContents.send('mooncap:preview-microphone', { enabled, deviceId: typeof deviceId === 'string' ? deviceId.slice(0,500) : '' });
  }
  function recorderPrepared(value) { state.recorderPrepared = true; prepareResolve?.(value); prepareResolve = undefined; prepareReject = undefined; return true; }
  async function recordingFailed(message) {
    prepareReject?.(new Error(message)); prepareReject = undefined;
    if (state.preparing) { prepareResolve = undefined; state.recorderPrepared = false; desktop.destroyRecorder(); desktop.notify(message); return; }
    if (recordings.activeId) await recordings.abort(recordings.activeId).catch(() => {});
    state.preparing = false; state.recordingPhase = null; state.recorderPrepared = false;
    desktop.closeControl(); desktop.closeSetup(); desktop.destroyRecorder(); restoreAfterRecording(); desktop.notify(message);
    if (state.quitAfterStop) desktop.finishQuit();
  }
  async function finishRecording(id, options) {
    const finishedRecorder = desktop.recorderWindow;
    state.recordingPhase = 'finishing'; desktop.updateMenu();
    try {
      const record = await recordings.finish(id, { ...options, ...(state.interruptedReason ? { interruptedReason: state.interruptedReason } : {}) });
      if (record.interruptedReason) desktop.notify(`录制中断，已保留原件：${record.interruptedReason}`);
      if (state.quitAfterStop) desktop.finishQuit(); else if (!record.interruptedReason && !state.interruptedReason) desktop.showVideo(id);
      else desktop.notify(`录制已停止，原件可从最近记录打开。${record.interruptedReason || state.interruptedReason}`);
      return record;
    } finally {
      state.recordingPhase = null; state.recorderPrepared = false; state.interruptedReason = null; desktop.closeControl(); restoreAfterRecording();
      // Let the IPC reply reach the recorder before disposing its media view.
      setTimeout(() => desktop.destroyRecorder(finishedRecorder), 250); desktop.updateMenu();
    }
  }
  async function exportVideo(id, plan, { mode = 'copy' } = {}) {
    if (state.exporting || state.exportPreparing || recordings.activeId || state.preparing || state.recordingPhase) throw new Error('请先结束当前录制或生成任务。');
    const record = recordings.get(id); validateExportPlan(plan, record);
    let destination = path.join(exportDirectory, `Mooncap-${Date.now()}-${randomUUID().slice(0, 8)}.mp4`);
    state.exportPreparing = true;
    try {
    if (mode === 'save') {
      const choice = await dialog.showSaveDialog({ title: '另存为 MP4', defaultPath: path.join(app.getPath('videos'), path.basename(destination)), filters: [{ name: 'MP4 视频', extensions: ['mp4'] }] });
      if (choice.canceled || !choice.filePath) return { canceled: true };
      destination = choice.filePath;
      destination = await protectOriginals(destination);
    } else if (mode !== 'copy') throw new Error('未知的视频输出方式。');
    state.exporting = true; state.exportId = id; state.exportProgress = 0; videoResults.delete(id); exportAbort = new AbortController(); desktop.updateMenu();
    } finally { state.exportPreparing = false; }
    const version = await clipboardVersion();
    const temporary = path.join(path.dirname(destination), `.mooncap-${randomUUID()}.mp4`);
    exportTask = (async () => {
      try {
        const result = await exportRecording(record, temporary, plan, { ffmpeg: await findExecutable('ffmpeg'), ffprobe: await findExecutable('ffprobe'), signal: exportAbort.signal,
          onProgress: progress => { state.exportProgress = progress; desktop.send('mooncap:export-progress', { id, progress }); } });
        await rename(temporary, destination); allowedOutputs.add(destination);
        let copied = { copied: false };
        if (mode === 'copy') { try { copied = await copyFileIfUnchanged(destination, version); } catch (error) { copied = { copied: false, copyError: error.message }; } }
        if (copied.copied) { desktop.notify('视频文件已复制'); }
        else desktop.notify(mode === 'save' ? '视频已保存' : '视频已生成，请点击复制');
        const final = { ...result, path: destination, ...copied };
        videoResults.set(id, { lastExport: final });
        desktop.send('mooncap:export-progress', { id, phase: 'complete', result: final });
        return final;
      } catch (error) {
        if (error.name === 'AbortError') { desktop.send('mooncap:export-progress', { id, phase: 'canceled' }); return { canceled: true }; }
        videoResults.set(id, { exportError: error.message }); desktop.notify(`视频生成失败：${error.message}`);
        desktop.send('mooncap:export-progress', { id, phase: 'error', error: error.message }); throw error;
      }
      finally { await rm(temporary, { force: true }).catch(() => {}); state.exporting = false; state.exportId = null; exportAbort = undefined; desktop.updateMenu(); }
    })();
    return exportTask;
  }
  async function cancelExport() { exportAbort?.abort(); await exportTask?.catch(() => {}); return { canceled: true }; }
  async function retryCopyVideo(filename) {
    if (!allowedOutputs.has(filename) || !filename.endsWith('.mp4')) throw new Error('找不到已生成的视频。');
    copyingOutputs.add(filename); try { return await copyFile(filename); } finally { copyingOutputs.delete(filename); }
  }
  function showInFolder(filename) { if (!allowedOutputs.has(filename)) throw new Error('只能显示本应用生成的文件。'); shell.showItemInFolder(filename); }
  async function history() { return { images: images.list(), recordings: await recordings.list(), exports: [...allowedOutputs], storage: await library.storage() }; }
  async function removeAsset(kind, id) {
    if (state.exporting || recordings.activeId || id === activeCaptureId) throw new Error('请先结束正在使用素材的任务。');
    const { response } = await dialog.showMessageBox({ message: '删除本机素材？', detail: '原件和编辑草稿将被删除。已导出文件单独保留。', buttons: ['取消', '删除'], cancelId: 0 });
    if (response !== 1) return { canceled: true };
    if (state.exporting || state.exportPreparing || recordings.activeId || id === activeCaptureId) throw new Error('素材正在使用，请稍后再删除。');
    if (kind === 'image') { if (imageLocks.has(id)) throw new Error('图片正在输出。'); await images.remove(id); desktop.closeImage(id); }
    else if (kind === 'video') { recordings.get(id); await rm(path.join(recordings.directory, id), { recursive: true }); recordings.records.delete(id); desktop.closeVideo(id); }
    else throw new Error('未知素材类型。');
    return { removed: true };
  }
  const handlers = {
    status: () => ({ activeCaptureId, recording: recordings.activeId, exporting: state.exporting, windows: desktop.windows.size, runtime: { name: 'Electron', version: process.versions.electron }, processes: app.getAppMetrics().map(item => ({ type: item.type, workingSetKiB: item.memory.workingSetSize })) }),
    list_windows: () => listSources(),
    capture: async ({ sourceId, region, name }) => { const value = await captureSource(sourceId, region, false); if (name) images.record(value.id).name = String(name).slice(0, 200); return previewResult(value.id); },
    import_image: async ({ path: filename }) => {
      if (!path.isAbsolute(filename) || (await stat(filename)).size > 100 * 1024 * 1024) throw new Error('需要小于 100 MiB 的本机图片绝对路径。');
      const bytes = nativeImage.createFromBuffer(await readFile(filename));
      if (bytes.isEmpty()) throw new Error('无法解码图片。');
      const size = bytes.getSize(); if (size.width * size.height > 80_000_000) throw new Error('图片超过 8000 万像素。');
      const value = await images.create({ png: bytes.toPNG(), name: path.basename(filename) }); return previewResult(value.id);
    },
    list_captures: () => images.list(), get_capture: ({ captureId }) => previewResult(captureId),
    annotate: async ({ captureId, expectedRevision, action = 'add', annotations, id, patch, ids }) => {
      const command = action === 'add' ? { type: 'add', annotations: annotations.map(item => ({ ...item, id: item.id || randomUUID() })) } : action === 'update' ? { type: 'update', id, patch } : { type: 'remove', ids };
      await applyImage(captureId, command, expectedRevision); return previewResult(captureId);
    },
    crop: async ({ captureId, region, expectedRevision }) => { await applyImage(captureId, { type: 'crop', rect: region }, expectedRevision); return previewResult(captureId); },
    undo: async ({ captureId, expectedRevision }) => { await applyImage(captureId, { type: 'undo' }, expectedRevision); return previewResult(captureId); },
    redo: async ({ captureId, expectedRevision }) => { await applyImage(captureId, { type: 'redo' }, expectedRevision); return previewResult(captureId); },
    preview: ({ captureId }) => previewResult(captureId),
    export: async ({ captureId, path: filename, overwrite = false }) => {
      if (!filename || !path.isAbsolute(filename) || !filename.toLowerCase().endsWith('.png')) throw new Error('导出需要绝对 PNG 路径。');
      if (!overwrite) { try { await stat(filename); throw new Error('文件已存在，需要显式允许覆盖。'); } catch (error) { if (error.code !== 'ENOENT') throw error; } }
      const { png } = await renderCapture(captureId); return savePng(png, filename);
    },
    present: ({ captureId }) => { desktop.showImage(images.get(captureId), captureId === activeCaptureId); return images.get(captureId, { image: false }); },
    pin: async ({ captureId }) => { const { png, session } = await renderCapture(captureId); desktop.pin(captureId, png, session.document.viewport.width, session.document.viewport.height); return { id: captureId, pinned: true, revision: session.document.revision }; },
    copy: async ({ captureId }) => { const { png, revision } = await renderCapture(captureId); await copyPng(png); return { id: captureId, revision, copied: true }; },
  };
  async function previewResult(id) { const { png, session } = await renderCapture(id); const { imageUrl, ...metadata } = session; return { ...metadata, image: `data:image/png;base64,${png.toString('base64')}` }; }
  const actions = { capture, captureSource, importImage, completeImage, cancelImage, applyImage, renderCapture, listSources, prepareRecording, prepareRecorder, previewMicrophone, resetRecordingPreparation, startPreparedRecording, cancelRecordingPreparation, recorderPrepared, recordingFailed, finishRecording, exportVideo, cancelExport, retryCopyVideo, showInFolder, history, removeAsset,
    imageClosed: async id => { if (activeCaptureId === id) activeCaptureId = null; try { if (!images.get(id, { image: false }).completed) await images.cancel(id); else await images.release(id); } catch {} },
    showExport: () => { if (state.exportId) desktop.showVideo(state.exportId); },
    getVideoState(id) { return { exporting: state.exporting && state.exportId === id, exportProgress: state.exportId === id ? state.exportProgress : 0, ...videoResults.get(id) }; },
    async environment() { return { platform: process.platform, screenPermission: process.platform === 'darwin' ? systemPreferences.getMediaAccessStatus('screen') : 'not-applicable', systemAudio: process.platform !== 'linux', settings: preferences.value, shortcuts: desktop.registered, directory }; },
  };
  desktop.setActions(actions);
  return { ...actions, images, handlers, allowedOutputs, library, get activeCaptureId() { return activeCaptureId; } };
}
