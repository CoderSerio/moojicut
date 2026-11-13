import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { createAgentServer, AGENT_METHODS } from '../src/main/agent-server.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const sampleImage = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==';
test('STDIO MCP discovers all tools and returns metadata with rendered PNG without requiring the GUI', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mooncap-mcp-'));
  const id = 'b0123456-1111-4111-8111-012345678901';
  const server = await createAgentServer({ directory: path.join(directory, 'agent'), handlers: {
    status: () => ({ activeCaptureId: id, revision: 2 }),
    get_capture: () => ({ id, document: { revision: 2 }, imageUrl: 'large source omitted' }),
    preview: () => ({ id, image: sampleImage }),
    annotate: () => { throw Object.assign(new Error('Changed by human'), { code: 'revision_conflict', details: { revision: 3 } }); },
  } });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(root, 'agent/mcp.mjs')],
    env: { ...process.env, MOONCAP_HOME: directory, MOONCAP_AUTOSTART: '0' }, stderr: 'pipe' });
  const client = new Client({ name: 'mooncap-test', version: '1.0' });
  t.after(async () => { await client.close(); await server.dispose(); await rm(directory, { force: true, recursive: true }); });
  await client.connect(transport);
  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map((tool) => tool.name).sort(), [...AGENT_METHODS].sort());
  const status = await client.callTool({ name: 'status', arguments: {} });
  assert.equal(JSON.parse(status.content[0].text).activeCaptureId, id);
  const capture = await client.callTool({ name: 'get_capture', arguments: { captureId: id } });
  assert.equal(capture.content.length, 2);
  assert.equal(capture.content[1].type, 'image');
  assert.equal(capture.content[1].mimeType, 'image/png');
  assert.equal(JSON.parse(capture.content[0].text).imageUrl, undefined);
  const conflict = await client.callTool({ name: 'annotate', arguments: { captureId: id, expectedRevision: 2, action: 'remove', ids: ['shape'] } });
  assert.equal(conflict.isError, true);
  assert.equal(JSON.parse(conflict.content[0].text).details.revision, 3);
});
