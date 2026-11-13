import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
if (process.platform === 'darwin') {
  mkdirSync(path.join(root, 'dist/native'), { recursive: true });
  for (const [name, frameworks] of [['clipboard', ['AppKit']], ['window-bounds', ['Foundation', 'CoreGraphics']]]) {
    const result = spawnSync('/usr/bin/clang', ['-fobjc-arc', '-O2', ...frameworks.flatMap(name => ['-framework', name]), path.join(root, `platform/darwin/${name}.m`), '-o', path.join(root, `dist/native/mooncap-${name}`)], { stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status) process.exit(result.status);
  }
}
