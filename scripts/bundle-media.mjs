import { access, chmod, copyFile, mkdir, readFile, readdir, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';

const execute = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const systemLibrary = filename => filename.startsWith('/System/Library/') || filename.startsWith('/usr/lib/');
const homebrewLibrary = filename => filename.startsWith('/opt/homebrew/') || filename.startsWith('/usr/local/');
const cleanEnvironment = () => Object.fromEntries(Object.entries({ ...process.env, PATH: '/usr/bin:/bin' }).filter(([name]) => !name.startsWith('DYLD_')));
async function run(command, args, options = {}) {
  const result = await execute(command, args, { maxBuffer: 8 * 1024 * 1024, ...options });
  return result.stdout.trim();
}
async function dependencies(filename) {
  const lines = (await run('/usr/bin/otool', ['-L', filename])).split('\n').slice(1);
  return lines.map(line => line.trim().replace(/ \(compatibility version.*$/, '')).filter(Boolean);
}
async function rpaths(filename) {
  const lines = (await run('/usr/bin/otool', ['-l', filename])).split('\n');
  const output = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() !== 'cmd LC_RPATH') continue;
    const line = lines.slice(i + 1, i + 5).find(value => /^\s*path /.test(value));
    if (line) output.push(line.trim().replace(/^path /, '').replace(/ \(offset \d+\)$/, ''));
  }
  return output;
}
const hash = async filename => createHash('sha256').update(await readFile(filename)).digest('hex');

