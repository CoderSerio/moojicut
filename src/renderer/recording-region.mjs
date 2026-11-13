// Coordinates enter in the selected source's pixel space. The browser may deliver
// a scaled stream, so compute the crop once from the actual decoded frame size.
export function recordingRegion(config, actualWidth, actualHeight) {
  const { sourceWidth, sourceHeight, region } = config;
  for (const value of [sourceWidth, sourceHeight, actualWidth, actualHeight]) {
    if (!Number.isFinite(value) || value < 2 || value > 32768) throw new Error('采集源尺寸无效。');
  }
  const selection = region || { x: 0, y: 0, width: sourceWidth, height: sourceHeight };
  for (const value of Object.values(selection)) if (!Number.isFinite(value)) throw new Error('录制范围无效。');
  if (selection.x < 0 || selection.y < 0 || selection.width < 2 || selection.height < 2
    || selection.x + selection.width > sourceWidth || selection.y + selection.height > sourceHeight) throw new Error('录制范围超出所选显示器。');
  const x = Math.round(selection.x * actualWidth / sourceWidth);
  const y = Math.round(selection.y * actualHeight / sourceHeight);
  const right = Math.min(actualWidth, Math.round((selection.x + selection.width) * actualWidth / sourceWidth));
  const bottom = Math.min(actualHeight, Math.round((selection.y + selection.height) * actualHeight / sourceHeight));
  const width = Math.floor((right - x) / 2) * 2;
  const height = Math.floor((bottom - y) / 2) * 2;
  if (width < 2 || height < 2) throw new Error('录制区域过小。');
  return { x, y, width, height };
}
