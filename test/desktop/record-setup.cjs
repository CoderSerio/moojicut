// Run with: electron test/desktop/record-setup.cjs
// Real preparation page + mocked capture service; no desktop/audio acquisition.
const { app, BrowserWindow, ipcMain } = require('electron');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const temp = require('node:fs').mkdtempSync(path.join(os.tmpdir(), 'mooncap-setup-smoke-'));
app.setPath('userData', path.join(temp, 'profile'));
const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900"><rect width="1600" height="900" fill="#e5ebf4"/><rect x="70" y="70" width="1460" height="120" rx="18" fill="#a8bed8"/><text x="120" y="145" font-family="sans-serif" font-size="44" fill="#17334f">Mooncap · Generated test desktop</text><path d="M70 300H1530M70 440H1530M70 580H1530M70 720H1530" stroke="#a8bed8" stroke-width="3"/></svg>';
const config = { sourceId: 'synthetic-source', sourceWidth: 1600, sourceHeight: 900, imageUrl: `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`, microphone: false, systemAudio: false };
const calls = { preview: [], prepare: [], reset: 0, start: 0, cancel: 0 };
const errors = [];
let win, pending, systemAudio = true;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const js = code => win.webContents.executeJavaScript(code);
async function until(fn, description, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (await fn()) return; await delay(25); }
  throw new Error(`Timed out: ${description}`);
}
async function ready() { await until(() => js('document.getElementById("selection").width===1600 && document.getElementById("region-label").hidden'), 'preparation page initialized'); }
async function drag(x, y, endX, endY) {
  win.webContents.sendInputEvent({ type: 'mouseDown', x, y, button: 'left', clickCount: 1 });
  win.webContents.sendInputEvent({ type: 'mouseMove', x: endX, y: endY, button: 'left' });
  win.webContents.sendInputEvent({ type: 'mouseUp', x: endX, y: endY, button: 'left', clickCount: 1 });
  await until(() => js('!document.getElementById("region-label").hidden'), 'dragged selection');
}
ipcMain.handle('setup:get', () => config);
ipcMain.handle('setup:environment', () => ({ systemAudio }));
ipcMain.handle('setup:preview-microphone', (event, enabled, deviceId) => {
  calls.preview.push({ enabled, deviceId });
  if (enabled) event.sender.send('setup:microphone-info', { devices: [{ id: 'builtin', label: '测试内置麦克风' }, { id: 'usb', label: '测试 USB 麦克风' }], level: 0.42 });
  return { ready: true };
});
ipcMain.handle('setup:prepare', (_event, options) => {
  calls.prepare.push(options);
  return new Promise((resolve, reject) => { pending = { resolve, reject }; });
});
ipcMain.handle('setup:reset', () => { calls.reset++; pending?.resolve({ canceled: true }); pending = undefined; return { reset: true }; });
ipcMain.handle('setup:start', () => { calls.start++; return { started: true }; });
ipcMain.handle('setup:cancel', () => { calls.cancel++; pending?.resolve({ canceled: true }); pending = undefined; return { canceled: true }; });

