import http from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir, chmod, writeFile, rename, readFile, rm } from 'node:fs/promises';
import path from 'node:path';

export const AGENT_METHODS = Object.freeze(['status', 'list_windows', 'capture', 'import_image', 'list_captures',
  'get_capture', 'annotate', 'crop', 'undo', 'redo', 'preview', 'export', 'present', 'pin', 'copy']);
const MAX_REQUEST_BYTES = 8 * 1024 * 1024;

export async function createAgentServer({ directory, handlers }) {
  const token = randomBytes(32).toString('hex');
  const expectedAuthorization = Buffer.from(`Bearer ${token}`);
  const connectionPath = path.join(directory, 'connection.json');
  const dispatch = async (method, params = {}) => {
    if (!AGENT_METHODS.includes(method) || !Object.hasOwn(handlers, method) || typeof handlers[method] !== 'function') {
      throw Object.assign(new Error('Unknown or unavailable tool.'), { code: 'unknown_method' });
    }
    if (!params || typeof params !== 'object' || Array.isArray(params)) throw Object.assign(new Error('Parameters must be an object.'), { code: 'invalid_params' });
    return handlers[method](params);
  };
  const server = http.createServer(async (request, response) => {
    const send = (status, body) => {
      if (response.destroyed) return;
      response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
      response.end(JSON.stringify(body));
    };
    if (request.headers.origin !== undefined || request.headers['sec-fetch-site'] === 'cross-site') return send(403, { error: { code: 'forbidden_origin', message: 'Browser requests are not accepted.' } });
    const host = request.headers.host;
    if (host !== `127.0.0.1:${server.address().port}`) return send(403, { error: { code: 'forbidden_host', message: 'Only the loopback address is accepted.' } });
    const supplied = Buffer.from(request.headers.authorization || '');
    if (supplied.length !== expectedAuthorization.length || !timingSafeEqual(supplied, expectedAuthorization)) return send(401, { error: { code: 'unauthorized', message: 'Local tool authentication failed.' } });
    if (request.method !== 'POST' || request.url !== '/rpc') return send(404, { error: { code: 'not_found', message: 'Use POST /rpc.' } });
    if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] || '')) return send(415, { error: { code: 'invalid_content_type', message: 'JSON content is required.' } });
    if (Number(request.headers['content-length']) > MAX_REQUEST_BYTES) return send(413, { error: { code: 'request_too_large', message: 'Tool request is too large.' } });
    try {
      const chunks = [];
      let size = 0;
      for await (const chunk of request) {
        size += chunk.length;
        if (size > MAX_REQUEST_BYTES) return send(413, { error: { code: 'request_too_large', message: 'Tool request is too large.' } });
        chunks.push(chunk);
      }
      let message;
      try { message = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { return send(400, { error: { code: 'invalid_json', message: 'Invalid JSON request.' } }); }
      if (!message || typeof message !== 'object' || Array.isArray(message)) return send(400, { error: { code: 'invalid_request', message: 'Expected a tool request object.' } });
      send(200, { result: await dispatch(message.method, message.params ?? {}) });
    } catch (failure) {
      send(failure.code === 'revision_conflict' ? 409 : 400, { error: { message: failure.message || 'Tool failed.',
        code: failure.code || 'tool_error', ...(failure.details ? { details: failure.details } : {}) } });
    }
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 1000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  try {
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await chmod(directory, 0o700);
    const temporary = path.join(directory, `.connection-${token.slice(0, 16)}.tmp`);
    await writeFile(temporary, JSON.stringify({ port, token, pid: process.pid, version: 1 }), { mode: 0o600, flag: 'wx' });
    await rename(temporary, connectionPath);
  } catch (failure) {
    await new Promise((resolve) => server.close(resolve));
    throw failure;
  }
  let disposing;
  const dispose = () => disposing ??= (async () => {
    server.closeIdleConnections();
    await new Promise((resolve) => server.close(resolve));
    try {
      const current = JSON.parse(await readFile(connectionPath, 'utf8'));
      if (current.token === token) await rm(connectionPath, { force: true });
    } catch { /* Another process may have replaced or removed the connection record. */ }
  })();
  return { port, token, connectionPath, dispatch, dispose };
}
