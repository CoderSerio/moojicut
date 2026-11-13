import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('Native shortcut checks require macOS.');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = join(root, '.artifacts', 'native-shortcuts');
mkdirSync(output, { recursive: true });
const executable = join(output, 'shortcut-settings');
const preferences = join(root, 'native', 'macos', 'preferences');
function run(binary, args) {
  const result = spawnSync(binary, args, { cwd: root, encoding: 'utf8', timeout: 60_000 });
  process.stdout.write(result.stdout || '');
  process.stderr.write(result.stderr || '');
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${binary} failed (${result.signal || result.status}).`);
}
run('xcrun', ['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-I', preferences,
  join(root, 'test', 'native', 'shortcut-settings.m'),
  join(preferences, 'MCShortcutStore.m'), join(preferences, 'MCSystemShortcutCheck.m'),
  '-framework', 'AppKit', '-framework', 'Carbon', '-o', executable]);
run(executable, []);
