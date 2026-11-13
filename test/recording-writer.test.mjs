import test from 'node:test';
import assert from 'node:assert/strict';
import { appendBlobInChunks } from '../src/renderer/recording-writer.mjs';

test('large MediaRecorder blobs are delivered in order within the IPC limit', async () => {
  const bytes = new Uint8Array(17 * 1024 * 1024 + 3);
  bytes[0] = 7;
  bytes[16 * 1024 * 1024] = 31;
  bytes[bytes.length - 1] = 255;
  const chunks = [];
  let pending = false;
  await appendBlobInChunks(new Blob([bytes]), async (chunk) => {
    assert.equal(pending, false);
    pending = true;
    await Promise.resolve();
    assert.ok(chunk.byteLength <= 16 * 1024 * 1024);
    chunks.push(chunk);
    pending = false;
  });
  assert.equal(chunks.length, 2);
  assert.deepEqual(Buffer.concat(chunks), Buffer.from(bytes));
});

test('a failed write stops delivery of later blob slices', async () => {
  let writes = 0;
  await assert.rejects(appendBlobInChunks(new Blob([new Uint8Array(17 * 1024 * 1024)]), async () => {
    writes += 1;
    throw new Error('disk full');
  }), /disk full/);
  assert.equal(writes, 1);
});
