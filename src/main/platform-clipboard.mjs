import { ClipboardItem, clipboard, nativeImage } from 'electron';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const execute = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const unpacked = root.replace(/app\.asar$/, 'app.asar.unpacked');
const helper = path.join(unpacked, 'dist/native/mooncap-clipboard');
async function native(action, filename, expectedVersion) {
  if (process.platform === 'darwin') {
    if (!existsSync(helper)) throw new Error('缺少剪贴板组件，请重新构建应用。');
    return (await execute(helper, [action, ...(filename ? [filename] : []), ...(expectedVersion !== undefined ? [String(expectedVersion)] : [])], { timeout: 10_000 })).stdout.trim();
  }
  if (process.platform === 'win32') {
    return (await execute('powershell.exe', ['-NoProfile', '-STA', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(unpacked, 'platform/win32/clipboard.ps1'), '-Action', action, ...(filename ? ['-FilePath', filename] : [])], { timeout: 15_000 })).stdout.trim();
  }
  return null;
}
export async function clipboardVersion() {
  try { return await native('change-count'); } catch { return null; }
}
export async function copyPng(bytes) {
  const image = nativeImage.createFromBuffer(Buffer.from(bytes));
  if (image.isEmpty()) throw new Error('图片无法解码。');
  await clipboard.write([new ClipboardItem({ 'image/png': new Blob([image.toPNG()], { type: 'image/png' }) })]);
}
export async function copyFile(filename) {
  if (process.platform === 'darwin' || process.platform === 'win32') {
    await native('copy-file', filename);
  } else {
    const uri = pathToFileURL(filename).href;
    await clipboard.write([new ClipboardItem({
      'text/uri-list': new Blob([`${uri}\r\n`], { type: 'text/uri-list' }),
      'x-special/gnome-copied-files': new Blob([`copy\n${uri}`], { type: 'x-special/gnome-copied-files' }),
    })]);
  }
  return { copied: true, path: filename };
}
export async function copyFileIfUnchanged(filename, expectedVersion) {
  if (process.platform === 'darwin' && expectedVersion !== null) {
    const result = await native('copy-file', filename, expectedVersion);
    return result === 'changed' ? { copied: false, clipboardChanged: true, path: filename } : { copied: true, path: filename };
  }
  const current = await clipboardVersion();
  if (expectedVersion === null || current === null || current !== expectedVersion) return { copied: false, clipboardChanged: true, path: filename };
  return copyFile(filename);
}
