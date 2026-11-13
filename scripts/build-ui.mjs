import { spawnSync } from 'node:child_process';
import { readdirSync, existsSync, copyFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const local = path.join(root, '.tools/moon');
const home = existsSync(path.join(local, 'bin/moon')) ? local : process.env.MOON_HOME;
const binary = home ? path.join(home, 'bin', process.platform === 'win32' ? 'moon.exe' : 'moon') : 'moon';
mkdirSync(path.join(root, 'dist/ui'), { recursive: true });
for (const entry of readdirSync(path.join(root, 'ui'), { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const directory = path.join(root, 'ui', entry.name);
  if (!existsSync(path.join(directory, 'moon.mod')) && !existsSync(path.join(directory, 'moon.mod.json'))) continue;
  const result = spawnSync(binary, ['-C', directory, 'build', '--target', 'js', '--release', '--output-json'], { env: { ...process.env, ...(home ? { MOON_HOME: home } : {}) }, encoding: 'utf8', maxBuffer: 20 * 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) { process.stdout.write(result.stdout); process.exit(result.status || 1); }
  const artifacts = result.stdout.split('\n').flatMap(line => { try { const item = JSON.parse(line); return item.$message_type === 'artifact' && item.target_backend === 'js' ? [item] : []; } catch { return []; } });
  const artifact = artifacts.find(item => item.package?.startsWith('mooncap/'));
  if (!artifact || !existsSync(artifact.path)) throw new Error(`No UI artifact for ${entry.name}`);
  copyFileSync(artifact.path, path.join(root, 'dist/ui', `${entry.name}.mjs`));
  console.log(`MoonBit UI built: ${entry.name}`);
}
