import { screen } from 'electron';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const execute = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const helper = path.join(root.replace(/app\.asar$/, 'app.asar.unpacked'), 'dist/native/mooncap-window-bounds');

function pixels(width, height, scale) {
  if (![width, height, scale].every(value => Number.isFinite(value) && value > 0)) throw new Error('无法确定采集来源的像素尺寸。');
  const result = { width: Math.round(width * scale), height: Math.round(height * scale) };
  if (!Object.values(result).every(value => Number.isSafeInteger(value) && value > 0)) throw new Error('采集来源的像素尺寸无效。');
  return result;
}

export async function captureDimensions(sourceId, defaultDisplay) {
  if (sourceId?.startsWith('window:') && process.platform === 'darwin') {
    // Electron's DesktopCapturerSource ID contains the native CGWindowID.
    const match = /^window:([1-9][0-9]*):[0-9]+$/.exec(sourceId);
    if (!match || !Number.isSafeInteger(Number(match[1])) || Number(match[1]) > 0xffffffff) throw new Error('窗口来源标识无效，请重新选择窗口。');
    let bounds;
    try {
      const { stdout } = await execute(helper, [match[1]], { timeout: 5000, maxBuffer: 16 * 1024 });
      const { x, y, w, h } = JSON.parse(stdout);
      if (![x, y, w, h].every(Number.isFinite) || w <= 0 || h <= 0) throw new Error('Invalid native window bounds.');
      bounds = { x, y, width: w, height: h };
    } catch (error) {
      if (error.code === 'ENOENT') throw new Error('缺少窗口尺寸组件，请重新构建应用。', { cause: error });
      throw new Error('无法读取窗口的真实尺寸。窗口可能已关闭，请重新选择窗口后重试。', { cause: error });
    }
    // CoreGraphics and Electron use the main screen's upper-left origin on
    // macOS. Only the Electron Rectangle passed to display lookup is rounded;
    // preserve the original native dimensions when computing output pixels.
    const display = screen.getDisplayMatching({ x: Math.round(bounds.x), y: Math.round(bounds.y), width: Math.ceil(bounds.width), height: Math.ceil(bounds.height) });
    return pixels(bounds.width, bounds.height, display.scaleFactor);
  }
  // Windows/Linux native window-size lookup is not implemented yet. Their
  // window captures use a display-sized thumbnail budget, not a native-size
  // guarantee. Screen captures use the requested display's physical size.
  return pixels(defaultDisplay?.size?.width, defaultDisplay?.size?.height, defaultDisplay?.scaleFactor);
}
