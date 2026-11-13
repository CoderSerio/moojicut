import { access, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { number } from './media-input.mjs';

export async function findExecutable(name) {
  const filename = process.platform === 'win32' ? `${name}.exe` : name;
  const folders = [process.env.MOONCAP_MEDIA_BIN, process.resourcesPath && path.join(process.resourcesPath, 'bin'), ...(process.env.PATH || '').split(path.delimiter), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];
  for (const folder of [...new Set(folders.filter(Boolean))]) {
    const candidate = path.join(folder, filename);
    try {
      await access(candidate, process.platform === 'win32' ? constants.F_OK : constants.X_OK);
      if ((await stat(candidate)).isFile()) return candidate;
    } catch { /* Try the next local installation. */ }
  }
  throw new Error(`${name} was not found. Install FFmpeg (including ffprobe), then restart Mooncap.`);
}

export function runProcess(executable, args, { onStdout, timeoutMs = 30_000, maxOutput = 1024 * 1024, signal } = {}) {
  return new Promise((resolve, reject) => {
    const canceled = () => Object.assign(new Error('已取消导出，原始录像和编辑草稿已保留。'), { name: 'AbortError' });
    if (signal?.aborted) { reject(canceled()); return; }
    const child = spawn(executable, args, { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let failure;
    let killTimer;
    const stop = (error) => {
      failure ??= error;
      child.kill('SIGTERM');
      killTimer ??= setTimeout(() => child.kill('SIGKILL'), 1000);
      killTimer.unref();
    };
    const abort = () => stop(canceled());
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    const timer = setTimeout(() => stop(new Error('媒体处理超时，原始录像已保留。')), timeoutMs);
    const cleanup = () => {
      clearTimeout(timer); clearTimeout(killTimer);
      signal?.removeEventListener('abort', abort);
    };
    child.on('error', (error) => { cleanup(); reject(error); });
    child.stdout.on('data', (chunk) => {
      try {
        if (onStdout) onStdout(chunk.toString());
        else {
          stdout += chunk.toString();
          if (stdout.length > maxOutput) stop(new Error('Unexpectedly large media-tool output.'));
        }
      } catch (error) { stop(error); }
    });
    child.stderr.on('data', (chunk) => { stderr = (stderr + chunk.toString()).slice(-16_384); });
    child.on('close', (code) => {
      cleanup();
      if (failure) reject(failure);
      else if (code !== 0) reject(new Error(`${path.basename(executable)} failed: ${stderr.trim() || `exit ${code}`}`));
      else resolve({ stdout, stderr });
    });
  });
}

export async function probeMedia(filename, ffprobe, { signal } = {}) {
  const { stdout } = await runProcess(ffprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', filename], { signal });
  const result = JSON.parse(stdout);
  const video = result.streams?.find((stream) => stream.codec_type === 'video');
  if (!video) throw new Error('No video stream was found. The original file has been kept.');
  let seconds = Number(result.format?.duration || video.duration);
  // MediaRecorder WebM files may omit container duration. Packet timestamps provide
  // a bounded-memory fallback without decoding the complete video.
  if (!Number.isFinite(seconds) || seconds <= 0) {
    let remainder = '';
    let lastEnd = 0;
    const readLines = (text, flush = false) => {
      const lines = (remainder + text).split('\n');
      remainder = flush ? '' : lines.pop();
      for (const line of lines) {
        const [timestamp, duration] = line.trim().split(',').map(Number);
        if (Number.isFinite(timestamp)) lastEnd = Math.max(lastEnd, timestamp + (Number.isFinite(duration) ? duration : 0));
      }
    };
    await runProcess(ffprobe, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time,duration_time', '-of', 'csv=p=0', filename], {
      onStdout: (text) => readLines(text), timeoutMs: 120_000, signal,
    });
    readLines('\n', true);
    seconds = lastEnd;
  }
  number(seconds, 'recording duration', 0.001, 7 * 24 * 60 * 60);
  return {
    durationMs: Math.ceil(seconds * 1000),
    width: number(video.width, 'video width', 1, 32768, true),
    height: number(video.height, 'video height', 1, 32768, true),
    frameRate: (() => { const [n, d] = String(video.avg_frame_rate || video.r_frame_rate || '30/1').split('/').map(Number); return d && Number.isFinite(n / d) && n / d > 0 ? n / d : 30; })(),
    hasAudio: result.streams.some((stream) => stream.codec_type === 'audio'),
  };
}
