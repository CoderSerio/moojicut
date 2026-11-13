import { app, BrowserWindow, dialog, globalShortcut, Menu, nativeImage, screen, shell, Tray } from 'electron';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const indexPath = path.resolve(here, '../renderer/index.html');
const controlPath = path.join(here, 'control.html');
const preload = path.resolve(here, '../preload.cjs');
const stopAccelerator = 'CommandOrControl+Shift+X';

function protectWindow(window, trustedPage) {
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event, url) => {
    if (url !== trustedPage) event.preventDefault();
  });
}

export function createDesktopShell(store, state) {
  let window;
  let controlWindow;
  let pendingCloseNotice = false;
  const trustedPage = pathToFileURL(indexPath).href;
  const iconName = process.platform === 'darwin' ? 'trayTemplate.png' : 'tray.png';
  const icon = nativeImage.createFromPath(path.join(here, 'assets', iconName));
  if (icon.isEmpty()) throw new Error('The MoonCap menu bar icon could not be loaded.');
  if (process.platform === 'darwin') icon.setTemplateImage(true);
  const tray = new Tray(icon);
  tray.setToolTip('MoonCap');

  function busy() { return Boolean(store.activeId || store.starting || state.exporting); }

  function send(channel, value) {
    if (window && !window.isDestroyed()) window.webContents.send(channel, value);
  }

  function requestStop() {
    if (store.activeId) send('mooncap:stop-requested');
  }

  const shortcutRegistered = globalShortcut.register(stopAccelerator, requestStop);
  if (!shortcutRegistered) {
    console.warn('MoonCap could not register Ctrl/⌘+Shift+X. Use the recording control or tray menu to stop.');
  }

  function updateMenu() {
    const stopItem = () => ({
      label: shortcutRegistered ? '停止录制' : '停止录制（全局快捷键未注册）',
      enabled: Boolean(store.activeId), click: requestStop,
    });
    const items = [
      { label: 'MoonCap 开发工作台', click: showWorkbench },
      stopItem(),
      { type: 'separator' },
      { label: '打开录像原件目录', click: () => shell.openPath(store.directory) },
      { type: 'separator' },
      { label: '退出 MoonCap', click: () => app.quit() },
    ];
    tray.setContextMenu(Menu.buildFromTemplate(items));
    Menu.setApplicationMenu(Menu.buildFromTemplate([
      ...(process.platform === 'darwin' ? [{ role: 'appMenu' }] : []),
      { label: 'MoonCap', submenu: [items[0], { ...stopItem(), accelerator: stopAccelerator }, { type: 'separator' }, items[3]] },
      { role: 'editMenu' }, { role: 'windowMenu' },
    ]));
  }

  function closeControl() {
    if (controlWindow && !controlWindow.isDestroyed()) controlWindow.destroy();
    controlWindow = undefined;
    updateMenu();
  }

  function openControl() {
    closeControl();
    const area = screen.getPrimaryDisplay().workArea;
    controlWindow = new BrowserWindow({
      width: 276, height: 74, x: area.x + area.width - 296, y: area.y + 20,
      resizable: false, minimizable: false, maximizable: false, alwaysOnTop: true,
      skipTaskbar: true, title: 'Mooncap recording', frame: false, show: false,
      webPreferences: { preload, contextIsolation: true, nodeIntegration: false, sandbox: true },
    });
    protectWindow(controlWindow, pathToFileURL(controlPath).href);
    controlWindow.setAlwaysOnTop(true, 'floating');
    controlWindow.on('close', (event) => {
      if (store.activeId) { event.preventDefault(); requestStop(); }
    });
    controlWindow.once('ready-to-show', () => controlWindow?.showInactive());
    void controlWindow.loadFile(controlPath);
  }

  async function guardClose(event) {
    if (!busy()) return;
    event.preventDefault();
    if (pendingCloseNotice) return;
    pendingCloseNotice = true;
    try {
      const recording = Boolean(store.activeId || store.starting);
      const { response } = await dialog.showMessageBox(window, {
        type: 'info', title: 'Work is still in progress',
        message: recording ? 'Stop and save the recording before closing MoonCap.' : 'Wait for the export to finish before closing MoonCap.',
        buttons: recording ? ['Keep recording', 'Stop recording'] : ['Keep open'], cancelId: 0,
      });
      if (recording && response === 1) requestStop();
    } finally { pendingCloseNotice = false; }
  }

  function showWorkbench() {
    if (window && !window.isDestroyed()) {
      if (window.isMinimized()) window.restore();
      window.show();
      window.focus();
      return window;
    }
    if (process.platform === 'darwin') void app.dock.show();
    window = new BrowserWindow({
      width: 1180, height: 820, minWidth: 780, minHeight: 620, title: 'MoonCap 开发工作台', show: false,
      webPreferences: { preload, contextIsolation: true, nodeIntegration: false, sandbox: true },
    });
    const opened = window;
    protectWindow(opened, trustedPage);
    opened.on('page-title-updated', (event) => event.preventDefault());
    opened.on('close', guardClose);
    opened.once('ready-to-show', () => { if (!opened.isDestroyed()) opened.show(); });
    opened.on('closed', () => {
      if (window === opened) window = undefined;
      if (process.platform === 'darwin') app.dock.hide();
    });
    opened.webContents.on('render-process-gone', async () => {
      if (store.activeId) await store.abort(store.activeId).catch(() => {});
      closeControl();
    });
    void opened.loadFile(indexPath);
    return opened;
  }

  function guardQuit(event) {
    if (!busy()) return;
    event.preventDefault();
    showWorkbench();
    // A quit request does not discard a recording; it requests the normal
    // recorder stop/flush path. The user can quit after it finishes.
    requestStop();
  }

  function dispose() {
    if (shortcutRegistered) globalShortcut.unregister(stopAccelerator);
    tray.destroy();
  }

  updateMenu();
  if (process.platform === 'darwin') app.dock.hide();
  return {
    get window() { return window; },
    get controlWindow() { return controlWindow; },
    trustedPage, stopAccelerator, shortcutRegistered,
    send, requestStop, updateMenu, openControl, closeControl, showWorkbench, guardQuit, dispose,
  };
}
