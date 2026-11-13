import { mkdir, open, readFile, readdir, writeFile, rename, rm, chmod } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { validatePng } from './media-input.mjs';

const ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const clone = (value) => structuredClone(value);
const error = (message, code, details) => Object.assign(new Error(message), { code, details });

export class ImageStore {
  constructor(directory, { onChange = () => {}, cropPng, core } = {}) {
    this.directory = directory;
    this.onChange = onChange;
    this.cropPng = cropPng;
    this.core = core;
    this.records = new Map();
  }

  async loadCore() {
    this.core ??= await import('../../dist/core/core.mjs');
    return this.core;
  }

  call(name, request) {
    const result = JSON.parse(this.core[name](JSON.stringify(request)));
    if (!result.ok) throw error(result.error.message, result.error.code);
    return result.document;
  }

  async initialize() {
    await this.loadCore();
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    await chmod(this.directory, 0o700);
    for (const entry of await readdir(this.directory, { withFileTypes: true })) {
      if (!entry.isDirectory() || !ID.test(entry.name)) continue;
      try {
        const base = path.join(this.directory, entry.name);
        const text = await readFile(path.join(base, 'capture.json'), 'utf8');
        if (text.length > 32 * 1024 * 1024) continue;
        const saved = JSON.parse(text);
        if (saved.id !== entry.name || !/^source-[a-f0-9-]{36}\.png$/.test(saved.sourceFile)) continue;
        // History only needs the PNG header at startup. Full sources are loaded
        // for the requested editor/preview and never cached in completed records.
        const file = await open(path.join(base, saved.sourceFile), 'r');
        const header = Buffer.alloc(24);
        try {
          const details = await file.stat();
          if (!details.isFile() || details.size < 24 || details.size > 64 * 1024 * 1024) continue;
          if ((await file.read(header, 0, header.length, 0)).bytesRead !== header.length) continue;
        } finally { await file.close(); }
        validatePng(header);
        const width = header.readUInt32BE(16), height = header.readUInt32BE(20);
        if (saved.document?.width !== width || saved.document?.height !== height) continue;
        if (!Number.isSafeInteger(saved.document.revision) || saved.document.revision < 0) continue;
        let document = this.call('image_create', { width, height, viewport: saved.document.viewport });
        if (!Array.isArray(saved.document.annotations)) continue;
        if (saved.document.annotations.length) document = this.call('image_apply', {
          document, command: { type: 'add', annotations: saved.document.annotations },
        });
        document = { ...document, revision: saved.document.revision, undo: [], redo: [] };
        this.records.set(saved.id, {
          id: saved.id, document, completed: true, mode: 'window',
          name: typeof saved.name === 'string' ? saved.name.slice(0, 200) : '截图',
          createdAt: typeof saved.createdAt === 'string' ? saved.createdAt : new Date().toISOString(),
          updatedAt: typeof saved.updatedAt === 'string' ? saved.updatedAt : saved.createdAt,
          sourceFile: saved.sourceFile, tail: Promise.resolve(),
        });
      } catch { /* Keep unreadable files intact so the user can recover them. */ }
    }
  }

  record(id) {
    if (typeof id !== 'string' || !ID.test(id) || !this.records.has(id)) throw error('找不到这张截图。', 'unknown_capture');
    return this.records.get(id);
  }

  describe(record, { image = true } = {}) {
    return {
      id: record.id, name: record.name, createdAt: record.createdAt, updatedAt: record.updatedAt,
      completed: record.completed, mode: record.mode, document: clone(record.document),
      width: record.document.width, height: record.document.height, revision: record.document.revision,
      ...(record.displayBounds ? { displayBounds: clone(record.displayBounds) } : {}),
      ...(record.scaleFactor ? { scaleFactor: record.scaleFactor } : {}),
      ...(image ? { imageUrl: `data:image/png;base64,${this.sourcePng(record).toString('base64')}` } : {}),
    };
  }

  get(id, options) { return this.describe(this.record(id), options); }
  sourcePng(record) {
    if (record.png) return record.png;
    if (!record.completed || !record.sourceFile) throw error('截图原件不可用。', 'missing_source');
    const png = validatePng(readFileSync(path.join(this.directory, record.id, record.sourceFile)));
    if (png.readUInt32BE(16) !== record.document.width || png.readUInt32BE(20) !== record.document.height) {
      throw error('截图原件尺寸已改变。', 'invalid_source');
    }
    return png;
  }
  readPng(id) { return Buffer.from(this.sourcePng(this.record(id))); }

  notify(record, image = false) {
    try { this.onChange(this.describe(record, { image })); }
    catch { /* A closed view must not roll back an already committed edit. */ }
  }

