const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('mooncap', {
  getCaptureSetup: () => ipcRenderer.invoke('setup:get'),
  environment: () => ipcRenderer.invoke('setup:environment'),
  previewMicrophone: (enabled, deviceId) => ipcRenderer.invoke('setup:preview-microphone', enabled, deviceId),
  onMicrophoneInfo(callback) {
    const listener = (_event, value) => callback(value);
    ipcRenderer.on('setup:microphone-info', listener);
    return () => ipcRenderer.removeListener('setup:microphone-info', listener);
  },
  prepareRecorder: options => ipcRenderer.invoke('setup:prepare', options),
  resetRecordingPreparation: () => ipcRenderer.invoke('setup:reset'),
  startPreparedRecording: () => ipcRenderer.invoke('setup:start'),
  cancelRecordingPreparation: () => ipcRenderer.invoke('setup:cancel'),
});
