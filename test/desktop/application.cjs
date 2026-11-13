// Build first, then run: electron test/desktop/application.cjs
// Exercises the real host, application services, preload and IPC. Fixtures are
// generated locally. Screen acquisition and clipboard writes are forbidden.
const { app, BrowserWindow, clipboard, desktopCapturer, dialog, protocol } = require('electron');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { pathToFileURL } = require('node:url');

const root = path.resolve(__dirname, '../..');
const temp = require('node:fs').realpathSync(require('node:fs').mkdtempSync(path.join(os.tmpdir(), 'mooncap-application-smoke-')));
const output = path.resolve(process.env.MOONCAP_SMOKE_OUTPUT_DIR || path.join(root, '.artifacts/application-smoke'));
const profile = path.join(temp, 'profile');
const checks = [], rendererErrors = [], screenshots = [];
const saveChoices = [], openChoices = [];
const hideOnShow = new WeakMap();
let desktop, saveCalls = 0, openCalls = 0;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const load = file => import(pathToFileURL(path.join(root, file)).href);
const js = (win, code) => win.webContents.executeJavaScript(code);

app.setName('Mooncap integration smoke');
app.setPath('userData', profile);
protocol.registerSchemesAsPrivileged([{ scheme: 'mooncap-media', privileges: { standard: true, secure: true, stream: true, supportFetchAPI: true } }]);
app.on('window-all-closed', () => {});
app.on('browser-window-created', (_event, win) => {
  // Exercise the actual window factory without taking focus from the user.
  const hide = () => win.hide();
  hideOnShow.set(win, hide); win.on('show', hide);
  win.webContents.on('console-message', (_event, details) => {
    if (details.level === 'error') rendererErrors.push(details.message);
  });
  win.webContents.on('render-process-gone', (_event, details) => rendererErrors.push(`renderer exited: ${details.reason}`));
});
desktopCapturer.getSources = async () => { throw new Error('This smoke must never acquire the user desktop.'); };
for (const name of ['write', 'writeText', 'writeImage', 'writeBuffer', 'writeHTML', 'writeRTF', 'writeBookmark', 'clear']) {
  if (typeof clipboard[name] === 'function') clipboard[name] = () => { throw new Error(`This smoke must never mutate the clipboard (${name}).`); };
}
dialog.showSaveDialog = async () => {
  saveCalls++;
  assert.ok(saveChoices.length, 'Unexpected save dialog');
  return saveChoices.shift();
};
dialog.showOpenDialog = async () => {
  openCalls++;
  assert.ok(openChoices.length, 'Unexpected import dialog');
  return openChoices.shift();
};
dialog.showMessageBox = async () => { throw new Error('Unexpected confirmation dialog'); };
dialog.showErrorBox = (title, message) => { rendererErrors.push(`${title}: ${message}`); };

