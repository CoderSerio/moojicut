const started = Date.now();
const elapsed = document.querySelector('#elapsed');
setInterval(() => {
  const seconds = Math.floor((Date.now() - started) / 1000);
  elapsed.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}, 1000);
document.querySelector('#stop').addEventListener('click', () => {
  window.mooncap.requestStop();
  document.querySelector('#stop').textContent = 'Saving…';
});
