import { app, BrowserWindow, dialog, globalShortcut, Menu, nativeImage, Notification, screen, Tray } from 'electron';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const renderer = path.resolve(here, '../renderer');
const preload = path.resolve(here, '../preload.cjs');

// Disposable views. Documents and tasks belong to the application services,
// so a future system-WebView host can replace this Electron adapter.
export function createDesktopHost(store, state, preferences) {
  const windows = new Map();
  let actions = {}, setup, recorder, control, library, recorderReady, resolveRecorderReady;
  let quitting = false, quitDialog = false;
  const registered = {};
  const icon = nativeImage.createFromPath(path.join(here, 'assets', process.platform === 'darwin' ? 'trayTemplate.png' : 'tray.png'));
  if (icon.isEmpty()) throw new Error('无法加载菜单栏图标。');
  if (process.platform === 'darwin') icon.setTemplateImage(true);
  const tray = new Tray(icon);
  const perform = (fn) => () => Promise.resolve().then(fn).catch(error => dialog.showErrorBox('Mooncap', error.message));

  function make(role, filename, options = {}, data = {}) {
    const page = pathToFileURL(path.join(renderer, filename)).href;
    const win = new BrowserWindow({ width: 940, height: 680, backgroundColor: '#171b23', title: 'Mooncap', show: false, ...options,
      webPreferences: { preload, contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: role !== 'recorder', ...(options.webPreferences || {}) } });
    const contentsId = win.webContents.id;
    windows.set(contentsId, { window: win, role, page, data });
    win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    win.webContents.on('will-navigate', event => event.preventDefault());
    win.webContents.on('console-message', details => { if (details.level === 'error' || details.level === 3) console.error(`[${role}]`, details.message); });
    win.webContents.on('render-process-gone', (_event, details) => {
      console.error(`[${role}] renderer exited`, details.reason);
      if (role === 'recorder') void actions.recordingFailed?.('录制进程意外结束，已写入的原件将保留。');
    });
    win.on('closed', () => { windows.delete(contentsId); updateMenu(); });
    void win.loadFile(path.join(renderer, filename), { query: data.id ? { id: data.id } : {} }).catch(console.error);
    return win;
  }
  function authorize(event, roles) {
    const item = windows.get(event.sender.id);
    if (!item || !roles.includes(item.role) || event.senderFrame !== event.sender.mainFrame || event.senderFrame.url.split('?')[0] !== item.page) throw new Error('此操作不属于当前窗口。');
    return item;
  }
  function send(channel, value) { for (const { window } of windows.values()) if (!window.isDestroyed()) window.webContents.send(channel, value); }
  function updateMenu() {
    const busy = Boolean(store.activeId || state.preparing || state.recordingPhase);
    tray.setToolTip(busy ? 'Mooncap · 正在录制或准备' : state.exporting ? 'Mooncap · 正在生成视频' : 'Mooncap');
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: '截图', accelerator: preferences.value.screenshotShortcut, click: perform(() => actions.capture?.('region')) },
      { label: '截取当前屏幕', click: perform(() => actions.capture?.('screen')) },
      { label: '窗口截图…', click: () => showLibrary('sources') },
      { label: '导入图片…', click: perform(() => actions.importImage?.()) },
      { type: 'separator' },
      { label: '录屏', accelerator: preferences.value.recordingShortcut, enabled: !state.exporting, click: perform(() => actions.prepareRecording?.()) },
      { label: state.recordingPhase === 'finishing' ? '正在完成录制…' : '停止录制', enabled: Boolean(store.activeId), accelerator: preferences.value.stopShortcut, click: requestStop },
      ...(state.exporting ? [{ label: '查看视频生成进度', click: () => actions.showExport?.() }] : []),
      { type: 'separator' },
      { label: '最近记录', click: () => showLibrary('history') },
      { label: '恢复所有贴图交互', click: () => { for (const item of windows.values()) if (item.role === 'pin') item.window.setIgnoreMouseEvents(false); } },
      { label: '设置', click: () => showLibrary('settings') },
      { type: 'separator' }, { label: '退出 Mooncap', click: () => app.quit() },
    ]));
  }
  function registerShortcuts() {
    for (const key of Object.values(registered)) globalShortcut.unregister(key);
    for (const key of Object.keys(registered)) delete registered[key];
    for (const [name, action] of [['screenshotShortcut', () => actions.capture?.('region')], ['recordingShortcut', () => actions.prepareRecording?.()], ['stopShortcut', requestStop]]) {
      const accelerator = preferences.value[name];
      try { if (globalShortcut.register(accelerator, perform(action))) registered[name] = accelerator; } catch { /* shown in settings */ }
    }
    updateMenu(); return { ...registered };
  }
  function showImage(session, overlay = false) {
    const existing = [...windows.values()].find(item => item.role === 'image' && item.data.id === session.id);
    if (existing) { existing.window.show(); existing.window.focus(); return existing.window; }
    const bounds = session.displayBounds || screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).bounds;
    const options = overlay ? { ...bounds, frame: false, resizable: false, movable: false, alwaysOnTop: true, skipTaskbar: true, hasShadow: false } : { width: 1040, height: 760, minWidth: 620, minHeight: 440 };
    const win = make('image', 'image-editor.html', options, { id: session.id, overlay });
    if (overlay) { win.setAlwaysOnTop(true, 'screen-saver'); win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true }); }
    win.once('ready-to-show', () => { win.show(); win.focus(); });
    win.on('closed', () => { void actions.imageClosed?.(session.id); });
    return win;
  }
  function closeImage(id) { for (const item of [...windows.values()]) if (item.role === 'image' && item.data.id === id) item.window.destroy(); }
  function showVideo(id) {
    const existing = [...windows.values()].find(item => item.role === 'video' && item.data.id === id);
    if (existing) { existing.window.show(); existing.window.focus(); return existing.window; }
    const win = make('video', 'video-editor.html', { width: 1080, height: 780, minWidth: 800, minHeight: 600 }, { id });
    win.once('ready-to-show', () => win.show()); return win;
  }
  function closeVideo(id) { for (const item of [...windows.values()]) if (item.role === 'video' && item.data.id === id) item.window.destroy(); }
  function showLibrary(section = 'history') {
    if (library && !library.isDestroyed()) { windows.get(library.webContents.id).data.section = section; library.webContents.send('mooncap:library-section', section); library.show(); library.focus(); return; }
    library = make('library', 'library.html', { width: 820, height: 650, minWidth: 620, minHeight: 460 }, { section });
    library.once('ready-to-show', () => library.show());
  }
  function showSetup(config) {
    if (setup && !setup.isDestroyed()) { setup.show(); setup.focus(); return; }
    setup = make('record-setup', 'record-setup.html', { ...config.displayBounds, frame: false, resizable: false, movable: false, alwaysOnTop: true, skipTaskbar: true, hasShadow: false }, { config });
    setup.setAlwaysOnTop(true, 'screen-saver'); setup.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    setup.once('ready-to-show', () => setup?.show());
    setup.on('closed', () => { setup = undefined; if (state.preparing) void actions.cancelRecordingPreparation?.(); });
  }
  function closeSetup() { if (setup && !setup.isDestroyed()) setup.destroy(); setup = undefined; }
  async function ensureRecorder() {
    if (!recorder || recorder.isDestroyed()) {
      recorderReady = new Promise(resolve => { resolveRecorderReady = resolve; });
      recorder = make('recorder', 'recorder.html', { width: 32, height: 32, skipTaskbar: true, webPreferences: { backgroundThrottling: false } });
    }
    let timer;
    try { await Promise.race([recorderReady, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('录制组件启动超时。')), 15000); })]); }
    finally { clearTimeout(timer); }
    return recorder;
  }
  function destroyRecorder(expected = recorder) { if (expected && !expected.isDestroyed()) expected.destroy(); if (recorder === expected) recorder = undefined; }
  function requestStop() { if (recorder && !recorder.isDestroyed()) recorder.webContents.send('mooncap:stop-requested'); }
  function openControl() {
    closeControl();
    const display = state.captureConfig?.displayBounds, region = state.captureConfig?.region;
    const factor = state.captureConfig?.scaleFactor || 1;
    if (!display || !region) return;
    const top = display.y + region.y / factor, bottom = display.y + (region.y + region.height) / factor;
    const y = top - display.y >= 80 ? top - 70 : display.y + display.height - bottom >= 80 ? bottom + 10 : null;
    if (y === null) return;
    control = make('control', 'control.html', { width: 290, height: 56, x: Math.round(display.x + 20), y: Math.round(y), resizable: false, frame: false, alwaysOnTop: true, skipTaskbar: true });
    control.once('ready-to-show', () => control?.showInactive());
    control.on('close', event => { if (store.activeId && !quitting) { event.preventDefault(); requestStop(); } });
  }
  function closeControl() { if (control && !control.isDestroyed()) control.destroy(); control = undefined; updateMenu(); }
  function pin(id, png, width, height) {
    const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
    const ratio = Math.min(1, 640 / width, 480 / height);
    const win = make('pin', 'pin.html', { width: Math.max(120, Math.round(width * ratio)), height: Math.max(80, Math.round(height * ratio)), x: area.x + 50, y: area.y + 50, frame: false, alwaysOnTop: true, skipTaskbar: true, backgroundColor: '#00000000' }, { id, imageUrl: `data:image/png;base64,${Buffer.from(png).toString('base64')}` });
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true }); win.once('ready-to-show', () => win.showInactive()); return win;
  }
  function notify(text) {
    tray.setToolTip(`Mooncap · ${text}`); send('mooncap:notice', text);
    if (Notification.isSupported() && ![...windows.values()].some(item => item.window.isVisible() && ['image','video','library','record-setup'].includes(item.role))) {
      const notification = new Notification({ title: 'Mooncap', body: text, silent: true });
      notification.on('click', () => showLibrary()); notification.show();
    }
  }
  async function guardQuit(event) {
    if (quitting || (!store.activeId && !state.preparing && !state.exporting)) return;
    event.preventDefault(); if (quitDialog) return; quitDialog = true;
    try {
      if (store.activeId) {
        const { response } = await dialog.showMessageBox({ message: '录制仍在进行', detail: '停止并保留原件后退出，或继续录制。', buttons: ['继续录制', '停止并保留后退出'], cancelId: 0 });
        if (response === 1) { state.quitAfterStop = true; requestStop(); }
      } else if (state.exporting) {
        const { response } = await dialog.showMessageBox({ message: '视频仍在生成', buttons: ['继续等待', '取消导出并退出'], cancelId: 0 });
        if (response === 1) { await actions.cancelExport?.(); quitting = true; app.quit(); }
      } else { await actions.cancelRecordingPreparation?.(); quitting = true; app.quit(); }
    } finally { quitDialog = false; }
  }
  function dispose() { for (const key of Object.values(registered)) globalShortcut.unregister(key); tray.destroy(); }
  Menu.setApplicationMenu(Menu.buildFromTemplate([...(process.platform === 'darwin' ? [{ role: 'appMenu' }] : []), { role: 'editMenu' }, { role: 'windowMenu' }]));
  if (process.platform === 'darwin') app.dock.hide(); updateMenu();
  return { windows, authorize, itemFor: contents => contents ? windows.get(contents.id) : undefined, send, updateMenu, registerShortcuts, registered, showImage, closeImage, showVideo, closeVideo, showLibrary, showSetup, closeSetup, ensureRecorder, markRecorderReady: () => resolveRecorderReady?.(), destroyRecorder, requestStop, openControl, closeControl, pin, notify, guardQuit, dispose,
    finishQuit() { quitting = true; app.quit(); }, setActions(value) { actions = value; registerShortcuts(); },
    get setupWindow() { return setup; }, get recorderWindow() { return recorder; },
    get stopAccelerator() { return preferences.value.stopShortcut; }, get shortcutRegistered() { return Boolean(registered.stopShortcut); },
  };
}
