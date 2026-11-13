import { clipboard, desktopCapturer, ipcMain, session, shell } from 'electron';

export function installApplicationIpc({ application: service, recordings, desktop, state, preferences }) {
  const all = ['image', 'video', 'record-setup', 'recorder', 'library', 'pin', 'control'];
  const register = (name, roles, fn) => ipcMain.handle(`mooncap:${name}`, (event, ...args) => fn(desktop.authorize(event, roles), ...args));
  const imageId = (item, id) => { if (item.data.id !== id) throw new Error('截图不属于当前窗口。'); return id; };
  const videoId = (item, id) => { if (item.data.id !== id) throw new Error('录像不属于当前窗口。'); return id; };
  register('get-image-session', ['image'], item => ({ ...service.images.get(item.data.id), mode: item.data.overlay ? 'overlay' : 'window' }));
  register('apply-image-command', ['image'], (item, id, command, revision) => service.applyImage(imageId(item, id), command, revision));
  register('complete-image', ['image'], (item, id, action, bytes, revision) => service.completeImage(imageId(item, id), action, bytes, revision));
  register('cancel-image', ['image'], (item, id) => service.cancelImage(imageId(item, id)));
  register('get-recording', ['video'], (item, id) => ({ ...recordings.describe(recordings.get(videoId(item, id))), ...service.getVideoState(id) }));
  register('load-video-draft', ['video'], (item, id) => recordings.loadDraft(videoId(item, id)));
  register('save-video-draft', ['video'], (item, id, document) => { if (state.exporting && state.exportId === id) throw new Error('视频正在生成。'); return recordings.saveDraft(videoId(item, id), document); });
  register('export-video', ['video'], (item, id, plan, options) => service.exportVideo(videoId(item, id), plan, options));
  register('cancel-export', ['video', 'library'], () => service.cancelExport());
  register('retry-copy-video', ['video', 'library'], (_item, filename) => service.retryCopyVideo(filename));
  register('show-in-folder', ['video', 'library'], (_item, filename) => service.showInFolder(filename));
  register('copy-path', ['video', 'library'], async (_item, filename) => { if (!service.allowedOutputs.has(filename)) throw new Error('未知文件。'); await clipboard.writeText(filename); return true; });
  register('capture-setup', ['record-setup'], item => item.data.config);
  register('prepare-recorder', ['record-setup'], (_item, options) => service.prepareRecorder(options));
  register('preview-microphone', ['record-setup'], (_item, enabled, deviceId) => service.previewMicrophone(enabled, deviceId));
  register('microphone-info', ['recorder'], (_item, info) => { desktop.setupWindow?.webContents.send('mooncap:microphone-info', info); });
  register('reset-recording-preparation', ['record-setup'], () => service.resetRecordingPreparation());
  register('start-prepared-recording', ['record-setup'], () => service.startPreparedRecording());
  register('cancel-recording-preparation', ['record-setup'], () => service.cancelRecordingPreparation());
  register('recorder-ready', ['recorder'], () => desktop.markRecorderReady());
  register('recorder-prepared', ['recorder'], (_item, value) => service.recorderPrepared(value));
  register('recording-failed', ['recorder'], (_item, message) => service.recordingFailed(String(message).slice(0, 1000)));
  register('recording-started', ['recorder'], () => { state.recordingPhase = 'recording'; desktop.openControl(); desktop.updateMenu(); return true; });
  register('select-source', ['recorder'], (_item, id, systemAudio) => { if (id !== state.captureConfig?.sourceId || systemAudio !== state.captureConfig?.systemAudio) throw new Error('录制来源不匹配。'); return { id, systemAudio }; });
  register('begin-recording', ['recorder'], (_item, options) => { if (state.recordingPhase !== 'requesting') throw new Error('未请求开始录制。'); return recordings.begin(options); });
  register('append-recording', ['recorder'], (_item, id, sequence, bytes) => recordings.append(id, sequence, bytes));
  register('finish-recording', ['recorder'], (_item, id, options) => service.finishRecording(id, options));
  register('abort-recording', ['recorder'], async (item, id) => { await recordings.abort(id); state.recordingPhase = null; desktop.closeControl(); setTimeout(() => desktop.destroyRecorder(item.window), 250); });
  register('request-stop', ['control', 'record-setup', 'library'], () => desktop.requestStop());
  ipcMain.on('mooncap:request-stop', event => { try { desktop.authorize(event, ['control', 'library']); desktop.requestStop(); } catch {} });
  register('environment', all, () => service.environment());
  register('get-library', ['library'], async item => ({ ...await service.history(), section: item.data.section, environment: await service.environment() }));
  register('asset-thumbnail', ['library'], (_item, kind, id) => service.library.thumbnail(kind, id));
  register('reveal-asset', ['library'], (_item, kind, id) => service.library.revealAsset(kind, id));
  register('delete-export', ['library'], (_item, filename) => service.library.deleteExport(filename));
  register('list-recordings', ['video', 'library'], () => recordings.list());
  register('sources', ['library'], () => service.listSources());
  register('capture-source', ['library'], (_item, id) => service.captureSource(id));
  register('capture', ['library'], (_item, mode) => service.capture(mode));
  register('prepare-recording', ['library'], () => service.prepareRecording());
  register('import-image', ['library'], () => service.importImage());
  register('open-asset', ['library'], (_item, kind, id) => { if (kind === 'image') desktop.showImage(service.images.get(id)); else { recordings.get(id); desktop.showVideo(id); } });
  register('remove-asset', ['library'], (_item, kind, id) => service.removeAsset(kind, id));
  register('save-preferences', ['library'], async (_item, patch) => { await preferences.update(patch); const shortcuts = desktop.registerShortcuts(); return { settings: preferences.value, shortcuts }; });
  register('open-data-folder', ['library'], () => shell.openPath(preferences.directory));
  register('open-permissions', ['library', 'record-setup'], () => process.platform === 'darwin' ? shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture') : undefined);
  register('get-pin', ['pin'], item => ({ ...item.data, session: service.images.get(item.data.id) }));
  register('pin-action', ['pin'], async (item, action) => {
    if (action === 'close') item.window.destroy();
    else if (action === 'edit') desktop.showImage(service.images.get(item.data.id));
    else if (action === 'copy') await service.handlers.copy({ captureId: item.data.id });
    else if (action === 'through') item.window.setIgnoreMouseEvents(true, { forward: true });
    else throw new Error('未知贴图操作。');
  });
  const mediaAllowed = contents => ['recorder'].includes(desktop.itemFor(contents)?.role);
  session.defaultSession.setPermissionCheckHandler((contents, permission) => mediaAllowed(contents) && ['media', 'display-capture'].includes(permission));
  session.defaultSession.setPermissionRequestHandler((contents, permission, callback) => callback(mediaAllowed(contents) && ['media', 'display-capture'].includes(permission)));
  session.defaultSession.setDisplayMediaRequestHandler(async (request, callback) => {
    const item = desktop.itemFor(desktop.recorderWindow?.webContents);
    if (!item || request.frame !== desktop.recorderWindow.webContents.mainFrame || !state.captureConfig) return callback(null);
    try {
      const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 0, height: 0 } });
      const source = sources.find(candidate => candidate.id === state.captureConfig.sourceId);
      if (!source) return callback(null);
      callback({ video: source, ...(state.captureConfig.systemAudio && request.audioRequested ? { audio: 'loopback' } : {}) });
    } catch { callback(null); }
  });
}
