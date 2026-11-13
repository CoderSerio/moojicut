const started = Date.now();
setInterval(() => { const seconds = Math.floor((Date.now() - started) / 1000); document.querySelector('#elapsed').textContent = `${String(Math.floor(seconds / 60)).padStart(2,'0')}:${String(seconds % 60).padStart(2,'0')}`; }, 1000);
document.querySelector('#stop').onclick = () => { document.querySelector('#stop').disabled = true; document.querySelector('#stop').textContent = '正在完成…'; window.mooncap.requestStop(); };