async function until(predicate, label, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await delay(25);
  }
  throw new Error(`Timed out: ${label}`);
}
async function ready(win, expression, label) {
  await until(async () => !win.isDestroyed() && !win.webContents.isLoading() && await js(win, `Boolean(${expression})`), label);
}
function item(role, id) {
  return [...desktop.windows.values()].find(value => value.role === role && (id === undefined || value.data.id === id));
}
async function screenshot(win, name) {
  const filename = path.join(output, `${name}.png`);
  // Hidden Chromium renderers can retain an older composited frame even though
  // DOM state is current. Briefly paint without focusing before capturePage.
  const hide = hideOnShow.get(win);
  if (hide) win.removeListener('show', hide);
  try {
    win.showInactive();
    await js(win, 'new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
    await fs.writeFile(filename, (await win.webContents.capturePage()).toPNG());
  } finally { win.hide(); if (hide) win.on('show', hide); }
  screenshots.push(filename);
}
function pass(name) { checks.push(name); process.stdout.write(`PASS ${name}\n`); }
async function close(win) {
  win.close();
  await until(() => win.isDestroyed(), 'window destroyed after closing');
}
async function fireClosing(win, code, label) {
  // A synchronous host close may dispose executeJavaScript's response frame.
  try { await js(win, code); }
  catch (error) { if (!win.isDestroyed() || !/frame was disposed|Object has been destroyed/i.test(error.message)) throw error; }
  await until(() => win.isDestroyed(), label);
}
async function imageReady(win) {
  await ready(win, 'window.mooncapImageReady', 'image module');
  await js(win, 'window.mooncapImageReady');
  await ready(win, 'document.querySelectorAll(".toolbar button").length >= 13', 'MoonBit image controls');
}

async function run() {
  await app.whenReady();
  await fs.mkdir(output, { recursive: true });
  const [{ RecordingStore }, { createDesktopHost }, { createApplication }, { installApplicationIpc }, { Preferences }, { createMediaHandler }, media, core] = await Promise.all([
    load('src/main/recording-store.mjs'), load('src/main/desktop-host.mjs'), load('src/main/application.mjs'),
    load('src/main/application-ipc.mjs'), load('src/main/preferences.mjs'), load('src/main/media-protocol.mjs'),
    load('src/main/media-tools.mjs'), load('dist/core/core.mjs'),
  ]);
  const ffmpeg = await media.findExecutable('ffmpeg');
  const fixtureVideo = path.join(temp, 'fixture.webm'), fixtureImage = path.join(temp, 'fixture.png');
  await media.runProcess(ffmpeg, ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '6', '-c:v', 'libvpx', '-deadline', 'realtime', '-c:a', 'libopus', fixtureVideo]);
  await media.runProcess(ffmpeg, ['-v', 'error', '-i', fixtureVideo, '-frames:v', '1', fixtureImage]);

  const preferences = new Preferences(profile);
  await preferences.initialize();
  await preferences.update({ screenshotShortcut: 'CommandOrControl+Alt+Shift+7', recordingShortcut: 'CommandOrControl+Alt+Shift+8', stopShortcut: 'CommandOrControl+Alt+Shift+9' });
  const recordings = new RecordingStore(path.join(profile, 'recordings'));
  await recordings.initialize();
  const { id: videoId } = await recordings.begin({ mimeType: 'video/webm' });
  await recordings.append(videoId, 0, await fs.readFile(fixtureVideo));
  const source = await recordings.finish(videoId);
  const state = { exporting: false, preparing: false, recordingPhase: null };
  desktop = createDesktopHost(recordings, state, preferences);
  const application = await createApplication({ directory: profile, recordings, desktop, state, preferences });
  protocol.handle('mooncap-media', createMediaHandler(recordings));
  installApplicationIpc({ application, recordings, desktop, state, preferences });
  assert.equal(BrowserWindow.getAllWindows().length, 0, 'Idle host owns no renderer windows');
  pass('idle host has zero windows');

  desktop.showLibrary('history');
  const library = item('library').window;
  await ready(library, 'document.querySelectorAll("#history .asset").length === 1', 'history rendering');
  const history = await js(library, `({text:document.querySelector('#history').textContent, disabled:document.querySelector('#history .asset button').disabled})`);
  assert.equal(history.disabled, false, 'A complete recording is editable in history');
  assert.ok(!history.text.includes('录制中断'), 'A complete recording is not mislabeled as interrupted');
  await js(library, `document.querySelector('[data-section="settings"]').click()`);
  await ready(library, 'document.querySelector("#settings input[name=screenshotShortcut]")', 'settings rendering');
  assert.equal(await js(library, 'document.querySelector("#settings input[name=screenshotShortcut]").value'), preferences.value.screenshotShortcut);
  await js(library, `document.querySelector('#settings input[name=stopShortcut]').value='CommandOrControl+Alt+Shift+0';document.querySelector('#settings form').requestSubmit()`);
  await until(() => preferences.value.stopShortcut === 'CommandOrControl+Alt+Shift+0', 'preferences IPC persistence');
  assert.equal(JSON.parse(await fs.readFile(path.join(profile, 'preferences.json'), 'utf8')).stopShortcut, preferences.value.stopShortcut);
  await screenshot(library, 'settings');
  pass('history and settings render through real authorized IPC; settings persist');

  openChoices.push({ canceled: false, filePaths: [fixtureImage] });
  const imported = await js(library, 'window.mooncap.importImage()');
  assert.equal(openCalls, 1);
  const image = item('image', imported.id).window;
  await imageReady(image);
  const modified = await js(image, `(async()=>{
    let value=await window.mooncap.getImageSession();
    value=await window.mooncap.applyImageCommand(value.id,{type:'add',annotations:[{id:'smoke-rect',type:'rect',x:80,y:70,width:160,height:90,color:'#00ffaa',stroke:6,opacity:1}]},value.document.revision);
    return window.mooncap.applyImageCommand(value.id,{type:'crop',rect:{x:40,y:30,width:400,height:250}},value.document.revision);
  })()`);
  assert.equal(modified.document.annotations.length, 1);
  assert.deepEqual(modified.document.viewport, { x: 40, y: 30, width: 400, height: 250 });
  await screenshot(image, 'image-editor');
  saveChoices.push({ canceled: true });
  const canceledImage = await js(image, `window.mooncap.completeImage(${JSON.stringify(imported.id)},'save',undefined,${modified.document.revision})`);
  assert.equal(canceledImage.canceled, true);
  assert.equal(image.isDestroyed(), false);
  assert.equal(application.images.get(imported.id).completed, false);
  const savedImage = path.join(temp, 'saved.png');
  saveChoices.push({ canceled: false, filePath: savedImage });
  await fireClosing(image, `void window.mooncapImageAction('save','')`, 'image save closes its editor');
  const png = await fs.readFile(savedImage);
  assert.equal(png.readUInt32BE(16), 400); assert.equal(png.readUInt32BE(20), 250);
  assert.equal(application.images.get(imported.id).completed, true);
  assert.equal(application.activeCaptureId, null);
  pass('image import → MoonBit edits → cancel save preserves draft → save writes cropped PNG and disposes editor');

  await application.handlers.pin({ captureId: imported.id });
  const pin = item('pin', imported.id).window;
  await ready(pin, 'window.mooncapPinReady', 'pin renderer');
  await js(pin, 'window.mooncapPinReady');
  await js(pin, `window.mooncap.pinAction('edit')`);
  const reopenedImage = item('image', imported.id).window;
  await imageReady(reopenedImage);
  const pinEdit = await js(reopenedImage, `(async()=>{const value=await window.mooncap.getImageSession();return window.mooncap.applyImageCommand(value.id,{type:'update',id:'smoke-rect',patch:{color:'#ff3366'}},value.document.revision)})()`);
  await ready(pin, `document.getElementById('image').dataset.revision === '${pinEdit.document.revision}'`, 'pin receives latest image revision');
  await screenshot(pin, 'pin');
  await fireClosing(pin, `void window.mooncap.pinAction('close')`, 'pin close IPC');
  await close(reopenedImage);
  assert.equal(application.images.get(imported.id).document.annotations[0].color, '#ff3366');
  pass('completed image reopens with editable objects; pin follows the same document revision');

  openChoices.push({ canceled: false, filePaths: [fixtureImage] });
  const discard = await js(library, 'window.mooncap.importImage()');
  const discardWindow = item('image', discard.id).window;
  await imageReady(discardWindow);
  await fireClosing(discardWindow, `void window.mooncapImageAction('cancel','')`, 'cancel discards image editor');
  assert.throws(() => application.images.get(discard.id), /找不到/);
  pass('cancel removes an unconfirmed imported image');

  await js(library, `window.mooncap.openAsset('video',${JSON.stringify(videoId)})`);
  let video = item('video', videoId).window;
  await ready(video, 'document.getElementById("confirm") && document.getElementById("source-video").readyState >= 2', 'real media protocol video playback');
  const described = await js(video, `window.mooncap.getRecording(${JSON.stringify(videoId)})`);
  assert.equal(described.state, 'complete');
  assert.equal(described.width, 640); assert.equal(described.hasAudio, true);
  await js(video, `window.__exportEvents=[];window.mooncap.onExportProgress(value=>window.__exportEvents.push(value));
    const field=(id,value)=>{const element=document.getElementById(id);element.value=value;element.dispatchEvent(new Event('change',{bubbles:true}));};
    field('cut-start','1');field('cut-end','2');document.getElementById('delete-cut').click();`);
  await ready(video, `document.getElementById('output-duration').textContent.startsWith('00:05.')`, 'first deleted interval');
  await js(video, `document.getElementById('cut-start').value='3';document.getElementById('cut-end').value='4';document.getElementById('delete-cut').click()`);
  await ready(video, `document.getElementById('output-duration').textContent.startsWith('00:04.')`, 'second deleted interval');
  await js(video, `for(const [id,value] of [['crop-x',10],['crop-y',10],['crop-width',401],['crop-height',201]])document.getElementById(id).value=value;document.getElementById('apply-crop').click()`);
  await ready(video, `document.getElementById('preview-canvas').width === 400`, 'normalized even video crop');
  await js(video, `document.getElementById('mute').checked=true;document.getElementById('mute').dispatchEvent(new Event('change',{bubbles:true}))`);
  await until(async () => (await recordings.loadDraft(videoId))?.muted, 'video draft persisted via IPC');
  const draft = await js(video, `window.mooncap.loadVideoDraft(${JSON.stringify(videoId)})`);
  assert.equal(draft.cuts.length, 2); assert.equal(draft.muted, true);
  assert.deepEqual(draft.crop, { x: 10, y: 10, width: 400, height: 200 });
  const opened = JSON.parse(core.video_open(JSON.stringify(source), JSON.stringify(draft)));
  core.video_dispose(opened.session);
  assert.equal(opened.plan.segments.length, 3);
  await screenshot(video, 'video-editor');
  pass('video source loads through media protocol; multiple cuts/crop/mute persist through draft IPC');

  const savedVideo = path.join(temp, 'saved.mp4');
  saveChoices.push({ canceled: false, filePath: savedVideo });
  await js(video, `document.getElementById('save-as').click()`);
  await until(async () => !state.exporting && application.allowedOutputs.has(savedVideo), 'real MP4 export completion', 30000);
  await ready(video, `window.__exportEvents.some(value=>value.phase==='complete') && !document.getElementById('confirm').disabled`, 'video completion terminal event');
  const exported = await media.probeMedia(savedVideo, await media.findExecutable('ffprobe'));
  assert.equal(exported.width, 400); assert.equal(exported.height, 200); assert.equal(exported.hasAudio, false);
  assert.ok(Math.abs(exported.durationMs - opened.plan.outputDurationMs) < 200, 'Preview and exported duration agree');
  assert.equal((await js(video, `window.mooncap.getRecording(${JSON.stringify(videoId)})`)).lastExport.path, savedVideo);
  pass('save-as exports matching MP4 duration/crop/audio and sends terminal state');

  const previousCalls = saveCalls;
  saveChoices.push({ canceled: true });
  await js(video, `document.getElementById('save-as').click()`);
  await until(() => saveCalls > previousCalls, 'video save dialog requested');
  await ready(video, `!document.getElementById('confirm').disabled`, 'save dialog cancellation restores editor');
  assert.equal(state.exporting, false);
  assert.deepEqual(await recordings.loadDraft(videoId), draft);
  const canceledVideo = path.join(temp, 'canceled.mp4');
  saveChoices.push({ canceled: false, filePath: canceledVideo });
  await js(video, `document.getElementById('save-as').click()`);
  await until(() => state.exporting, 'export started before cancel');
  await js(video, `document.getElementById('cancel-export').click()`);
  await until(() => !state.exporting, 'canceled export settles');
  await ready(video, `window.__exportEvents.some(value=>value.phase==='canceled') && !document.getElementById('confirm').disabled`, 'export canceled terminal event');
  await assert.rejects(fs.stat(canceledVideo), { code: 'ENOENT' });
  assert.deepEqual(await recordings.loadDraft(videoId), draft);
  assert.equal((await fs.stat(recordings.get(videoId).filename)).size > 0, true);
  assert.equal((await fs.readdir(temp)).some(name => name.startsWith('.mooncap-')), false, 'Canceled export leaves no partial MP4');
  pass('dialog cancel and encoder cancel preserve source/draft, remove partial output and restore controls');

  await close(video);
  await js(library, `window.mooncap.openAsset('video',${JSON.stringify(videoId)})`);
  video = item('video', videoId).window;
  await ready(video, 'document.getElementById("source-video").readyState >= 2 && document.getElementById("preview-canvas").width === 400', 'video editor restores draft after recreation');
  assert.equal(await js(video, 'document.getElementById("mute").checked'), true);
  await close(video);
  desktop.showLibrary('history');
  await ready(library, 'document.querySelectorAll("#history .asset").length === 2', 'history contains completed image and video');
  await screenshot(library, 'history');
  await close(library);
  await until(() => desktop.windows.size === 0 && BrowserWindow.getAllWindows().length === 0, 'no hidden renderer windows remain');
  pass('close/reopen restores video draft; closing all views returns to zero renderer windows');

  // Hold only the capture-adapter readiness boundary. This reproduces a user
  // canceling while permission/device setup is pending, without screen access.
  const ensureRecorder = desktop.ensureRecorder;
  const captureConfig = { sourceId: 'synthetic-source', sourceWidth: 640, sourceHeight: 360 };
  const options = { region: { x: 0, y: 0, width: 320, height: 200 }, microphone: false, systemAudio: false, cursor: true };
  let waiting = false, releaseReady, lateMessages = 0;
  const readiness = new Promise(resolve => { releaseReady = resolve; });
  try {
    desktop.ensureRecorder = () => { waiting = true; return readiness; };
    state.preparing = true; state.captureConfig = captureConfig;
    const canceledPreparation = application.prepareRecorder(options).then(() => null, error => error);
    await until(() => waiting, 'recorder initialization is pending');
    await application.cancelRecordingPreparation();
    releaseReady({ isDestroyed: () => false, webContents: { send() { lateMessages++; } } });
    assert.ok(await canceledPreparation, 'Canceled preparation rejects its outstanding request');
    assert.equal(lateMessages, 0, 'Canceled initialization must not send to a stale recorder');
    desktop.ensureRecorder = async () => ({ isDestroyed: () => false, webContents: { send() { queueMicrotask(() => application.recorderPrepared({ region: options.region })); } } });
    state.preparing = true; state.captureConfig = captureConfig;
    assert.deepEqual(await application.prepareRecorder(options), { region: options.region }, 'A fresh preparation can begin after cancel');
    await application.cancelRecordingPreparation();
  } finally { desktop.ensureRecorder = ensureRecorder; }
  pass('cancel while recorder initializes rejects stale work and permits a fresh preparation');
  assert.equal(saveChoices.length, 0); assert.equal(openChoices.length, 0);
  assert.deepEqual(rendererErrors, [], 'No renderer exceptions');
  const report = { electron: process.versions.electron, checks, screenshots, windowCount: BrowserWindow.getAllWindows().length, clipboardMutated: false, desktopCaptured: false };
  await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  process.stdout.write(JSON.stringify(report, null, 2) + '\n');
}

const timeout = setTimeout(() => { process.stderr.write('Application smoke timed out\n'); app.exit(2); }, 120000);
run().then(async () => {
  clearTimeout(timeout); desktop?.dispose(); await fs.rm(temp, { recursive: true, force: true }); app.exit(0);
}).catch(async error => {
  clearTimeout(timeout);
  process.stderr.write(error.stack + '\n');
  process.stderr.write(JSON.stringify({ checks, rendererErrors, temp }) + '\n');
  for (const value of desktop?.windows.values() || []) {
    if (!value.window.isDestroyed()) {
      try { process.stderr.write(JSON.stringify({ role: value.role, text: await js(value.window, 'document.body.innerText') }) + '\n'); } catch {}
    }
  }
  for (const win of BrowserWindow.getAllWindows()) win.destroy();
  desktop?.dispose(); app.exit(1);
});
