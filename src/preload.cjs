const { contextBridge, ipcRenderer } = require('electron');

function listen(channel, callback) {
  if (typeof callback !== 'function') throw new TypeError('A callback is required.');
  const listener = (_event, value) => callback(value);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld('mooncap', {
  sources: () => ipcRenderer.invoke('mooncap:sources'),
  selectSource: (id, systemAudio = false) => ipcRenderer.invoke('mooncap:select-source', id, systemAudio),
  beginRecording: (options) => ipcRenderer.invoke('mooncap:begin-recording', options),
  appendRecording: (id, sequence, bytes) => ipcRenderer.invoke('mooncap:append-recording', id, sequence, bytes),
  finishRecording: (id) => ipcRenderer.invoke('mooncap:finish-recording', id),
  abortRecording: (id) => ipcRenderer.invoke('mooncap:abort-recording', id),
  listRecordings: () => ipcRenderer.invoke('mooncap:list-recordings'),
  exportVideo: (id, plan) => ipcRenderer.invoke('mooncap:export-video', id, plan),
  saveImage: (bytes) => ipcRenderer.invoke('mooncap:save-image', bytes),
  copyImage: (bytes) => ipcRenderer.invoke('mooncap:copy-image', bytes),
  showInFolder: (path) => ipcRenderer.invoke('mooncap:show-in-folder', path),
  showRecordingsFolder: () => ipcRenderer.invoke('mooncap:show-recordings-folder'),
  environment: () => ipcRenderer.invoke('mooncap:environment'),
  requestStop: () => ipcRenderer.send('mooncap:request-stop'),
  onStopRequested: (callback) => listen('mooncap:stop-requested', callback),
  onExportProgress: (callback) => listen('mooncap:export-progress', callback),
});
