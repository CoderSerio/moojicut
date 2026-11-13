import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') {
  throw new Error('The AppKit app build requires macOS and Xcode Command Line Tools.');
}
const options = new Set(process.argv.slice(2));
for (const option of options) {
  if (!['--run', '--preferences'].includes(option)) throw new Error(`Unknown native app build option: ${option}`);
}
if (options.has('--preferences') && !options.has('--run')) {
  throw new Error('Use --run --preferences to build and open the preferences window.');
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourceDirectory = join(root, 'native', 'macos');
const localHome = join(root, '.tools', 'moon');
const localBinary = join(localHome, 'bin', 'moon');
// Match the core build/check: repository toolchain, MOON_HOME, then PATH.
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
  throw new Error('Cannot locate native headers. Set MOON_HOME to the matching complete MoonBit toolchain.');
}
const env = { ...process.env, MOON_HOME: moonHome };
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
function sources(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const filename = join(directory, entry.name);
    return entry.isDirectory() ? sources(filename) : entry.isFile() && entry.name.endsWith('.m') ? [filename] : [];
  }).sort();
}
if (!existsSync(sourceDirectory)) throw new Error('Native AppKit sources are missing: native/macos.');
const objectiveC = sources(sourceDirectory);
if (!objectiveC.length) throw new Error('No Objective-C source files found in native/macos.');

const project = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const coreManifest = readFileSync(join(root, 'core', 'moon.mod'), 'utf8');
const coreVersion = /^\s*version\s*=\s*"([^"]+)"/mu.exec(coreManifest)?.[1] || '0.1.0';
const compilerVersion = run(join(moonHome, 'bin', 'moonc'), ['-v']).trim();
const clangVersion = run('xcrun', ['clang', '--version']).split(/\r?\n/u)[0];
console.log(`MoonBit compiler: ${compilerVersion}`);
console.log(clangVersion);

const buildDirectory = join(root, '.artifacts', 'native-app');
mkdirSync(buildDirectory, { recursive: true });
const buildOutput = run(moon, ['-C', join(root, 'core'), '--target-dir', join(buildDirectory, 'moon'),
  'build', '--target', 'native', '--release', '--deny-warn', '--output-json']);
const artifacts = buildOutput.split(/\r?\n/u).flatMap(line => {
  try {
    const message = JSON.parse(line);
    return message.$message_type === 'artifact' ? [message] : [];
  } catch { return []; }
});
const archive = artifacts.find(item => item.package === 'mooncap/core' && item.target_backend === 'native');
if (!archive || !archive.path.endsWith('.a') || !existsSync(archive.path)) {
  throw new Error('MoonBit did not report the expected native foreign_library static archive.');
}

const appName = 'Mooncap Native.app';
const outputDirectory = join(root, 'dist', 'native-app');
const appPath = join(outputDirectory, appName);
const staging = mkdtempSync(join(buildDirectory, 'staging-'));
const stagedApp = join(staging, appName);
const contents = join(stagedApp, 'Contents');
const executable = join(contents, 'MacOS', 'MooncapNative');
const xml = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
try {
  mkdirSync(dirname(executable), { recursive: true });
  mkdirSync(join(contents, 'Resources'), { recursive: true });
  run('xcrun', ['clang', '-fobjc-arc', '-O2', '-Wall', '-Wextra', '-Werror',
    '-I', includeDirectory, '-I', sourceDirectory, ...objectiveC, archive.path,
    '-framework', 'AppKit', '-framework', 'Foundation', '-o', executable]);
  writeFileSync(join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleName</key><string>Mooncap Native</string>
  <key>CFBundleDisplayName</key><string>Mooncap</string>
  <key>CFBundleIdentifier</key><string>dev.mooncap.native</string>
  <key>CFBundleExecutable</key><string>MooncapNative</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${xml(project.version)}</string>
  <key>CFBundleVersion</key><string>${xml(project.version)}</string>
  <key>MoonBitCoreVersion</key><string>${xml(coreVersion)}</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
`);
  run('/usr/bin/plutil', ['-lint', join(contents, 'Info.plist')]);
  const dependencies = run('/usr/bin/otool', ['-L', executable]);
  if (/Electron|Chromium|WebKit|libnode/iu.test(dependencies)) {
    throw new Error('The native app unexpectedly links a browser or Node runtime.');
  }
  writeFileSync(join(contents, 'Resources', 'build.json'), JSON.stringify({
    version: project.version, coreVersion, compilerVersion, clangVersion, arch: process.arch,
    frameworks: ['AppKit', 'Foundation'], signing: 'ad-hoc', notarized: false,
  }, null, 2) + '\n');
  // Local development signature only; no signing identity or network is used.
  run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', stagedApp]);
  run('/usr/bin/codesign', ['--verify', '--strict', stagedApp]);
  mkdirSync(outputDirectory, { recursive: true });
  // Keep the previous build intact until compilation and bundle checks pass.
  rmSync(appPath, { recursive: true, force: true });
  renameSync(stagedApp, appPath);
} finally { rmSync(staging, { recursive: true, force: true }); }

console.log(`Native app: ${appPath}`);
console.log(`Executable: ${(statSync(join(appPath, 'Contents', 'MacOS', 'MooncapNative')).size / 1024).toFixed(0)} KiB; ${objectiveC.length} Objective-C files + MoonBit static core; ad-hoc signed.`);
if (options.has('--run')) {
  // Launch Services starts the standalone app; Node exits after launching it.
  run('/usr/bin/open', ['-n', appPath, ...(options.has('--preferences') ? ['--args', '--preferences'] : [])]);
  console.log(options.has('--preferences') ? 'Opened native preferences.' : 'Started the native menu bar app.');
}