async function run() {
  await app.whenReady();
  win = new BrowserWindow({ width: 1100, height: 760, show: false, webPreferences: { preload: path.join(__dirname, 'record-setup-preload.cjs'), sandbox: true, contextIsolation: true, backgroundThrottling: false } });
  win.webContents.on('console-message', event => { if (event.level === 'error') errors.push(event.message); });
  await win.loadFile(path.join(root, 'src/renderer/record-setup.html'));
  await ready();
  assert.equal(await js('document.getElementById("start").disabled'), true);
  assert.deepEqual(await js('({checked:document.getElementById("cursor").checked,disabled:document.getElementById("cursor").disabled,title:document.getElementById("cursor").parentElement.title})'), { checked: true, disabled: true, title: '当前采集宿主固定包含光标' });
  await js('document.getElementById("full-screen").click()');
  assert.equal(await js('document.getElementById("region-label").textContent'), '1600 × 900 px');
  assert.equal(await js('document.getElementById("start").disabled'), false);
  await drag(60, 70, 500, 260);
  const selectedLabel = await js('document.getElementById("region-label").textContent');
  assert.notEqual(selectedLabel, '1600 × 900 px');
  const viewport = await js('({width:innerWidth,height:innerHeight})');
  const x = Math.round(60 * 1600 / viewport.width), y = Math.round(70 * 900 / viewport.height);
  const selected = { x, y, width: Math.round(500 * 1600 / viewport.width) - x, height: Math.round(260 * 900 / viewport.height) - y };
  await js('document.getElementById("microphone").click();document.getElementById("system-audio").click()');
  await until(() => js('document.getElementById("microphone-device").options.length===3'), 'microphone device list');
  await js('document.getElementById("microphone-device").value="usb";document.getElementById("microphone-device").dispatchEvent(new Event("change"))');
  await until(() => calls.preview.some(value => value.deviceId === 'usb'), 'selected microphone preview');
  assert.equal(await js('document.getElementById("microphone-level").value'), 0.42);
  await js('document.getElementById("start").click()');
  await until(() => pending, 'media preparation requested');
  assert.deepEqual(calls.prepare[0], { region: selected, microphone: true, microphoneId: 'usb', systemAudio: true, cursor: true });
  assert.equal(await js('document.getElementById("countdown").hidden'), true, 'Countdown waits for permission/device preparation');
  pending.resolve({ prepared: true }); pending = undefined;
  await until(() => js('!document.getElementById("countdown").hidden && document.getElementById("countdown").textContent === "3"'), 'countdown after preparation');
  await js('document.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))');
  await until(() => calls.reset === 1, 'Escape resets preparation');
  await until(() => js('!document.getElementById("record-panel").hidden && document.getElementById("countdown").hidden'), 'preparation controls restored');
  assert.equal(await js('document.getElementById("region-label").textContent'), selectedLabel);
  assert.deepEqual(await js('({microphone:document.getElementById("microphone").checked,systemAudio:document.getElementById("system-audio").checked,device:document.getElementById("microphone-device").value,cursorDisabled:document.getElementById("cursor").disabled})'), { microphone: true, systemAudio: true, device: 'usb', cursorDisabled: true });
  await delay(1100);
  assert.equal(calls.start, 0, 'Canceled countdown must not begin recording later');
  const output = path.resolve(process.env.MOONCAP_SETUP_SMOKE_OUTPUT || path.join(root, '.artifacts/record-setup-smoke.png'));
  await fs.mkdir(path.dirname(output), { recursive: true });
  win.showInactive();
  await js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  await fs.writeFile(output, (await win.webContents.capturePage()).toPNG());
  win.hide();
  await js('document.getElementById("start").click()');
  await until(() => pending, 'second preparation');
  assert.deepEqual(calls.prepare[1], calls.prepare[0]);
  pending.resolve({ prepared: true }); pending = undefined;
  await until(() => calls.start === 1, 'second countdown starts prepared stream', 5000);
  assert.equal(calls.cancel, 0);

  systemAudio = false;
  await win.loadFile(path.join(root, 'src/renderer/record-setup.html'));
  await ready();
  assert.equal(await js('document.getElementById("system-audio").disabled'), true);
  await js('document.getElementById("full-screen").click();document.getElementById("start").click()');
  await until(() => pending, 'failing preparation');
  pending.reject(new Error('测试：未获得麦克风权限')); pending = undefined;
  await until(() => js('document.getElementById("status").textContent.includes("未获得麦克风权限")'), 'permission failure shown');
  assert.deepEqual(await js('({start:document.getElementById("start").disabled,cursor:document.getElementById("cursor").disabled,systemAudio:document.getElementById("system-audio").disabled,countdown:document.getElementById("countdown").hidden})'), { start: false, cursor: true, systemAudio: true, countdown: true });
  await js('document.getElementById("cancel").click()');
  await until(() => calls.cancel === 1, 'cancel preparation');
  assert.deepEqual(errors, []);
  process.stdout.write(JSON.stringify({ electron: process.versions.electron, result: 'PASS full-screen/region; microphone devices+activity; preparation-before-countdown; Escape retains selection/settings and cancels timer; restart; permission failure; cancel', screenshot: output, preparations: calls.prepare.length, starts: calls.start, resets: calls.reset, cancels: calls.cancel }) + '\n');
  win.destroy(); await fs.rm(temp, { recursive: true, force: true }); app.exit(0);
}
const timeout = setTimeout(() => { process.stderr.write('Preparation smoke timed out\n'); app.exit(2); }, 30000);
run().catch(error => { process.stderr.write(error.stack + '\n' + JSON.stringify({ calls, errors }) + '\n'); app.exit(1); }).finally(() => clearTimeout(timeout));
