const {contextBridge,ipcRenderer}=require('electron');
const listen=(name,cb)=>{ipcRenderer.on(name,(_,value)=>cb(value));};
contextBridge.exposeInMainWorld('mooncap',{
 selectSource:async()=>{},recorderReady:()=>ipcRenderer.invoke('fixture:ready'),recorderPrepared:value=>ipcRenderer.invoke('fixture:prepared',value),recordingStarted:id=>ipcRenderer.invoke('fixture:started',id),recordingFailed:message=>ipcRenderer.invoke('fixture:failed',message),
 onPrepareRecording:cb=>listen('fixture:prepare',cb),onStartRecording:cb=>listen('fixture:start',cb),onStopRequested:cb=>listen('fixture:stop',cb),onCancelRecorderPreparation:cb=>listen('fixture:cancel',cb),
 beginRecording:value=>ipcRenderer.invoke('fixture:begin',value),appendRecording:(id,seq,bytes)=>ipcRenderer.invoke('fixture:append',id,seq,bytes),finishRecording:id=>ipcRenderer.invoke('fixture:finish',id),abortRecording:id=>ipcRenderer.invoke('fixture:abort',id),
});