export async function bundleMedia({ output = path.join(root, 'release/media'), ffmpeg = process.env.MOONCAP_FFMPEG || '/opt/homebrew/bin/ffmpeg', ffprobe = process.env.MOONCAP_FFPROBE || '/opt/homebrew/bin/ffprobe' } = {}) {
  if (process.platform !== 'darwin') throw new Error('The current media bundler supports macOS only; add a separately verified platform bundle.');
  output = path.resolve(output);
  const allowedRoot = path.join(root, 'release') + path.sep;
  if (!output.startsWith(allowedRoot)) throw new Error('Media output must be inside this repository release directory.');
  for (const filename of [ffmpeg, ffprobe]) await access(filename, constants.X_OK);
  await mkdir(path.join(output, 'bin/lib'), { recursive: true });
  const files = new Map();
  const filenames = new Map();
  const sourceRpaths = new Map();
  const roots = [await realpath(ffmpeg), await realpath(ffprobe)];
  async function resolveDependency(dependency, owner) {
    if (dependency.startsWith('/')) return dependency;
    const expand = value => value.replace(/^@loader_path/, path.dirname(owner)).replace(/^@executable_path/, path.dirname(roots[0]));
    const candidates = dependency.startsWith('@rpath/')
      ? (await rpaths(owner)).map(item => path.join(expand(item), dependency.slice(7)))
      : [expand(dependency)];
    for (const candidate of candidates) { try { await access(candidate); return candidate; } catch {} }
    throw new Error(`Cannot resolve ${dependency} loaded by ${owner}.`);
  }
  async function visit(filename, executable = false) {
    const source = await realpath(filename);
    if (files.has(source)) return files.get(source);
    const basename = path.basename(source);
    const destination = path.join(output, 'bin', ...(executable ? [] : ['lib']), basename);
    if (filenames.has(destination) && filenames.get(destination) !== source) throw new Error(`Conflicting library names: ${source} and ${filenames.get(destination)}.`);
    const record = { source, destination, executable, dependencies: [] };
    files.set(source, record); filenames.set(destination, source);
    await copyFile(source, destination); await chmod(destination, 0o755);
    sourceRpaths.set(source, await rpaths(source));
    for (const dependency of await dependencies(source)) {
      const resolved = await resolveDependency(dependency, source);
      if (systemLibrary(resolved)) continue;
      if (!homebrewLibrary(resolved)) throw new Error(`Unbundled non-system dependency: ${resolved}.`);
      const actual = await realpath(resolved);
      if (actual === source) continue; // LC_ID_DYLIB is not a dependency edge.
      const target = await visit(actual);
      record.dependencies.push({ original: dependency, target: target.destination });
    }
    return record;
  }
  for (const filename of roots) await visit(filename, true);
  for (const record of files.values()) {
    for (const { original, target } of record.dependencies) {
      const relative = path.relative(path.dirname(record.destination), target).split(path.sep).join('/');
      await run('/usr/bin/install_name_tool', ['-change', original, `@loader_path/${relative}`, record.destination]);
    }
    if (!record.executable) await run('/usr/bin/install_name_tool', ['-id', `@loader_path/${path.basename(record.destination)}`, record.destination]);
    for (const entry of sourceRpaths.get(record.source)) {
      if (homebrewLibrary(entry)) await run('/usr/bin/install_name_tool', ['-delete_rpath', entry, record.destination]);
    }
  }
  // Local ad-hoc signatures restore Mach-O integrity after relocation. They are not Developer ID signing or notarization.
  for (const record of [...files.values()].sort((a, b) => Number(a.executable) - Number(b.executable))) {
    await run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', record.destination]);
    await run('/usr/bin/codesign', ['--verify', '--strict', record.destination]);
    for (const dependency of await dependencies(record.destination)) {
      if (!systemLibrary(dependency) && !dependency.startsWith('@loader_path/')) throw new Error(`Non-relocatable dependency remains in ${record.destination}: ${dependency}`);
      if (dependency.startsWith('@loader_path/')) await access(path.resolve(path.dirname(record.destination), dependency.slice('@loader_path/'.length)));
    }
  }
  const licenses = path.join(output, 'bin/licenses');
  await mkdir(licenses, { recursive: true });
  const cellarRoots = new Set([...files.keys()].map(filename => filename.match(/^((?:\/opt\/homebrew|\/usr\/local)\/Cellar\/[^/]+\/[^/]+)/)?.[1]).filter(Boolean));
  for (const cellar of cellarRoots) {
    const tag = `${path.basename(path.dirname(cellar))}-${path.basename(cellar)}`;
    const destination = path.join(licenses, tag); await mkdir(destination, { recursive: true });
    for (const name of await readdir(cellar)) {
      if (!/^(?:LICENSE|LICENCE|COPYING|NOTICE|AUTHORS)(?:[._-]|$)|^INSTALL_RECEIPT\.json$|^sbom\.spdx\.json$/i.test(name)) continue;
      const source = path.join(cellar, name);
      if ((await stat(source)).isFile()) await copyFile(source, path.join(destination, name));
    }
  }
  const environment = cleanEnvironment();
  const bundledFfmpeg = path.join(output, 'bin/ffmpeg'), bundledFfprobe = path.join(output, 'bin/ffprobe');
  const version = await run(bundledFfmpeg, ['-version'], { env: environment });
  await writeFile(path.join(output, 'bin/ffmpeg-build.txt'), version + '\n' + await run(bundledFfmpeg, ['-buildconf'], { env: environment }) + '\n');
  const sample = path.join(output, `.probe-${process.pid}.mp4`);
  let probe;
  try {
    await run(bundledFfmpeg, ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=64x48:r=30', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=mono', '-t', '0.5', '-c:v', 'libx264', '-c:a', 'aac', '-pix_fmt', 'yuv420p', '-y', sample], { env: environment, timeout: 30_000 });
    probe = JSON.parse(await run(bundledFfprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', sample], { env: environment, timeout: 15_000 }));
    if (!probe.streams.some(item => item.codec_name === 'h264') || !probe.streams.some(item => item.codec_name === 'aac')) throw new Error('Bundled media smoke test did not produce H.264 and AAC.');
    await run(bundledFfmpeg, ['-v', 'error', '-i', sample, '-f', 'null', '-'], { env: environment, timeout: 15_000 });
  } finally { await rm(sample, { force: true }); }
  const manifest = { platform: 'darwin', arch: process.arch, builtAt: new Date().toISOString(), version: version.split('\n')[0],
    validation: { localAdHocSignatures: true, externalHomebrewDependencies: false, sanitizedPath: environment.PATH, h264AacEncodeProbeDecode: true },
    files: await Promise.all([...files.values()].map(async record => ({ path: path.relative(output, record.destination), source: record.source, sha256: await hash(record.destination) }))),
    distribution: 'Local development bundle. Developer ID signing, notarization and release distribution review are not performed by this script.' };
  await writeFile(path.join(output, 'bin/media-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  return { directory: output, binDirectory: path.join(output, 'bin'), manifest };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await bundleMedia();
  console.log(`Bundled and validated ${result.manifest.files.length} media binaries: ${result.binDirectory}`);
}
