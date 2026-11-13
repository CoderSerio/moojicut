import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
export function dataDirectory() {
  if (process.env.MOONCAP_HOME) return path.resolve(process.env.MOONCAP_HOME);
  if (process.platform === 'darwin') return path.join(os.homedir(), 'Library', 'Application Support', 'mooncap');
  if (process.platform === 'win32') return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'mooncap');
  return path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'mooncap');
}

export async function request(method, params = {}, { directory = path.join(dataDirectory(), 'agent'), timeout = 60_000 } = {}) {
  const { port, token } = JSON.parse(await fs.readFile(path.join(directory, 'connection.json'), 'utf8'));
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !/^[a-f0-9]{64}$/.test(token)) throw new Error('Invalid Mooncap connection record.');
  const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ method, params }), signal: AbortSignal.timeout(timeout),
  });
  const value = await response.json();
  if (!response.ok) throw Object.assign(new Error(value.error?.message || 'Mooncap tool failed.'), {
    code: value.error?.code, details: value.error?.details, applicationError: true,
  });
  return value.result;
}

async function start() {
  if (process.env.MOONCAP_AUTOSTART === '0') throw new Error('Mooncap 尚未运行，请先启动桌面应用。');
  let executable;
  let args;
  if (process.env.MOONCAP_EXECUTABLE) { executable = path.resolve(process.env.MOONCAP_EXECUTABLE); args = []; }
  else {
    const bundled = process.platform === 'darwin'
      ? path.join(root, 'release', `Mooncap-darwin-${process.arch}`, 'Mooncap.app', 'Contents', 'MacOS', 'Mooncap')
      : path.join(root, 'release', `Mooncap-${process.platform}-${process.arch}`, process.platform === 'win32' ? 'Mooncap.exe' : 'Mooncap');
    try { await fs.access(bundled); executable = bundled; args = []; }
    catch { executable = (await import('electron')).default; args = [root]; }
  }
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  const child = spawn(executable, args, { detached: true, stdio: 'ignore', env });
  let spawnError;
  child.on('error', (failure) => { spawnError = failure; });
  child.unref();
  for (let attempt = 0; attempt < 80; attempt += 1) {
    if (spawnError) throw spawnError;
    await new Promise((resolve) => setTimeout(resolve, 200));
    try { await request('status', {}, { timeout: 1000 }); return; }
    catch (failure) { if (failure.applicationError) throw failure; }
  }
  throw new Error('Mooncap 启动超时，请手动启动应用后重试。');
}

let launching;
export async function rpc(method, params = {}) {
  try { return await request(method, params); }
  catch (failure) {
    // Retry only when a request could not reach any app. A timed-out mutation is never replayed.
    if (failure.applicationError || !(failure.code === 'ENOENT' || failure.cause?.code === 'ECONNREFUSED')) throw failure;
    launching ??= start().finally(() => { launching = undefined; });
    await launching;
    return request(method, params);
  }
}
