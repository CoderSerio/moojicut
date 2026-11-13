import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const localHome = join(root, '.tools', 'moon');
const binaryName = process.platform === 'win32' ? 'moon.exe' : 'moon';
const localBinary = join(localHome, 'bin', binaryName);
const moonHome = existsSync(localBinary) ? localHome : process.env.MOON_HOME;
const moon = moonHome ? join(moonHome, 'bin', binaryName) : binaryName;
const env = { ...process.env, ...(moonHome ? { MOON_HOME: moonHome } : {}) };

for (const arg of process.argv.slice(2)) {
  if (arg !== '--test') throw new Error(`Unknown build-core option: ${arg}`);
}

function run(args) {
  const result = spawnSync(moon, ['-C', join(root, 'core'), ...args], {
    cwd: root,
    env,
    encoding: 'utf8',
    timeout: 120_000,
    maxBuffer: 10 * 1024 * 1024,
  });
  if (result.error) {
    throw new Error(`Cannot run MoonBit: ${result.error.message}. Install the toolchain or set MOON_HOME; see core/README.md.`);
  }
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(`MoonBit ${args[0]} failed (${result.signal ?? result.status}).`);
  }
  if (result.stderr) process.stderr.write(result.stderr);
  return result.stdout;
}

if (process.argv.includes('--test')) {
  process.stdout.write(run(['test', '--target', 'js', '--deny-warn']));
}

const output = run(['build', '--target', 'js', '--release', '--deny-warn', '--output-json']);
const artifacts = output.split(/\r?\n/u).flatMap((line) => {
  try {
    const message = JSON.parse(line);
    return message.$message_type === 'artifact' ? [message] : [];
  } catch {
    return [];
  }
});
const artifact = artifacts.find((item) => item.package === 'mooncap/core' && item.target_backend === 'js');
if (!artifact || !existsSync(artifact.path)) {
  throw new Error('MoonBit did not report the expected mooncap/core JavaScript artifact.');
}

const destination = join(root, 'dist', 'core', 'core.mjs');
mkdirSync(dirname(destination), { recursive: true });
copyFileSync(artifact.path, destination);

// Check the actual ESM boundary, not just MoonBit's internal test entry point.
const core = await import(pathToFileURL(destination).href);
for (const name of ['edit_plan', 'crop_rect', 'recording_transition', 'export_profile']) {
  assert.equal(typeof core[name], 'function', `Missing MoonBit export ${name}`);
}
assert.equal(JSON.parse(core.recording_transition('idle', 'start')).state, 'requesting');
console.log(`MoonBit core built: ${destination}`);
