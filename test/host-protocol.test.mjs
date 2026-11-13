import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createMediaHandler } from '../src/main/media-protocol.mjs';

test('recording protocol supports video byte ranges and rejects unknown or incomplete assets', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mooncap-protocol-'));
  try {
    const filename = path.join(directory, 'recording.webm');
    await writeFile(filename, '0123456789');
    const record = { filename, state: 'complete', mimeType: 'video/webm' };
    const handle = createMediaHandler({ get(id) { if (id !== 'known') throw new Error('Unknown'); return record; } });
    const url = 'mooncap-media://recording/known';
    const whole = await handle(new Request(url));
    assert.equal(whole.status, 200);
    assert.equal(await whole.text(), '0123456789');
    const range = await handle(new Request(url, { headers: { Range: 'bytes=2-5' } }));
    assert.equal(range.status, 206);
    assert.equal(range.headers.get('Content-Range'), 'bytes 2-5/10');
    assert.equal(range.headers.get('Content-Length'), '4');
    assert.equal(await range.text(), '2345');
    const suffix = await handle(new Request(url, { headers: { Range: 'bytes=-3' } }));
    assert.equal(await suffix.text(), '789');
    const head = await handle(new Request(url, { method: 'HEAD' }));
    assert.equal(head.headers.get('Content-Length'), '10');
    assert.equal(await head.text(), '');
    for (const range of ['bytes=10-', 'bytes=8-3', 'bytes=-0', 'bytes=', 'bytes=0-1,4-5']) {
      const result = await handle(new Request(url, { headers: { Range: range } }));
      assert.equal(result.status, 416, range);
      assert.equal(result.headers.get('Content-Range'), 'bytes */10');
    }
    assert.equal((await handle(new Request('mooncap-media://recording/unknown'))).status, 404);
    assert.equal((await handle(new Request('mooncap-media://another-host/known'))).status, 404);
    assert.equal((await handle(new Request(url, { method: 'POST' }))).status, 404);
    record.state = 'recording';
    assert.equal((await handle(new Request(url))).status, 404);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
