import * as core from '../../dist/core/core.mjs';

function result(value) {
  const response = JSON.parse(value);
  if (!response.ok) throw new Error(response.error.message);
  return response;
}

export const editPlan = (value) => result(core.edit_plan(JSON.stringify(value)));
export const cropRect = (value) => result(core.crop_rect(JSON.stringify(value)));
export const exportProfile = (value) => result(core.export_profile(JSON.stringify(value)));
export const recordingTransition = (state, event) => result(core.recording_transition(state, event)).state;
