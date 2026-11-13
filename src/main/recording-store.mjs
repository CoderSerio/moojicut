import { lstat, mkdir, open, readFile, readdir, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { validateBytes } from './media-input.mjs';
import { video_open, video_dispose } from '../../dist/core/core.mjs';
import { findExecutable, probeMedia } from './media-tools.mjs';

const MAX_PENDING_BYTES = 64 * 1024 * 1024;
const ID = /^[a-f0-9-]{36}$/;

export class RecordingStore {
  constructor(directory, { ffprobe } = {}) {
    this.directory = directory;
    this.ffprobe = ffprobe;
    this.records = new Map();
    this.activeId = null;
    this.starting = false;
  }

  async initialize() {
    await mkdir(this.directory, { recursive: true });
    for (const entry of await readdir(this.directory, { withFileTypes: true })) {
      if (!entry.isDirectory() || !ID.test(entry.name)) continue;
      try {
        const metadata = JSON.parse(await readFile(path.join(this.directory, entry.name, 'recording.json'), 'utf8'));
        const filename = path.join(this.directory, entry.name, 'original.webm');
        const fileInfo = await lstat(filename);
        if (metadata.id !== entry.name || !fileInfo.isFile()) continue;
        const complete = metadata.state === 'complete' && Number.isFinite(metadata.durationMs) && metadata.durationMs > 0 && metadata.durationMs <= 7 * 24 * 60 * 60 * 1000
          && Number.isInteger(metadata.width) && metadata.width > 0 && metadata.width <= 32768
          && Number.isInteger(metadata.height) && metadata.height > 0 && metadata.height <= 32768
          && typeof metadata.hasAudio === 'boolean' && fileInfo.size > 0 && metadata.bytes === fileInfo.size;
        const record = {
          id: entry.name, filename, state: complete ? 'complete' : 'incomplete', bytes: fileInfo.size,
          mimeType: typeof metadata.mimeType === 'string' && /^video\/webm(?:;[a-zA-Z0-9=, ."_-]+)?$/.test(metadata.mimeType) ? metadata.mimeType : 'video/webm',
          createdAt: typeof metadata.createdAt === 'string' && Number.isFinite(Date.parse(metadata.createdAt)) ? new Date(metadata.createdAt).toISOString() : fileInfo.birthtime.toISOString(),
          ...(typeof metadata.interruptedReason === 'string' ? { interruptedReason: metadata.interruptedReason.slice(0, 2000) } : {}),
          ...(complete ? { durationMs: metadata.durationMs, width: metadata.width, height: metadata.height, frameRate: metadata.frameRate || 30, hasAudio: metadata.hasAudio } : {}),
        };
        this.records.set(entry.name, record);
      } catch { /* Unfinished files are retained, even if their metadata is unreadable. */ }
    }
  }

  get(id) {
    if (typeof id !== 'string' || !ID.test(id) || !this.records.has(id)) throw new Error('Unknown recording.');
    return this.records.get(id);
  }

  describe(record) {
    const { id, durationMs, width, height, frameRate = 30, hasAudio, createdAt, state, bytes = 0, interruptedReason } = record;
    return { id, durationMs, width, height, frameRate, hasAudio, createdAt, state, bytes, ...(interruptedReason ? { interruptedReason } : {}), url: `mooncap-media://recording/${id}` };
  }

  async metadata(record) {
    const filename = path.join(this.directory, record.id, 'recording.json');
    const temporary = `${filename}.tmp`;
    await writeFile(temporary, JSON.stringify({ ...this.describe(record), mimeType: record.mimeType }, null, 2));
    await rename(temporary, filename);
  }

  async begin({ mimeType = 'video/webm' } = {}) {
    if (this.activeId || this.starting) throw new Error('A recording is already in progress.');
    if (typeof mimeType !== 'string' || !/^video\/webm(?:;[a-zA-Z0-9=, ."_-]+)?$/.test(mimeType)) throw new Error('Recording must use a supported WebM format.');
    this.starting = true;
    try {
      const id = randomUUID();
      const directory = path.join(this.directory, id);
      await mkdir(directory, { recursive: false });
      const filename = path.join(directory, 'original.webm');
      const handle = await open(filename, 'wx');
      const record = { id, filename, handle, mimeType, createdAt: new Date().toISOString(), state: 'recording', nextSequence: 0, bytes: 0, pendingBytes: 0, tail: Promise.resolve() };
      this.records.set(id, record);
      this.activeId = id;
      try { await this.metadata(record); }
      catch (error) {
        await handle.close();
        this.activeId = null;
        record.state = 'incomplete';
        throw error;
      }
      return { id };
    } finally { this.starting = false; }
  }

  append(id, sequence, value) {
    const record = this.get(id);
    if (record.state !== 'recording' || this.activeId !== id || record.failure) throw new Error('The recording is not accepting more data.');
    if (!Number.isInteger(sequence) || sequence !== record.nextSequence) throw new Error('Recording chunks arrived out of order.');
    const bytes = validateBytes(value);
    if (record.pendingBytes + bytes.length > MAX_PENDING_BYTES) throw new Error('Recording data is arriving faster than it can be saved.');
    record.nextSequence += 1;
    record.pendingBytes += bytes.length;
    const operation = record.tail.then(async () => {
      if (record.failure) throw record.failure;
      let offset = 0;
      while (offset < bytes.length) {
        const result = await record.handle.write(bytes, offset, bytes.length - offset, null);
        if (result.bytesWritten === 0) throw new Error('The recording file could not be written.');
        offset += result.bytesWritten;
      }
      record.bytes += bytes.length;
      return { bytes: record.bytes };
    }).catch((error) => {
      record.failure = error;
      throw error;
    }).finally(() => { record.pendingBytes -= bytes.length; });
    record.tail = operation.catch(() => {});
    return operation;
  }

  async finish(id, { interruptedReason } = {}) {
    const record = this.get(id);
    if (record.state !== 'recording' || this.activeId !== id) throw new Error('This recording is not active.');
    if (interruptedReason !== undefined && (typeof interruptedReason !== 'string' || interruptedReason.length > 2000)) throw new Error('Invalid recording interruption reason.');
    if (interruptedReason) record.interruptedReason = interruptedReason;
    record.state = 'finishing';
    try {
      await record.tail;
      await record.handle.sync();
      await record.handle.close();
      record.handle = null;
      if (record.failure) throw record.failure;
      Object.assign(record, await probeMedia(record.filename, this.ffprobe || await findExecutable('ffprobe')));
      record.state = 'complete';
      await this.metadata(record);
      return this.describe(record);
    } catch (error) {
      record.state = 'incomplete';
      if (record.handle) { await record.handle.close().catch(() => {}); record.handle = null; }
      await this.metadata(record).catch(() => {});
      throw new Error(`${error.message} Original recording retained in ${path.dirname(record.filename)}.`);
    } finally { this.activeId = null; }
  }

  async abort(id) {
    const record = this.get(id);
    if (record.state !== 'recording' || this.activeId !== id) return;
    record.state = 'aborting';
    await record.tail;
    await record.handle.sync().catch(() => {});
    await record.handle.close().catch(() => {});
    record.handle = null;
    this.activeId = null;
    record.state = 'incomplete';
    await this.metadata(record);
  }

  validateDraft(id, document) {
    const record = this.get(id);
    if (record.state !== 'complete') throw new Error('请先恢复或完成录像。');
    const text = JSON.stringify(document);
    if (!text || text.length > 65536) throw new Error('编辑草稿格式无效或过大。');
    const result = JSON.parse(video_open(JSON.stringify(this.describe(record)), text));
    if (!result.ok) throw new Error(result.error.message);
    video_dispose(result.session);
    return result.document;
  }

  async loadDraft(id) {
    const record = this.get(id);
    await record.draftTail;
    try {
      const document = JSON.parse(await readFile(path.join(this.directory, id, 'draft.json'), 'utf8'));
      return this.validateDraft(id, document);
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw error;
    }
  }

  async saveDraft(id, document) {
    const normalized = this.validateDraft(id, document);
    const record = this.get(id);
    const operation = (record.draftTail || Promise.resolve()).then(async () => {
      const filename = path.join(this.directory, id, 'draft.json');
      const temporary = `${filename}.tmp`;
      await writeFile(temporary, JSON.stringify(normalized, null, 2));
      await rename(temporary, filename);
      return { ok: true };
    });
    record.draftTail = operation.catch(() => {});
    return operation;
  }

  async list() {
    for (const record of this.records.values()) {
      if (record.state !== 'incomplete' || record.recoveryAttempted) continue;
      record.recoveryAttempted = true;
      try {
        Object.assign(record, await probeMedia(record.filename, this.ffprobe || await findExecutable('ffprobe')));
        record.state = 'complete';
        record.interruptedReason ||= '上次录制未正常完成，已恢复可播放原件。';
        await this.metadata(record);
      } catch { /* Incomplete recordings stay visible and remain on disk. */ }
    }
    return [...this.records.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt)).map((record) => this.describe(record));
  }
}
