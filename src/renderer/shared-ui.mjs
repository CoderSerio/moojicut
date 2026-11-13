export const $ = (id) => document.getElementById(id);
export const number = (id) => Number($(id).value);
export const checked = (id) => $(id).checked;

export function notice(message, error = false) {
  $('notice').textContent = message;
  $('notice').classList.toggle('error', error);
  $('notice').hidden = !message;
}

export function view(name) {
  for (const section of ['capture', 'recording', 'image', 'video']) {
    $(`${section}-view`).hidden = section !== name;
  }
  $('home').hidden = name === 'capture' || name === 'recording';
}

export function action(id, fn) {
  $(id).addEventListener('click', async () => {
    const button = $(id);
    button.disabled = true;
    try { await fn(); } catch (error) { notice(error.message, true); }
    finally { button.disabled = false; }
  });
}

export function formatTime(ms) {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
}
