const { contextBridge, ipcRenderer }=require('electron');
contextBridge.exposeInMainWorld('mooncap',{
 getImageSession:()=>ipcRenderer.invoke('test:get'),
 getPin:()=>ipcRenderer.invoke('test:pin'),
 pinAction:action=>ipcRenderer.invoke('test:pin-action',action),
 applyImageCommand:(id,command,expectedRevision)=>ipcRenderer.invoke('test:apply',command,expectedRevision),
 completeImage:(id,action,bytes,revision)=>ipcRenderer.invoke('test:complete',action,bytes,revision),
 cancelImage:()=>ipcRenderer.invoke('test:cancel'),
 onImageChanged:fn=>{const handler=(_event,value)=>fn(value);ipcRenderer.on('test:changed',handler);return()=>ipcRenderer.removeListener('test:changed',handler);},
});
