import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, realpathSync } from 'node:fs';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// This verifies a macOS Foundation host embedding the existing core. It does
// not build the desktop product or change the default JavaScript target.
if (process.platform !== 'darwin') {
  throw new Error('The Objective-C/Foundation embedding check requires macOS and Xcode Command Line Tools.');
}
if (process.argv.length > 2) throw new Error('check-native-core does not accept arguments.');

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const localHome = join(root, '.tools', 'moon');
const localBinary = join(localHome, 'bin', 'moon');
// Match build-core.mjs: repository toolchain, explicit MOON_HOME, then PATH.
let moonHome = existsSync(localBinary) ? localHome : process.env.MOON_HOME;
let moon = moonHome ? join(moonHome, 'bin', 'moon') : 'moon';
if (!moonHome) {
  const executable = (process.env.PATH || '').split(delimiter)
    .map(directory => join(directory, 'moon')).find(filename => existsSync(filename));
  if (!executable) throw new Error('Cannot find MoonBit. Install .tools/moon or set MOON_HOME.');
  moon = realpathSync(executable);
  moonHome = resolve(dirname(moon), '..');
}
const includeDirectory = join(moonHome, 'include');
if (!existsSync(join(includeDirectory, 'moonbit.h'))) {
  throw new Error('Cannot locate the MoonBit native headers. Set MOON_HOME to the matching complete toolchain.');
}
const env = { ...process.env, MOON_HOME: moonHome };
const outputDirectory = join(root, '.artifacts', 'native-core');
mkdirSync(outputDirectory, { recursive: true });

function run(binary, args) {
  const result = spawnSync(binary, args, {
    cwd: root, env, encoding: 'utf8', timeout: 120_000, maxBuffer: 10 * 1024 * 1024,
  });
  if (result.error) throw new Error(`Cannot run ${binary}: ${result.error.message}`);
  if (result.status !== 0) {
    process.stderr.write(result.stdout || '');
    process.stderr.write(result.stderr || '');
    throw new Error(`${binary} ${args[0]} failed (${result.signal || result.status}).`);
  }
  return result.stdout;
}
function runMoon(args) {
  return run(moon, ['-C', join(root, 'core'), '--target-dir', join(outputDirectory, 'moon'), ...args]);
}

console.log(`MoonBit compiler: ${run(join(moonHome, 'bin', 'moonc'), ['-v']).trim()}`);
console.log(run('xcrun', ['clang', '--version']).split(/\r?\n/u)[0]);
process.stdout.write(runMoon(['test', '--target', 'native', '--deny-warn']));
const output = runMoon(['build', '--target', 'native', '--release', '--deny-warn', '--output-json']);
const artifacts = output.split(/\r?\n/u).flatMap(line => {
  try {
    const message = JSON.parse(line);
    return message.$message_type === 'artifact' ? [message] : [];
  } catch { return []; }
});
const archive = artifacts.find(item => item.package === 'mooncap/core' && item.target_backend === 'native');
if (!archive || !archive.path.endsWith('.a') || !existsSync(archive.path)) {
  throw new Error('MoonBit did not report the expected native foreign_library static archive.');
}
const executable = join(outputDirectory, 'core-embedding');
run('xcrun', ['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-I', includeDirectory,
  join(root, 'test', 'native', 'core-embedding.m'), archive.path, '-framework', 'Foundation', '-o', executable]);
process.stdout.write(run(executable, []));
console.log(`Native archive: ${archive.path}`);
console.log(`Embedding check: ${executable}`);
