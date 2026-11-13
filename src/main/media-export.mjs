import { stat } from 'node:fs/promises';
import { number } from './media-input.mjs';
import { findExecutable, runProcess } from './media-tools.mjs';

export function validateExportPlan(plan, source) {
  if (!plan || !Array.isArray(plan.segments) || plan.segments.length < 1 || plan.segments.length > 100) {
    throw new Error('The export needs between 1 and 100 kept segments.');
  }
  let previousEnd = 0;
  let outputDuration = 0;
  const segments = plan.segments.map((segment) => {
    const start = number(segment?.sourceStartMs, 'segment start', 0, source.durationMs);
    const end = number(segment?.sourceEndMs, 'segment end', start + 1, source.durationMs + 1);
    if (start < previousEnd) throw new Error('Export segments must be ordered and must not overlap.');
    if (segment.outputStartMs !== undefined && (!Number.isFinite(segment.outputStartMs) || Math.abs(segment.outputStartMs - outputDuration) > 1)) throw new Error('Invalid output segment start.');
    const duration = end - start;
    outputDuration += duration;
    if (segment.outputEndMs !== undefined && (!Number.isFinite(segment.outputEndMs) || Math.abs(segment.outputEndMs - outputDuration) > 1)) throw new Error('Invalid output segment end.');
    previousEnd = end;
    return { sourceStartMs: start, sourceEndMs: end };
  });
  let crop;
  if (plan.crop) {
    const { x, y, width, height } = plan.crop;
    number(x, 'crop x', 0, source.width - 2, true);
    number(y, 'crop y', 0, source.height - 2, true);
    number(width, 'crop width', 2, source.width - x, true);
    number(height, 'crop height', 2, source.height - y, true);
    crop = { x, y, width, height };
  }
  if (plan.muted !== undefined && typeof plan.muted !== 'boolean') throw new Error('Invalid muted setting.');
  const input = plan.profile || {};
  const profile = {
    videoBitrateKbps: number(input.videoBitrateKbps ?? 4000, 'video bitrate', 64, 100_000, true),
    audioBitrateKbps: number(input.audioBitrateKbps ?? 128, 'audio bitrate', source.hasAudio && !plan.muted ? 16 : 0, 512, true),
    maxWidth: number(input.maxWidth ?? source.width, 'maximum width', 2, 32768, true),
  };
  return { segments, crop, muted: Boolean(plan.muted), profile, durationMs: outputDuration };
}

export function buildExportArgs(input, output, source, rawPlan) {
  const plan = validateExportPlan(rawPlan, source);
  const withAudio = source.hasAudio && !plan.muted;
  const filters = [];
  const labels = [];
  for (const [index, segment] of plan.segments.entries()) {
    const start = segment.sourceStartMs / 1000;
    const end = segment.sourceEndMs / 1000;
    filters.push(`[0:v:0]trim=start=${start}:end=${end},setpts=PTS-STARTPTS[v${index}]`);
    labels.push(`[v${index}]`);
    if (withAudio) {
      filters.push(`[0:a:0]atrim=start=${start}:end=${end},asetpts=PTS-STARTPTS[a${index}]`);
      labels.push(`[a${index}]`);
    }
  }
  filters.push(`${labels.join('')}concat=n=${plan.segments.length}:v=1:a=${withAudio ? 1 : 0}[joined]${withAudio ? '[audio]' : ''}`);
  const crop = plan.crop ? `crop=${plan.crop.width}:${plan.crop.height}:${plan.crop.x}:${plan.crop.y},` : '';
  const maxWidth = Math.floor(plan.profile.maxWidth / 2) * 2;
  filters.push(`[joined]${crop}scale=w='min(${maxWidth},trunc(iw/2)*2)':h=-2,setsar=1[video]`);
  const args = ['-hide_banner', '-nostdin', '-n', '-i', input, '-filter_complex', filters.join(';'), '-map', '[video]'];
  if (withAudio) args.push('-map', '[audio]', '-c:a', 'aac', '-b:a', `${plan.profile.audioBitrateKbps}k`);
  args.push('-c:v', 'libx264', '-preset', 'veryfast', '-b:v', `${plan.profile.videoBitrateKbps}k`, '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-progress', 'pipe:1', '-nostats', output);
  return { args, plan };
}

export async function exportRecording(record, output, plan, { ffmpeg, onProgress = () => {} } = {}) {
  if (record.state !== 'complete') throw new Error('Finish the recording before exporting.');
  const { args, plan: validated } = buildExportArgs(record.filename, output, record, plan);
  let remainder = '';
  await runProcess(ffmpeg || await findExecutable('ffmpeg'), args, {
    timeoutMs: 60 * 60 * 1000,
    onStdout(text) {
      const lines = (remainder + text).split('\n');
      remainder = lines.pop();
      for (const line of lines) {
        const match = /^out_time_us=(\d+)$/.exec(line.trim());
        if (match) onProgress(Math.min(0.99, Number(match[1]) / (validated.durationMs * 1000)));
      }
    },
  });
  const info = await stat(output);
  if (info.size === 0) throw new Error('The export produced an empty file.');
  onProgress(1);
  return { path: output, size: info.size, fileSize: info.size, durationMs: validated.durationMs };
}
