import { readdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
let checked = 0;
for (const folder of ['src', 'scripts', 'test']) {
  for (const filename of readdirSync(join(root, folder), { recursive: true })) {
    if (!/\.(?:mjs|cjs|js)$/.test(filename)) continue;
    const result = spawnSync(process.execPath, ['--check', join(root, folder, filename)], { stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) process.exit(result.status ?? 1);
    checked += 1;
  }
}
console.log(`Syntax checked ${checked} JavaScript files.`);
