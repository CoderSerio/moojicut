import { loadSource, renderDocument } from './image-render.mjs';

const api=window.mooncap,img=document.getElementById('image');
let id,documentState,sourceUrl,sourcePromise,version=0,closed=false;
function showError(error){img.title=error.message||String(error);}
async function update(value){
  if(closed||!value||value.id!==id||!value.document)return;
  if(documentState&&value.document.revision<documentState.revision)return;
  documentState=value.document;
  if(value.imageUrl&&value.imageUrl!==sourceUrl){sourceUrl=value.imageUrl;sourcePromise=loadSource(sourceUrl);}
  if(!sourcePromise)return;
  const current=++version,document=documentState;
  try{
    const source=await sourcePromise;
    if(closed||current!==version)return;
    const canvas=renderDocument(document,source);
    img.src=canvas.toDataURL('image/png');img.title='';img.dataset.revision=String(document.revision);
  }catch(error){if(current===version)showError(error);}
}
const pending=[];
const unsubscribe=api.onImageChanged(value=>{if(id)void update(value);else pending.push(value);});
window.mooncapPinReady=(async()=>{
  const initial=await api.getPin();id=initial.id;
  if(initial.imageUrl)img.src=initial.imageUrl;
  if(initial.session)await update(initial.session);
  for(const value of pending)await update(value);pending.length=0;
})();
window.mooncapPinReady.catch(showError);
for(const button of document.querySelectorAll('button'))button.addEventListener('click',()=>{
  button.disabled=true;
  Promise.resolve(api.pinAction(button.dataset.action)).catch(showError).finally(()=>{button.disabled=false;});
});
addEventListener('beforeunload',()=>{closed=true;version++;unsubscribe?.();});
