import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import path from 'node:path';

export const defaults = Object.freeze({ screenshotShortcut: 'CommandOrControl+Shift+1', recordingShortcut: 'CommandOrControl+Shift+2', stopShortcut: 'CommandOrControl+Shift+X', microphone: false, systemAudio: false, microphoneId: '' });
export class Preferences {
  constructor(directory) { this.directory = directory; this.value = { ...defaults }; }
  async initialize() {
    await mkdir(this.directory, { recursive: true });
    try { this.value = this.validate({ ...defaults, ...JSON.parse(await readFile(path.join(this.directory, 'preferences.json'), 'utf8')) }); } catch { /* default settings */ }
  }
  validate(input) {
    const result = {};
    for (const key of Object.keys(defaults)) {
      const value = input[key];
      if (key === 'microphoneId') { if (typeof value !== 'string' || value.length > 500) throw new Error('无效的输入设备。'); }
      else if (typeof defaults[key] === 'boolean') { if (typeof value !== 'boolean') throw new Error('无效的声音设置。'); }
      else if (typeof value !== 'string' || !value.trim() || value.length > 80) throw new Error('请输入有效的快捷键。');
      result[key] = value;
    }
    const keys = [result.screenshotShortcut, result.recordingShortcut, result.stopShortcut];
    if (new Set(keys.map(key => key.toLowerCase())).size !== keys.length) throw new Error('三个快捷键不能相同。');
    return result;
  }
  async update(patch) {
    const value = this.validate({ ...this.value, ...patch });
    const file = path.join(this.directory, 'preferences.json');
    await writeFile(`${file}.tmp`, JSON.stringify(value, null, 2));
    await rename(`${file}.tmp`, file);
    this.value = value;
    return value;
  }
}
