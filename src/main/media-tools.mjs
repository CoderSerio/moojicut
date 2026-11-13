import { access, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { number } from './media-input.mjs';

export async function findExecutable(name) {
  const filename = process.platform === 'win32' ? `${name}.exe` : name;
  const folders = [...(process.env.PATH || '').split(path.delimiter), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];
  for (const folder of [...new Set(folders.filter(Boolean))]) {
    const candidate = path.join(folder, filename);
    try {
      await access(candidate, process.platform === 'win32' ? constants.F_OK : constants.X_OK);
      if ((await stat(candidate)).isFile()) return candidate;
    } catch { /* Try the next local installation. */ }
  }
  throw new Error(`${name} was not found. Install FFmpeg (including ffprobe), then restart Mooncap.`);
}

export function runProcess(executable, args, { onStdout, timeoutMs = 30_000, maxOutput = 1024 * 1024 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let failure;
    const timer = setTimeout(() => {
      failure = new Error('The media operation timed out. The original recording is still saved.');
      child.kill('SIGKILL');
    }, timeoutMs);
    const finish = (error) => { clearTimeout(timer); reject(error); };
    child.on('error', finish);
    child.stdout.on('data', (chunk) => {
      if (onStdout) onStdout(chunk.toString());
      else {
        stdout += chunk.toString();
        if (stdout.length > maxOutput) {
          failure = new Error('Unexpectedly large media-tool output.');
          child.kill('SIGKILL');
        }
      }
    });
    child.stderr.on('data', (chunk) => { stderr = (stderr + chunk.toString()).slice(-16_384); });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (failure) reject(failure);
      else if (code !== 0) reject(new Error(`${path.basename(executable)} failed: ${stderr.trim() || `exit ${code}`}`));
      else resolve({ stdout, stderr });
    });
  });
}

export async function probeMedia(filename, ffprobe) {
  const { stdout } = await runProcess(ffprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', filename]);
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
      onStdout: (text) => readLines(text), timeoutMs: 120_000,
    });
    readLines('\n', true);
    seconds = lastEnd;
  }
  number(seconds, 'recording duration', 0.001, 7 * 24 * 60 * 60);
  return {
    durationMs: Math.ceil(seconds * 1000),
    width: number(video.width, 'video width', 1, 32768, true),
    height: number(video.height, 'video height', 1, 32768, true),
    hasAudio: result.streams.some((stream) => stream.codec_type === 'audio'),
  };
}
