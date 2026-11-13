#!/usr/bin/env node
import { rpc } from './client.mjs';
const [method, input] = process.argv.slice(2);
if (!method || method === '--help') {
  console.log(`Mooncap CLI

Usage: node agent/cli.mjs <method> [JSON parameters]

Tools: status, list_windows, capture, import_image, list_captures, get_capture,
annotate, crop, undo, redo, preview, export, present, pin, copy

Coordinates use original-image physical pixels. Read the returned revision and
pass expectedRevision when editing; preview (0,0) is document.viewport.x/y.
MOONCAP_HOME selects a separate data directory. MOONCAP_AUTOSTART=0 disables startup.

Example: node agent/cli.mjs annotate '{"captureId":"...","expectedRevision":1,"action":"add","annotations":[{"type":"rect","x":10,"y":10,"width":100,"height":60}]}'`);
} else {
  try {
    const result = await rpc(method, input ? JSON.parse(input) : {});
    console.log(JSON.stringify(result, (key, value) => ['image', 'imageUrl', 'pngBase64'].includes(key) && typeof value === 'string' ? `[image data ${value.length} characters]` : value, 2));
  } catch (failure) {
    console.error(JSON.stringify({ error: failure.message, code: failure.code, details: failure.details }));
    process.exitCode = 1;
  }
}