  async create({ png, width, height, viewport, mode = 'window', displayBounds, scaleFactor, name = '截图' }) {
    await this.loadCore();
    const bytes = validatePng(png);
    const actualWidth = bytes.readUInt32BE(16), actualHeight = bytes.readUInt32BE(20);
    if ((width !== undefined && width !== actualWidth) || (height !== undefined && height !== actualHeight)) {
      throw error('图片尺寸与采集元数据不一致。', 'invalid_dimensions');
    }
    const document = this.call('image_create', { width: actualWidth, height: actualHeight, ...(viewport !== undefined ? { viewport } : {}) });
    const now = new Date().toISOString();
    const record = { id: randomUUID(), png: bytes, document, completed: false,
      createdAt: now, updatedAt: now, name: String(name).slice(0, 200),
      mode: mode === 'overlay' ? 'overlay' : 'window', displayBounds, scaleFactor, tail: Promise.resolve() };
    this.records.set(record.id, record);
    return this.describe(record);
  }

  enqueue(id, action) {
    const record = this.record(id);
    const operation = record.tail.then(() => {
      if (this.records.get(id) !== record) throw error('这张截图已被关闭或删除。', 'unknown_capture');
      return action(record);
    });
    // Do not retain an operation result (including base64 source images) in the
    // long-lived queue promise once the caller has received it.
    record.tail = operation.then(() => undefined, () => undefined);
    return operation;
  }

  checkRevision(record, expectedRevision) {
    if (expectedRevision !== undefined && expectedRevision !== record.document.revision) {
      throw error('截图已经改变，请读取最新版本后重试。', 'revision_conflict', { revision: record.document.revision });
    }
  }

  async persist(record) {
    const base = path.join(this.directory, record.id);
    await mkdir(base, { recursive: true, mode: 0o700 });
    const previous = record.sourceFile;
    const sourceFile = record.sourceFile ?? `source-${randomUUID()}.png`;
    if (!record.sourceFile) await writeFile(path.join(base, sourceFile), record.png, { flag: 'wx', mode: 0o600 });
    const metadata = { id: record.id, name: record.name, createdAt: record.createdAt, updatedAt: record.updatedAt,
      sourceFile, document: { ...record.document, undo: [], redo: [] } };
    const temporary = path.join(base, `.${randomUUID()}.json.tmp`);
    try {
      await writeFile(temporary, JSON.stringify(metadata), { flag: 'wx', mode: 0o600 });
      await rename(temporary, path.join(base, 'capture.json'));
      record.sourceFile = sourceFile;
    } catch (failure) {
      await rm(temporary, { force: true }).catch(() => {});
      if (!previous) await rm(path.join(base, sourceFile), { force: true }).catch(() => {});
      throw failure;
    }
  }

  apply(id, command, expectedRevision) {
    return this.enqueue(id, async (record) => {
      this.checkRevision(record, expectedRevision);
      const document = this.call('image_apply', { document: record.document, command,
        ...(expectedRevision === undefined ? {} : { expectedRevision }) });
      const candidate = { ...record, document, updatedAt: new Date().toISOString() };
      if (record.completed) await this.persist(candidate);
      const { tail: _tail, ...committed } = candidate;
      Object.assign(record, committed);
      this.notify(record);
      return this.describe(record, { image: false });
    });
  }

  complete(id, { expectedRevision } = {}) {
    return this.enqueue(id, async (record) => {
      this.checkRevision(record, expectedRevision);
      const rect = record.document.viewport;
      if (!rect) throw error('请先选择截图区域。', 'empty_crop');
      const document = this.call('image_finalize', { document: record.document });
      const changed = rect.x !== 0 || rect.y !== 0 || rect.width !== record.document.width || rect.height !== record.document.height;
      if (changed && !this.cropPng) throw error('截图裁切服务未初始化。', 'missing_crop_adapter');
      const source = this.sourcePng(record);
      const png = changed ? validatePng(await this.cropPng(source, rect)) : source;
      if (png.readUInt32BE(16) !== document.width || png.readUInt32BE(20) !== document.height) {
        throw error('截图裁切尺寸不正确。', 'invalid_crop_result');
      }
      const previous = record.sourceFile;
      const candidate = { ...record, png, document, completed: true, mode: 'window',
        displayBounds: undefined, scaleFactor: undefined, sourceFile: changed ? undefined : record.sourceFile,
        updatedAt: new Date().toISOString() };
      await this.persist(candidate);
      candidate.png = undefined;
      const { tail: _tail, ...committed } = candidate;
      Object.assign(record, committed);
      if (previous && previous !== record.sourceFile) await rm(path.join(this.directory, id, previous), { force: true }).catch(() => {});
      this.notify(record, true);
      return this.describe(record);
    });
  }

  cancel(id) {
    return this.enqueue(id, (record) => {
      if (!record.completed) this.records.delete(id);
      else this.releaseRecord(record);
      return { id, canceled: true, retained: record.completed };
    });
  }

  releaseRecord(record) {
    if (!record.completed) return false;
    record.png = undefined;
    record.document = { ...record.document, undo: [], redo: [] };
    return true;
  }

  release(id) {
    return this.enqueue(id, (record) => ({ id, released: this.releaseRecord(record) }));
  }

  list() {
    return [...this.records.values()].filter((record) => record.completed)
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
      .map((record) => this.describe(record, { image: false }));
  }

  remove(id) {
    return this.enqueue(id, async (record) => {
      if (record.completed) await rm(path.join(this.directory, id), { recursive: true, force: true });
      this.records.delete(id);
      return { id, removed: true };
    });
  }
}
