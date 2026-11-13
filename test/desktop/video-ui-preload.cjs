const {contextBridge}=require('electron');
contextBridge.exposeInMainWorld('mooncap',{
  getRecording:()=>require('electron').ipcRenderer.invoke('fixture:recording'),
  loadVideoDraft:async()=>null,
  saveVideoDraft:async(id,document)=>({ok:true}),
  exportVideo:async(id,plan)=>({path:'/tmp/test.mp4',copied:false}),
  cancelExport:async()=>{},retryCopyVideo:async()=>({copied:false}),onExportProgress:()=>()=>{},showInFolder:async()=>{},copyPath:async()=>{},
});
