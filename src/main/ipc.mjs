import { app, ClipboardItem, clipboard, desktopCapturer, dialog, ipcMain, nativeImage, session, shell, systemPreferences } from 'electron';
import { open, realpath, rename, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { exportRecording, validateExportPlan } from './media-export.mjs';
import { findExecutable } from './media-tools.mjs';
import { validatePng } from './media-input.mjs';

export function installHostIpc(store, desktop, state) {
  const allowedOutputs = new Set();
  let selection;

  async function protectOriginals(destination) {
    const directory = await realpath(path.dirname(destination));
    const originals = await realpath(store.directory);
    const relative = path.relative(originals, directory);
    if (!relative || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) {
      throw new Error('Choose a save location outside the originals folder. Original recordings are kept for recovery.');
    }
  }

  function register(name, handler) {
    ipcMain.handle(`mooncap:${name}`, async (event, ...args) => {
      if (event.sender !== desktop.window?.webContents || event.senderFrame?.url !== desktop.trustedPage || event.senderFrame !== event.sender.mainFrame) {
        throw new Error('This operation is only available in the Mooncap window.');
      }
      return handler(...args);
    });
  }

  register('sources', async () => {
    const sources = await desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 320, height: 180 }, fetchWindowIcons: true });
    return sources.filter((source) => source.name !== 'Mooncap recording').map((source) => ({
      id: source.id, name: source.name, displayId: source.display_id,
      thumbnail: source.thumbnail.isEmpty() ? null : source.thumbnail.toDataURL(),
      appIcon: source.appIcon?.isEmpty() === false ? source.appIcon.toDataURL() : null,
    }));
  });
  register('select-source', async (id, systemAudio = false) => {
    if (typeof id !== 'string' || id.length > 200 || typeof systemAudio !== 'boolean') throw new Error('Invalid capture source.');
    if (store.activeId) throw new Error('Finish the current recording before changing sources.');
    const sources = await desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 0, height: 0 } });
    if (!sources.some((source) => source.id === id)) throw new Error('That capture source is no longer available. Refresh the list.');
    if (systemAudio && process.platform === 'linux') throw new Error('System audio capture is not yet enabled on Linux. Use microphone audio or video only.');
    selection = { id, systemAudio };
    return { id, systemAudio };
  });
  register('begin-recording', async (options = {}) => {
    if (state.exporting) throw new Error('Wait for the current export to finish.');
    if (!options || typeof options !== 'object' || Array.isArray(options)) throw new Error('Invalid recording options.');
    const result = await store.begin(options);
    desktop.openControl();
    return result;
  });
  register('append-recording', (id, sequence, bytes) => store.append(id, sequence, bytes));
  register('finish-recording', async (id) => {
    try { return await store.finish(id); }
    finally { if (!store.activeId) desktop.closeControl(); }
  });
  register('abort-recording', async (id) => {
    await store.abort(id);
    if (!store.activeId) desktop.closeControl();
  });
  register('list-recordings', () => store.list());
  register('export-video', async (id, plan) => {
    if (state.exporting || store.activeId) throw new Error('Finish the current recording or export first.');
    const record = store.get(id);
    validateExportPlan(plan, record);
    state.exporting = true;
    desktop.updateMenu();
    let temporary;
    try {
      const ffmpeg = await findExecutable('ffmpeg');
      const { canceled, filePath } = await dialog.showSaveDialog(desktop.window, {
        title: 'Export MP4', defaultPath: path.join(app.getPath('videos'), `Mooncap-${Date.now()}.mp4`),
        filters: [{ name: 'MP4 video', extensions: ['mp4'] }],
      });
      if (canceled || !filePath) return null;
      const destination = filePath;
      await protectOriginals(destination);
      temporary = path.join(path.dirname(destination), `.mooncap-${randomUUID()}.mp4`);
      const result = await exportRecording(record, temporary, plan, {
        ffmpeg, onProgress: (progress) => desktop.send('mooncap:export-progress', { id, progress }),
      });
      // The save dialog supplies overwrite consent. A completed temporary export
      // replaces the destination only after the encoder has exited successfully.
      await rename(temporary, destination);
      temporary = undefined;
      allowedOutputs.add(destination);
      return { ...result, path: destination };
    } finally {
      state.exporting = false;
      desktop.updateMenu();
      if (temporary) await unlink(temporary).catch(() => {});
    }
  });
  register('save-image', async (input) => {
    const bytes = validatePng(input);
    if (nativeImage.createFromBuffer(bytes).isEmpty()) throw new Error('The PNG image could not be decoded.');
    const { canceled, filePath } = await dialog.showSaveDialog(desktop.window, {
      title: 'Save screenshot', defaultPath: path.join(app.getPath('pictures'), `Mooncap-${Date.now()}.png`),
      filters: [{ name: 'PNG image', extensions: ['png'] }],
    });
    if (canceled || !filePath) return null;
    const destination = filePath;
    await protectOriginals(destination);
    const temporary = path.join(path.dirname(destination), `.mooncap-${randomUUID()}.png`);
    const handle = await open(temporary, 'wx');
    try {
      await handle.writeFile(bytes);
      await handle.sync();
      await handle.close();
      await rename(temporary, destination);
    } catch (error) {
      await handle.close().catch(() => {});
      await unlink(temporary).catch(() => {});
      throw error;
    }
    allowedOutputs.add(destination);
    return { path: destination, size: bytes.length };
  });
  register('copy-image', async (input) => {
    const bytes = validatePng(input);
    if (nativeImage.createFromBuffer(bytes).isEmpty()) throw new Error('The PNG image could not be decoded.');
    await clipboard.write([new ClipboardItem({ 'image/png': new Blob([bytes], { type: 'image/png' }) })]);
    return true;
  });
  register('show-in-folder', async (filename) => {
    if (typeof filename !== 'string' || !allowedOutputs.has(filename)) throw new Error('Choose a file saved by Mooncap in this session.');
    shell.showItemInFolder(filename);
  });
  register('show-recordings-folder', () => shell.openPath(store.directory));
  register('environment', async () => {
    const tools = await Promise.all(['ffmpeg', 'ffprobe'].map(async (name) => {
      try { await findExecutable(name); return [name, true]; }
      catch { return [name, false]; }
    }));
    return {
      platform: process.platform, tools: Object.fromEntries(tools),
      screenPermission: process.platform === 'darwin' ? systemPreferences.getMediaAccessStatus('screen') : 'not-applicable',
      systemAudio: process.platform === 'darwin' || process.platform === 'win32',
      stopShortcut: { accelerator: desktop.stopAccelerator, registered: desktop.shortcutRegistered },
    };
  });
  ipcMain.on('mooncap:request-stop', (event) => {
    if (event.sender === desktop.controlWindow?.webContents || (event.sender === desktop.window?.webContents && event.senderFrame?.url === desktop.trustedPage)) desktop.requestStop();
  });

  const trustedRequest = (contents, origin) => contents === desktop.window?.webContents && (origin === 'file://' || origin === 'file:///' || origin === 'null' || origin === desktop.trustedPage);
  session.defaultSession.setPermissionCheckHandler((contents, permission, origin) => trustedRequest(contents, origin) && (permission === 'media' || permission === 'display-capture'));
  session.defaultSession.setPermissionRequestHandler((contents, permission, callback) => {
    callback(contents === desktop.window?.webContents && contents.getURL() === desktop.trustedPage && (permission === 'media' || permission === 'display-capture'));
  });
  session.defaultSession.setDisplayMediaRequestHandler(async (request, callback) => {
    if (!selection || request.frame !== desktop.window?.webContents.mainFrame || request.frame?.url !== desktop.trustedPage) return callback(null);
    try {
      const chosen = { ...selection };
      const sources = await desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 0, height: 0 } });
      const source = sources.find((candidate) => candidate.id === chosen.id);
      if (!source) return callback(null);
      callback({ video: source, ...(chosen.systemAudio && request.audioRequested ? { audio: 'loopback' } : {}) });
    } catch { callback(null); }
  });
}
