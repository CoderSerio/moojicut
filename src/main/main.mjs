import { app, dialog, protocol } from 'electron';
import path from 'node:path';
import { RecordingStore } from './recording-store.mjs';
import { createDesktopShell } from './desktop-shell.mjs';
import { installHostIpc } from './ipc.mjs';
import { createMediaHandler } from './media-protocol.mjs';

protocol.registerSchemesAsPrivileged([{ scheme: 'mooncap-media', privileges: { standard: true, secure: true, stream: true, supportFetchAPI: true } }]);

let desktop;
let openWorkbench = process.argv.includes('--workbench');
const state = { exporting: false };

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_event, argv) => {
    if (argv.includes('--workbench')) {
      openWorkbench = true;
      desktop?.showWorkbench();
    }
  });
  app.on('before-quit', (event) => desktop?.guardQuit(event));
  app.on('will-quit', () => desktop?.dispose());
  // Closing the development workbench leaves MoonCap available in the tray.
  app.on('window-all-closed', () => {});
  app.on('activate', () => { if (desktop?.window) desktop.showWorkbench(); });

  app.whenReady().then(async () => {
    const store = new RecordingStore(path.join(app.getPath('userData'), 'recordings'));
    await store.initialize();
    desktop = createDesktopShell(store, state);
    protocol.handle('mooncap-media', createMediaHandler(store));
    installHostIpc(store, desktop, state);
    if (openWorkbench) desktop.showWorkbench();
  }).catch((error) => {
    dialog.showErrorBox('MoonCap could not start', error.message);
    app.quit();
  });
}
