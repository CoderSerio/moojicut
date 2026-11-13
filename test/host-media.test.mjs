import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { RecordingStore } from '../src/main/recording-store.mjs';
import { MAX_CHUNK_BYTES, validateBytes, validatePng } from '../src/main/media-input.mjs';
import { findExecutable, probeMedia, runProcess } from '../src/main/media-tools.mjs';
import { buildExportArgs, exportRecording, validateExportPlan } from '../src/main/media-export.mjs';

const source = { durationMs: 5000, width: 1920, height: 1080, hasAudio: true };
const oneSegment = { segments: [{ sourceStartMs: 0, sourceEndMs: 5000, outputStartMs: 0, outputEndMs: 5000 }] };

test('host rejects malformed edits and out-of-frame crops before spawning a tool', () => {
  assert.throws(() => validateExportPlan({ segments: [] }, source), /segments/);
  assert.throws(() => validateExportPlan({ segments: [{ sourceStartMs: -1, sourceEndMs: 10 }] }, source), /start/);
  assert.throws(() => validateExportPlan({ segments: [{ sourceStartMs: 2, sourceEndMs: Infinity }] }, source), /end/);
  assert.throws(() => validateExportPlan({ segments: [{ sourceStartMs: 0, sourceEndMs: 1000 }, { sourceStartMs: 900, sourceEndMs: 2000 }] }, source), /overlap/);
  assert.throws(() => validateExportPlan({ ...oneSegment, crop: { x: 1900, y: 0, width: 40, height: 40 } }, source), /crop width/);
  assert.throws(() => validateExportPlan({ ...oneSegment, profile: { maxWidth: '640;invalid' } }, source), /maximum width/);
  assert.throws(() => validateExportPlan({ ...oneSegment, muted: 'false' }, source), /muted/);
  assert.throws(() => validateExportPlan({ segments: [{ sourceStartMs: 0, sourceEndMs: 2000, outputStartMs: 1_000 }] }, source), /output segment/);
  assert.throws(() => validateExportPlan({ segments: [{ sourceStartMs: 0, sourceEndMs: 2000, outputStartMs: NaN }] }, source), /output segment/);
  assert.equal(validateExportPlan({ ...oneSegment, muted: true, profile: { audioBitrateKbps: 0 } }, source).profile.audioBitrateKbps, 0);
  assert.throws(() => validateExportPlan({ ...oneSegment, profile: { audioBitrateKbps: 0 } }, source), /audio bitrate/);
  const { args } = buildExportArgs('/tmp/input with spaces.webm', '/tmp/out with spaces.mp4', source, oneSegment);
  assert.equal(args[args.indexOf('-i') + 1], '/tmp/input with spaces.webm');
  assert.equal(args.at(-1), '/tmp/out with spaces.mp4');
  assert.ok(args.includes('libx264'));
});

test('host validates binary input and PNG dimensions', () => {
  assert.throws(() => validateBytes(new Uint8Array()), /between/);
  assert.throws(() => validateBytes('not bytes'), /between/);
  assert.throws(() => validateBytes(new Uint8Array(MAX_CHUNK_BYTES + 1)), /between/);
  const input = new Uint8Array([1, 2, 3]);
  const result = validateBytes(input);
  input[0] = 99;
  assert.equal(result[0], 1, 'retained chunks cannot be mutated by the caller');
  assert.throws(() => validatePng(new Uint8Array([1, 2, 3])), /PNG/);
});

