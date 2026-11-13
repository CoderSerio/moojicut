import test from 'node:test';
import assert from 'node:assert/strict';
import { editPlan, cropRect, exportProfile, recordingTransition } from '../src/renderer/core-bridge.mjs';
import { buildExportArgs, validateExportPlan } from '../src/main/media-export.mjs';

const call = (fn, value) => {
  const result = fn(value);
  assert.equal(result.ok, true, JSON.stringify(result));
  return result;
};

test('MoonBit edits and share profiles are accepted by the native export boundary', () => {
  for (const sourceHasAudio of [false, true]) {
    for (const muted of [false, true]) {
      const source = { durationMs: 60000, width: 2560, height: 1440, hasAudio: sourceHasAudio };
      const edit = call(editPlan, { durationMs: source.durationMs, trim: { startMs: 5000, endMs: 55000 }, cut: { startMs: 20000, endMs: 30000 } });
      assert.equal(edit.outputDurationMs, 40000);
      const crop = call(cropRect, { sourceWidth: source.width, sourceHeight: source.height, x: 100, y: 100, width: 1600, height: 900 }).rect;
      const profile = call(exportProfile, { durationMs: edit.outputDurationMs, width: crop.width, height: crop.height, preset: 'share', hasAudio: sourceHasAudio && !muted, targetBytes: 25 * 1024 * 1024 });
      const plan = { segments: edit.segments, crop, profile, muted };
      assert.equal(validateExportPlan(plan, source).durationMs, 40000);
      const { args } = buildExportArgs('/source.webm', '/export.mp4', source, plan);
      assert.equal(args.includes('aac'), sourceHasAudio && !muted);
      assert.ok(args.includes('libx264'));
      assert.ok(profile.estimatedBytes <= 25 * 1024 * 1024);
    }
  }
});

test('the recording lifecycle permits completion, failure, and a fresh capture', () => {
  let state = 'idle';
  for (const event of ['start', 'capture_started', 'stop', 'complete', 'reset', 'start', 'fail', 'reset']) {
    state = recordingTransition(state, event);
  }
  assert.equal(state, 'idle');
  assert.throws(() => recordingTransition('idle', 'complete'), /Cannot apply complete/);
});
