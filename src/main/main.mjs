import { app, dialog, protocol } from 'electron';
import path from 'node:path';
import { RecordingStore } from './recording-store.mjs';
import { createDesktopHost } from './desktop-host.mjs';
import { installApplicationIpc } from './application-ipc.mjs';
import { createMediaHandler } from './media-protocol.mjs';
import { Preferences } from './preferences.mjs';
import { createApplication } from './application.mjs';
import { createAgentServer } from './agent-server.mjs';

protocol.registerSchemesAsPrivileged([{ scheme: 'mooncap-media', privileges: { standard: true, secure: true, stream: true, supportFetchAPI: true } }]);

app.setName('mooncap');
if (process.env.MOONCAP_HOME) app.setPath('userData', path.resolve(process.env.MOONCAP_HOME));
let desktop, agent;
let openWorkbench = process.argv.includes('--workbench');
const state = { exporting: false, preparing: false, recordingPhase: null };

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_event, argv) => {
    if (argv.includes('--workbench')) {
      openWorkbench = true;
      desktop?.showLibrary();
    }
  });
  app.on('before-quit', (event) => desktop?.guardQuit(event));
  app.on('will-quit', () => { desktop?.dispose(); void agent?.dispose(); });
  // Closing the development workbench leaves MoonCap available in the tray.
  app.on('window-all-closed', () => {});
  app.on('activate', () => desktop?.showLibrary());

  app.whenReady().then(async () => {
    const directory = app.getPath('userData');
    const preferences = new Preferences(directory);
    await preferences.initialize();
    const store = new RecordingStore(path.join(directory, 'recordings'));
    await store.initialize();
    desktop = createDesktopHost(store, state, preferences);
    const application = await createApplication({ directory, recordings: store, desktop, state, preferences });
    protocol.handle('mooncap-media', createMediaHandler(store));
    installApplicationIpc({ application, recordings: store, desktop, state, preferences });
    agent = await createAgentServer({ directory: path.join(directory, 'agent'), handlers: application.handlers });
    screenChanges();
    if (openWorkbench) desktop.showLibrary();
    const importIndex = process.argv.indexOf('--import');
    if (importIndex >= 0 && process.argv[importIndex + 1]) await application.importImage(path.resolve(process.argv[importIndex + 1]));
    if (process.argv.includes('--capture')) await application.capture('region');
    if (process.argv.includes('--record')) await application.prepareRecording();
    function screenChanges() {
      import('electron').then(({ screen }) => {
        const changed = () => { if (store.activeId || state.preparing) { desktop.notify('显示器发生变化，已停止录制以保留当前内容。'); if (store.activeId) { state.interruptedReason = '显示器发生变化'; desktop.requestStop(); } else void application.cancelRecordingPreparation(); } };
        screen.on('display-removed', changed);
        screen.on('display-metrics-changed', (_event, _display, metrics) => { if (metrics.some(value => ['bounds', 'scaleFactor', 'rotation'].includes(value))) changed(); });
      });
    }
  }).catch((error) => {
    dialog.showErrorBox('MoonCap could not start', error.message);
    app.quit();
  });
}