test('recording store enforces one writer, ordered chunks, and keeps interrupted originals', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mooncap-store-'));
  try {
    const store = new RecordingStore(directory);
    await store.initialize();
    const { id } = await store.begin();
    await assert.rejects(store.begin(), /already in progress/);
    assert.throws(() => store.append(id, 1, new Uint8Array([1])), /out of order/);
    await store.append(id, 0, new Uint8Array([1, 2, 3]));
    assert.throws(() => store.append(id, 0, new Uint8Array([4])), /out of order/);
    await store.abort(id);
    assert.equal(store.activeId, null);
    assert.deepEqual(await readFile(store.get(id).filename), Buffer.from([1, 2, 3]));
    assert.throws(() => store.append(id, 1, new Uint8Array([4])), /not accepting/);
    assert.throws(() => store.get('../outside'), /Unknown/);
    const reopened = new RecordingStore(directory);
    await reopened.initialize();
    assert.equal(reopened.get(id).state, 'incomplete');
    assert.equal(reopened.get(id).bytes, 3);
    const metadata = path.join(directory, id, 'recording.json');
    await writeFile(metadata, JSON.stringify({ id, state: 'complete', durationMs: -1, width: 'invalid', height: 4, hasAudio: false }));
    const corrupt = new RecordingStore(directory);
    await corrupt.initialize();
    assert.equal(corrupt.get(id).state, 'incomplete');
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('FFmpeg integration: streamed original survives restart, cuts/crop/mute export correctly', { timeout: 120_000 }, async (t) => {
  let ffmpeg;
  let ffprobe;
  try { ffmpeg = await findExecutable('ffmpeg'); ffprobe = await findExecutable('ffprobe'); }
  catch { t.skip('FFmpeg and ffprobe must be installed for media integration.'); return; }
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mooncap-ffmpeg-'));
  try {
    const input = path.join(directory, 'fixture.webm');
    await runProcess(ffmpeg, ['-hide_banner', '-nostdin', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=15', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '4', '-c:v', 'libvpx', '-deadline', 'realtime', '-c:a', 'libopus', input]);
    const bytes = await readFile(input);
    const store = new RecordingStore(path.join(directory, 'recordings'), { ffprobe });
    await store.initialize();
    const { id } = await store.begin({ mimeType: 'video/webm;codecs=vp8,opus' });
    let sequence = 0;
    for (let offset = 0; offset < bytes.length; offset += 8192) await store.append(id, sequence++, bytes.subarray(offset, offset + 8192));
    const finished = await store.finish(id, { interruptedReason: "测试：音频设备中断" });
    assert.equal(finished.interruptedReason, "测试：音频设备中断");
    assert.equal(finished.width, 320);
    assert.equal(finished.height, 240);
    assert.equal(finished.hasAudio, true);
    assert.ok(finished.durationMs >= 3900 && finished.durationMs <= 4200);
    assert.match(finished.url, /^mooncap-media:\/\/recording\//);
    assert.deepEqual(await readFile(store.get(id).filename), bytes);
    const reloaded = new RecordingStore(path.join(directory, 'recordings'), { ffprobe });
    await reloaded.initialize();
    assert.equal((await reloaded.list())[0].id, id);
    assert.equal(reloaded.describe(reloaded.get(id)).interruptedReason, "测试：音频设备中断");
    const originalDraft = { schemaVersion: 1, source: finished, trim: { startMs: 0, endMs: 3500 }, cuts: [], crop: null, muted: false, preset: 'share' };
    await Promise.all([
      reloaded.saveDraft(id, originalDraft),
      reloaded.saveDraft(id, { ...originalDraft, cuts: [{ startMs: 500, endMs: 1000 }, { startMs: 2000, endMs: 2500 }], muted: true }),
    ]);
    const draftStore = new RecordingStore(path.join(directory, 'recordings'), { ffprobe });
    await draftStore.initialize();
    const restoredDraft = await draftStore.loadDraft(id);
    assert.equal(restoredDraft.muted, true);
    assert.equal(restoredDraft.cuts.length, 2);
    await assert.rejects(draftStore.saveDraft(id, { ...restoredDraft, trim: { startMs: 5000, endMs: 6000 } }), /integer/);
    assert.deepEqual(await draftStore.loadDraft(id), restoredDraft, 'rejected draft cannot overwrite last valid edit');

    const segments = [{ sourceStartMs: 250, sourceEndMs: 1250, outputStartMs: 0, outputEndMs: 1000 }, { sourceStartMs: 2250, sourceEndMs: 3250, outputStartMs: 1000, outputEndMs: 2000 }];
    const plan = { segments, crop: { x: 10, y: 10, width: 200, height: 150 }, muted: true, profile: { videoBitrateKbps: 400, audioBitrateKbps: 64, maxWidth: 160 } };
    const output = path.join(directory, 'trimmed.mp4');
    const progress = [];
    const exported = await exportRecording(reloaded.get(id), output, plan, { ffmpeg, onProgress: (value) => progress.push(value) });
    const info = await probeMedia(output, ffprobe);
    assert.equal(info.width, 160);
    assert.equal(info.height, 120);
    assert.equal(info.hasAudio, false);
    assert.ok(Math.abs(info.durationMs - 2000) <= 150, JSON.stringify(info));
    assert.equal(exported.fileSize, (await stat(output)).size);
    assert.equal(progress.at(-1), 1);
    const withAudio = path.join(directory, 'audio.mp4');
    await exportRecording(reloaded.get(id), withAudio, { segments, profile: plan.profile }, { ffmpeg });
    assert.equal((await probeMedia(withAudio, ffprobe)).hasAudio, true);
    const streams = JSON.parse((await runProcess(ffprobe, ['-v', 'error', '-show_streams', '-of', 'json', withAudio])).stdout).streams;
    const videoDuration = Number(streams.find((stream) => stream.codec_type === 'video').duration);
    const audioDuration = Number(streams.find((stream) => stream.codec_type === 'audio').duration);
    assert.ok(Math.abs(videoDuration - audioDuration) < 0.15, `A/V duration mismatch: ${videoDuration} vs ${audioDuration}`);
    const live = path.join(directory, 'no-duration.webm');
    await runProcess(ffmpeg, ['-hide_banner', '-nostdin', '-i', input, '-c', 'copy', '-live', '1', live]);
    const liveFormat = JSON.parse((await runProcess(ffprobe, ['-v', 'error', '-show_format', '-of', 'json', live])).stdout).format;
    assert.equal(liveFormat.duration, undefined, 'fixture must exercise missing WebM duration');
    const recovered = await probeMedia(live, ffprobe);
    assert.ok(recovered.durationMs > 3900 && recovered.durationMs < 4200, JSON.stringify(recovered));
    assert.deepEqual(await readFile(reloaded.get(id).filename), bytes, 'export never modifies the original');
    const threeSegments = [{ sourceStartMs: 250, sourceEndMs: 750 }, { sourceStartMs: 1500, sourceEndMs: 2000 }, { sourceStartMs: 2500, sourceEndMs: 3250 }];
    const three = path.join(directory, 'three-segments.mp4');
    await exportRecording(reloaded.get(id), three, { segments: threeSegments, muted: true }, { ffmpeg, ffprobe });
    assert.ok(Math.abs((await probeMedia(three, ffprobe)).durationMs - 1750) <= 150);
    const existing = await readFile(three);
    await assert.rejects(exportRecording(reloaded.get(id), three, { segments: threeSegments }, { ffmpeg, ffprobe }), /already exists/);
    assert.deepEqual(await readFile(three), existing, 'export rejection must never remove an existing file');

  } finally { await rm(directory, { recursive: true, force: true }); }
});
