import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { deflateSync } from 'node:zlib';
import { ImageStore } from '../src/main/image-store.mjs';

function png(width, height) {
  const chunk = (name, bytes) => {
    const payload = Buffer.concat([Buffer.from(name), bytes]);
    let crc = 0xffffffff;
    for (const value of payload) { crc ^= value; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); }
    const output = Buffer.alloc(bytes.length + 12);
    output.writeUInt32BE(bytes.length); payload.copy(output, 4); output.writeUInt32BE((crc ^ 0xffffffff) >>> 0, bytes.length + 8);
    return output;
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header), chunk('IDAT', deflateSync(Buffer.alloc((width * 4 + 1) * height))), chunk('IEND', Buffer.alloc(0))]);
}
async function fixture(t, options = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mooncap-image-store-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ImageStore(directory, { cropPng: (_bytes, rect) => png(rect.width, rect.height), ...options });
  await store.initialize();
  return { store, directory };
}
const rect = (id, x = 20) => ({ id, type: 'rect', x, y: 12, width: 20, height: 15, color: '#ff0000', stroke: 3, opacity: 1 });

test('unconfirmed screenshot stays in memory and cancel does not create history', async (t) => {
  const { store, directory } = await fixture(t);
  const item = await store.create({ png: png(80, 60), viewport: null, mode: 'overlay' });
  assert.equal(item.document.viewport, null);
  assert.equal(store.list().length, 0);
  assert.deepEqual(await readdir(directory), []);
  await assert.rejects(store.complete(item.id), /选择截图区域/);
  await store.cancel(item.id);
  assert.throws(() => store.get(item.id), /找不到/);
  assert.deepEqual(await readdir(directory), []);
});

test('confirmation crops the source, rebases editable annotations, and survives restart', async (t) => {
  const changes = [];
  const { store, directory } = await fixture(t, { onChange: (value) => changes.push(value) });
  let item = await store.create({ png: png(80, 60), viewport: { x: 10, y: 5, width: 50, height: 40 } });
  item = await store.apply(item.id, { type: 'add', annotations: [rect('box')] }, item.revision);
  assert.equal(changes.at(-1).imageUrl, undefined, 'ordinary edits must not resend the base image');
  const completed = await store.complete(item.id, { expectedRevision: item.revision });
  assert.equal(completed.completed, true);
  assert.equal(completed.width, 50);
  assert.equal(completed.height, 40);
  assert.deepEqual(completed.document.viewport, { x: 0, y: 0, width: 50, height: 40 });
  assert.equal(completed.document.annotations[0].x, 10);
  assert.equal(completed.document.annotations[0].y, 7);
  assert.deepEqual(completed.document.undo, []);
  assert.ok(changes.at(-1).imageUrl);
  const revived = new ImageStore(directory);
  await revived.initialize();
  assert.equal(revived.list().length, 1);
  const current = revived.get(item.id);
  assert.deepEqual(current.document, completed.document);
  await revived.apply(item.id, { type: 'move', id: 'box', dx: 4, dy: 2 }, current.revision);
  const third = new ImageStore(directory);
  await third.initialize();
  assert.equal(third.get(item.id).document.annotations[0].x, 14);
  assert.equal(third.get(item.id).document.undo.length, 0);
});

test('concurrent human and agent edits serialize and reject stale revisions without losing changes', async (t) => {
  const { store } = await fixture(t);
  const item = await store.create({ png: png(80, 60) });
  const outcomes = await Promise.allSettled([
    store.apply(item.id, { type: 'add', annotations: [rect('human')] }, 0),
    store.apply(item.id, { type: 'add', annotations: [rect('agent')] }, 0),
  ]);
  assert.equal(outcomes[0].status, 'fulfilled');
  assert.equal(outcomes[1].status, 'rejected');
  assert.equal(outcomes[1].reason.code, 'revision_conflict');
  assert.equal(outcomes[1].reason.details.revision, 1);
  assert.deepEqual(store.get(item.id).document.annotations.map((a) => a.id), ['human']);
  await store.apply(item.id, { type: 'add', annotations: [rect('agent')] }, 1);
  await assert.rejects(store.complete(item.id, { expectedRevision: 1 }), { code: 'revision_conflict' });
  assert.equal(store.get(item.id).completed, false);
});

test('failed source crop leaves the full editable session untouched', async (t) => {
  const { store, directory } = await fixture(t, { cropPng: () => { throw new Error('decoder failed'); } });
  const item = await store.create({ png: png(80, 60), viewport: { x: 10, y: 5, width: 50, height: 40 } });
  await assert.rejects(store.complete(item.id), /decoder failed/);
  assert.deepEqual(store.get(item.id).document, item.document);
  assert.equal(store.get(item.id).completed, false);
  assert.deepEqual(await readdir(directory), []);
});

test('completed metadata is immutable to callers and corrupt records are preserved but not loaded', async (t) => {
  const { store, directory } = await fixture(t);
  const item = await store.create({ png: png(80, 60) });
  await store.complete(item.id);
  const read = store.get(item.id); read.document.width = 4;
  assert.equal(store.get(item.id).document.width, 80);
  const metadataPath = path.join(directory, item.id, 'capture.json');
  const metadata = JSON.parse(await readFile(metadataPath));
  metadata.sourceFile = '../outside.png';
  await writeFile(metadataPath, JSON.stringify(metadata));
  const revived = new ImageStore(directory); await revived.initialize();
  assert.equal(revived.list().length, 0);
  assert.ok((await readFile(metadataPath)).length);
});

test('closed history releases image bytes and undo state while reopening preserves pixels and edits', async (t) => {
  const { store, directory } = await fixture(t);
  const pixels = png(80, 60);
  const item = await store.create({ png: pixels });
  await store.complete(item.id);
  assert.equal(store.record(item.id).png, undefined, 'completed sources must not stay resident');
  assert.equal(await store.record(item.id).tail, undefined, 'the queue must not retain a result containing imageUrl');
  const edited = await store.apply(item.id, { type: 'add', annotations: [rect('box')] });
  assert.equal(edited.document.undo.length, 1);
  await store.release(item.id);
  const reopened = store.get(item.id);
  assert.deepEqual(Buffer.from(reopened.imageUrl.split(',')[1], 'base64'), pixels);
  assert.deepEqual(reopened.document.undo, []);
  assert.equal(reopened.document.revision, edited.revision);
  assert.equal(reopened.document.annotations[0].id, 'box');
  assert.equal(store.record(item.id).png, undefined, 'reopening must not cache source bytes in the store');
  const restored = new ImageStore(directory);
  await restored.initialize();
  assert.equal(restored.record(item.id).png, undefined, 'startup must keep history source pixels on disk');
  assert.deepEqual(restored.readPng(item.id), pixels);
  assert.equal(restored.get(item.id, { image: false }).document.annotations[0].id, 'box');
});
