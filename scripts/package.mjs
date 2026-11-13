import { packager } from '@electron/packager';
import { access, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { bundleMedia } from './bundle-media.mjs';

const execute = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
if (process.platform !== 'darwin') throw new Error('This packaging entry currently validates macOS only. Add a platform-specific media/clipboard packaging path before publishing other platforms.');
const args = new Set(process.argv.slice(2));
for (const arg of args) if (!['--skip-build', '--skip-media'].includes(arg)) throw new Error(`Unknown packaging option: ${arg}`);
const project = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const installedElectron = JSON.parse(await readFile(path.join(root, 'node_modules/electron/package.json'), 'utf8'));
const runtime = path.join(root, 'node_modules/electron/dist');
const runtimeVersion = (await readFile(path.join(runtime, 'version'), 'utf8')).trim().replace(/^v/, '');
if (runtimeVersion !== installedElectron.version || project.devDependencies.electron !== runtimeVersion) throw new Error('Installed Electron runtime does not match the exact project version. Finish npm installation before packaging.');
await execute('/usr/bin/lipo', [path.join(runtime, 'Electron.app/Contents/MacOS/Electron'), '-verify_arch', process.arch === 'x64' ? 'x86_64' : process.arch]);
if (!args.has('--skip-build')) {
  for (const script of ['build-core.mjs', 'build-ui.mjs', 'build-native.mjs']) {
    const { stdout, stderr } = await execute(process.execPath, [path.join(root, 'scripts', script)], { cwd: root, maxBuffer: 20 * 1024 * 1024 });
    if (stdout) process.stdout.write(stdout); if (stderr) process.stderr.write(stderr);
  }
}
for (const file of ['dist/core/core.mjs', 'dist/ui/image.mjs', 'dist/ui/video.mjs']) await access(path.join(root, file));
for (const helper of ['mooncap-clipboard', 'mooncap-window-bounds']) await access(path.join(root, 'dist/native', helper), constants.X_OK);
const release = path.join(root, 'release');
await mkdir(release, { recursive: true });
let media;
if (args.has('--skip-media')) {
  const binDirectory = path.join(release, 'media/bin');
  const manifest = JSON.parse(await readFile(path.join(binDirectory, 'media-manifest.json'), 'utf8'));
  if (!manifest.validation?.h264AacEncodeProbeDecode || manifest.arch !== process.arch) throw new Error('No validated local media bundle; run without --skip-media.');
  media = { binDirectory, manifest };
} else media = await bundleMedia();

// Reuse the fully installed, version-checked official runtime; never substitute another Electron version.
let zipDirectory = process.env.MOONCAP_ELECTRON_ZIP_DIR && path.resolve(process.env.MOONCAP_ELECTRON_ZIP_DIR);
if (!zipDirectory) {
  zipDirectory = path.join(release, 'electron-runtime');
  await mkdir(zipDirectory, { recursive: true });
  const zip = path.join(zipDirectory, `electron-v${runtimeVersion}-darwin-${process.arch}.zip`);
  let refresh = true;
  try { refresh = (await stat(zip)).mtimeMs < (await stat(path.join(runtime, 'version'))).mtimeMs; } catch {}
  if (refresh) await execute('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', runtime, zip], { maxBuffer: 1024 * 1024 });
}
const permissionInfo = {
  NSMicrophoneUsageDescription: 'Mooncap 使用麦克风录制你选择的解说声音。',
  NSAudioCaptureUsageDescription: 'Mooncap 使用系统声音录制你选择的操作过程。',
  NSScreenCaptureUsageDescription: 'Mooncap 根据你的操作截取屏幕或录制所选区域。',
};
const outputs = await packager({
  dir: root, name: 'Mooncap', executableName: 'Mooncap', out: release,
  platform: 'darwin', arch: process.arch, electronVersion: runtimeVersion, electronZipDir: zipDirectory,
  appBundleId: 'dev.mooncap.desktop', helperBundleId: 'dev.mooncap.desktop.helper', appVersion: project.version,
  overwrite: true, prune: true, asar: { unpackDir: '{dist/native,platform}', unpack: '**/*.node' },
  ignore: [/^\/(?:\.[^/]+|release|test|docs|scripts|core|ui|work|output|outputs)(?:\/|$)/],
  extraResource: [media.binDirectory],
  extendInfo: { ...permissionInfo, LSUIElement: true, NSHighResolutionCapable: true },
  extendHelperInfo: permissionInfo,
});
for (const output of outputs) {
  const appPath = path.join(output, 'Mooncap.app');
  const resources = path.join(appPath, 'Contents/Resources');
  for (const helper of ['mooncap-clipboard', 'mooncap-window-bounds']) await access(path.join(resources, 'app.asar.unpacked/dist/native', helper), constants.X_OK);
  await access(path.join(resources, 'bin/ffmpeg'), constants.X_OK);
  const { stdout } = await execute(path.join(resources, 'bin/ffmpeg'), ['-version'], { env: { PATH: '/usr/bin:/bin' }, timeout: 15_000 });
  if (!stdout.startsWith('ffmpeg version')) throw new Error('Packaged media runtime failed to load.');
  await writeFile(path.join(resources, 'mooncap-build.json'), JSON.stringify({ appVersion: project.version, electronVersion: runtimeVersion, platform: 'darwin', arch: process.arch,
    builtAt: new Date().toISOString(), mediaFiles: media.manifest.files.length, developerIdSigned: false, notarized: false }, null, 2) + '\n');
  console.log(`Packaged local app: ${appPath}`);
  console.log('Developer ID signing and notarization were not performed.');
}
