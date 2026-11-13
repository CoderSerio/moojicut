import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, stat, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createAgentServer } from '../src/main/agent-server.mjs';
import { request } from '../agent/client.mjs';

async function fixture(t, handlers) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mooncap-agent-'));
  const server = await createAgentServer({ directory, handlers });
  t.after(async () => { await server.dispose(); await rm(directory, { force: true, recursive: true }); });
  return { directory, server };
}

test('local tools require bearer authentication, reject browser origins, and preserve structured conflicts', async (t) => {
  let calls = 0;
  const { directory, server } = await fixture(t, {
    status: () => ({ activeCaptureId: null }),
    annotate: () => { calls += 1; throw Object.assign(new Error('changed'), { code: 'revision_conflict', details: { revision: 4 } }); },
  });
  const base = { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ method: 'status' }) };
  const url = `http://127.0.0.1:${server.port}/rpc`;
  assert.equal((await fetch(url, base)).status, 401);
  assert.equal((await fetch(url, { ...base, headers: { ...base.headers, Authorization: `Bearer ${server.token}`, Origin: 'null' } })).status, 403);
  assert.deepEqual(await request('status', {}, { directory }), { activeCaptureId: null });
  await assert.rejects(request('annotate', {}, { directory }), (failure) => failure.code === 'revision_conflict' && failure.details.revision === 4);
  assert.equal(calls, 1, 'a failed mutation must never be automatically replayed');
  await assert.rejects(request('toString', {}, { directory }), { code: 'unknown_method' });
  if (process.platform !== 'win32') {
    assert.equal((await stat(directory)).mode & 0o777, 0o700);
    assert.equal((await stat(server.connectionPath)).mode & 0o777, 0o600);
  }
});

test('invalid request shapes do not reach handlers and disposal does not delete a newer connection', async (t) => {
  let calls = 0;
  const { directory, server } = await fixture(t, { status: () => { calls += 1; return {}; } });
  const url = `http://127.0.0.1:${server.port}/rpc`;
  const headers = { Authorization: `Bearer ${server.token}`, 'Content-Type': 'application/json' };
  assert.equal((await fetch(url, { method: 'POST', headers, body: '{' })).status, 400);
  assert.equal((await fetch(url, { method: 'POST', headers, body: JSON.stringify({ method: 'status', params: [] }) })).status, 400);
  assert.equal(calls, 0);
  await writeFile(server.connectionPath, JSON.stringify({ token: 'new-owner' }));
  await server.dispose();
  assert.equal(JSON.parse(await readFile(path.join(directory, 'connection.json'))).token, 'new-owner');
});
