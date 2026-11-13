import { dialog, nativeImage, shell } from 'electron';
import { chmod, lstat, readFile, readdir, realpath, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { findExecutable, runProcess } from './media-tools.mjs';

const contained = (filename, directory) => filename.startsWith(`${directory}${path.sep}`);
async function directoryBytes(directory) {
  let total = 0;
  try {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const filename = path.join(directory, entry.name);
      if (entry.isDirectory()) total += await directoryBytes(filename);
      else if (entry.isFile()) total += (await lstat(filename)).size;
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  return total;
}

export function createLibraryService({ directory, images, recordings, allowedOutputs, isBusy = () => false, renderCapture }) {
  const thumbnails = new Map(), inflight = new Map();
  let thumbnailTail = Promise.resolve();
  let usage;
  let usageAt = 0;
  let usageKey;
  function assertIdle(kind, id) {
    if (isBusy(kind, id)) throw new Error('素材正在使用，请等待当前任务完成后重试。');
  }
  async function source(kind, id) {
    let base, filename, version;
    if (kind === 'image') {
      const record = images.record(id);
      if (!record.completed || !/^source-[a-f0-9-]{36}\.png$/.test(record.sourceFile)) throw new Error('请先确认截图。');
      base = path.join(images.directory, record.id);
      filename = path.join(base, record.sourceFile);
      version = record.document.revision;
    } else if (kind === 'video') {
      const record = recordings.get(id);
      base = path.join(recordings.directory, record.id);
      filename = path.join(base, 'original.webm');
      if (path.resolve(record.filename) !== path.resolve(filename)) throw new Error('录制原件路径无效。');
      version = record.state;
    } else throw new Error('未知素材类型。');
    const [canonicalBase, canonicalFile, info] = await Promise.all([realpath(base), realpath(filename), lstat(filename)]);
    const canonicalRoot = await realpath(kind === 'image' ? images.directory : recordings.directory);
    if (!contained(canonicalBase, canonicalRoot) || !contained(canonicalFile, canonicalBase) || !info.isFile()) throw new Error('素材路径无效。');
    const key = createHash('sha256').update(`${kind}:${id}:${version}:${info.size}:${info.mtimeMs}`).digest('hex');
    return { base: canonicalBase, filename: canonicalFile, key, version };
  }
  function thumbnailBytes(bytes) {
    const image = nativeImage.createFromBuffer(bytes);
    if (image.isEmpty()) throw new Error('无法生成素材缩略图。');
    const size = image.getSize(), scale = Math.min(1, 168 / size.width, 104 / size.height);
    return image.resize({ width: Math.max(1, Math.round(size.width * scale)), height: Math.max(1, Math.round(size.height * scale)), quality: 'good' }).toJPEG(72);
  }
  function remember(key, value) {
    thumbnails.delete(key); thumbnails.set(key, value);
    while (thumbnails.size > 64) thumbnails.delete(thumbnails.keys().next().value);
    return value;
  }
  async function generateThumbnail(kind, id) {
    const asset = await source(kind, id);
    if (kind === 'video' && asset.version !== 'complete') return null;
    if (thumbnails.has(asset.key)) return remember(asset.key, thumbnails.get(asset.key));
    const filename = path.join(asset.base, 'thumbnail.jpg'), metadata = path.join(asset.base, 'thumbnail.json');
    try {
      if (JSON.parse(await readFile(metadata, 'utf8')).key === asset.key) {
        const cached = await readFile(filename);
        if (cached.length <= 256 * 1024) return remember(asset.key, `data:image/jpeg;base64,${thumbnailBytes(cached).toString('base64')}`);
      }
    } catch { /* Rebuild a missing or stale derived preview. */ }
    const temporary = path.join(asset.base, `.thumbnail-${randomUUID()}.jpg`);
    const metadataTemporary = `${temporary}.json`;
    let bytes;
    try {
      if (kind === 'image') bytes = thumbnailBytes((await renderCapture(id)).png);
      else {
        await runProcess(await findExecutable('ffmpeg'), ['-hide_banner', '-loglevel', 'error', '-i', asset.filename, '-frames:v', '1', '-vf', 'scale=168:104:force_original_aspect_ratio=decrease', '-an', '-c:v', 'mjpeg', '-q:v', '5', '-update', '1', '-y', temporary], { timeoutMs: 15_000 });
        bytes = thumbnailBytes(await readFile(temporary));
      }
      const result = `data:image/jpeg;base64,${bytes.toString('base64')}`;
      // A human edit can finish while rendering; only cache an unchanged source.
      if ((await source(kind, id)).key !== asset.key) return result;
      await writeFile(temporary, bytes, { mode: 0o600 });
      await chmod(temporary, 0o600);
      await writeFile(metadataTemporary, JSON.stringify({ key: asset.key }), { mode: 0o600 });
      await rename(temporary, filename); await rename(metadataTemporary, metadata);
      return remember(asset.key, result);
    } finally {
      await Promise.all([rm(temporary, { force: true }), rm(metadataTemporary, { force: true })]);
    }
  }
  function thumbnail(kind, id) {
    const key = `${kind}:${id}`;
    if (inflight.has(key)) return inflight.get(key);
    // Serial generation prevents a history list from spawning many renderers or FFmpeg processes.
    const operation = thumbnailTail.then(() => generateThumbnail(kind, id));
    thumbnailTail = operation.then(() => undefined, () => undefined);
    inflight.set(key, operation);
    void operation.finally(() => inflight.delete(key)).catch(() => {});
    return operation;
  }
  async function validatedExport(filename) {
    if (typeof filename !== 'string' || !path.isAbsolute(filename) || !allowedOutputs.has(filename)) throw new Error('未知导出文件。');
    const [resolved, info] = await Promise.all([realpath(filename), lstat(filename)]);
    if (!info.isFile()) throw new Error('只能操作本应用导出的普通文件。');
    for (const folder of [images.directory, recordings.directory]) {
      const protectedRoot = await realpath(folder);
      if (contained(resolved, protectedRoot) || resolved === protectedRoot) throw new Error('不能删除素材原件。');
    }
    return { resolved, info };
  }
  async function storage() {
    const key = `${images.records.size}:${recordings.records.size}:${allowedOutputs.size}`;
    if (usage && usageKey === key && Date.now() - usageAt < 2000) return usage;
    const [imagesBytes, recordingsBytes, localExportsBytes] = await Promise.all([
      directoryBytes(images.directory), directoryBytes(recordings.directory), directoryBytes(path.join(directory, 'exports')),
    ]);
    const exportFiles = [];
    let externalBytes = 0;
    const exportRoot = await realpath(path.join(directory, 'exports')).catch(() => path.resolve(directory, 'exports'));
    const counted = new Set();
    for (const filename of allowedOutputs) {
      try {
        const { resolved, info } = await validatedExport(filename);
        exportFiles.push({ path: filename, bytes: info.size });
        if (!contained(resolved, exportRoot) && !counted.has(resolved)) externalBytes += info.size;
        counted.add(resolved);
      } catch { /* A user may have moved an exported file in Finder. */ }
    }
    usage = { imagesBytes, recordingsBytes, exportsBytes: localExportsBytes + externalBytes, exportFiles };
    usageAt = Date.now(); usageKey = key; return usage;
  }
  async function revealAsset(kind, id) {
    const asset = await source(kind, id); shell.showItemInFolder(asset.filename); return { revealed: true };
  }
  async function deleteExport(filename) {
    assertIdle('export', filename);
    await validatedExport(filename);
    const { response } = await dialog.showMessageBox({ type: 'warning', message: '删除这个导出文件？',
      detail: `${path.basename(filename)}\n原始素材和编辑草稿会保留。如果这个文件仍在剪贴板中，删除会使尚未完成的粘贴失效。`,
      buttons: ['取消', '删除导出文件'], defaultId: 0, cancelId: 0, noLink: true });
    if (response !== 1) return { canceled: true };
    await validatedExport(filename);
    assertIdle('export', filename);
    await rm(filename);
    allowedOutputs.delete(filename); usage = undefined;
    return { removed: true };
  }
  return { storage, thumbnail, revealAsset, deleteExport };
}
